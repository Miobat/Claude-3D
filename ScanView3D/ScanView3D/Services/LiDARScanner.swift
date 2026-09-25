// PoseFile, MeshData and PathRangeIndex below are also compiled for simulator.
import Foundation
import simd

#if !targetEnvironment(simulator)
import ARKit
import RealityKit
import Combine
import CoreImage
import AVFoundation
import os

/// Manages LiDAR scanning sessions using ARKit
class LiDARScanner: NSObject, ObservableObject {
    // MARK: - Published State

    @Published var isScanning = false
    @Published var isPaused = false
    @Published private(set) var isFinalizing = false
    @Published var needsRecoveryCheckpoint = false
    @Published var scanProgress: String = "Ready to scan"
    @Published var vertexCount: Int = 0
    @Published var faceCount: Int = 0
    @Published var scanError: String?
    @Published var capturedFrameCount: Int = 0
    @Published var detectedPlaneCount: Int = 0
    @Published var isPreviewing = false
    @Published var memoryUsageMB: Double = 0
    @Published var estimatedFileSizeMB: Double = 0
    @Published var scanCapacityPercent: Double = 0
    @Published var highResFrameCount: Int = 0
    /// Plain-language tracking problem ("Move slower"), or nil when tracking is good.
    @Published var trackingWarning: String?
    @Published var photoLimitReached = false
    /// Points in the LiDAR depth cloud (Point Cloud / Splat modes).
    @Published var depthPointCount: Int = 0
    @Published var pointBudgetReached = false
    /// Advice about how the user is moving (e.g. "walk around, don't pivot").
    @Published var captureHint: String?

    // MARK: - Properties

    @Published private(set) var arSession: ARSession
    private var captureTexture: Bool = true
    private(set) var rangeMeters: Float = 3.0
    private let scanQuality: ScanSettings.ScanQuality = .standard
    private(set) var meshMode: ScanSettings.MeshMode = .free
    let textureMapper = TextureMapper()
    private var frameCaptureTimer: Timer?
    private var memoryMonitorTimer: Timer?

    // Anchors change several times a second, so they are deliberately not
    // @Published: SwiftUI only needs the counts, not a re-render per update.
    private var meshAnchorsByID: [UUID: ARMeshAnchor] = [:]
    private var retiredMeshSnapshots: [UUID: MeshAnchorSnapshot] = [:]
    private var planeAnchorsByID: [UUID: ARPlaneAnchor] = [:]
    var meshAnchors: [ARMeshAnchor] { Array(meshAnchorsByID.values) }
    var planeAnchors: [ARPlaneAnchor] { Array(planeAnchorsByID.values) }

    /// Where the device was when tracking first became reliable in this scan.
    private(set) var scanOrigin = SIMD3<Float>(0, 0, 0)
    private var needsOrigin = true
    private var textureCapturePaused = false

    // Camera path: geometry is kept only if the device passed within
    // `rangeMeters` of it, so the range setting follows the walked route.
    private(set) var cameraPath: [SIMD3<Float>] = []
    private let cameraPathMinStep: Float = 0.2
    private let cameraPathMaxCount = 20_000          // ~4 km of walking
    private var anchorPathIndex = PathRangeIndex(points: [], radius: 7)

    // High-Quality / Splat full-resolution photo capture
    private var captureMode: ScanSettings.CaptureMode = .fast
    private var captureFolderURL: URL?
    private var lastHighResSaveTime: TimeInterval = 0
    private let maxHighResFrames: Int = 250
    private var pendingHighResSaves = 0
    private let ciContext = CIContext()
    private let hqSaveQueue = DispatchQueue(label: "scanview.hq.save", qos: .utility)
    private(set) var capturedPoses: [CapturedPose] = []
    private var lastPhotoTransform: simd_float4x4?
    private var useHighResPhotos = false
    private var highResCaptureInFlight = false
    private let epoch = CaptureEpoch()
    private let photoWork = DispatchGroup()
    private var nextPhotoIndex = 0
    private var finalizationCallbacks: [() -> Void] = []

    // Motion (for blur rejection)
    private var lastTickTransform: simd_float4x4?
    private var lastTickTime: TimeInterval = 0

    // Camera control: white balance is locked once it has settled, so colours
    // stay consistent between the frames used for the texture.
    private var captureDevice: AVCaptureDevice?
    private var whiteBalanceLocked = false
    private var normalTrackingSince: TimeInterval?

    /// Dense coloured points straight from the LiDAR depth sensor.
    private let depthCloud = DepthPointAccumulator()
    var acceptedDepthFrame: AcceptedDepthFrame? { depthCloud.acceptedFrame }

    // Memory limits (MB). "Available" is the app's real remaining budget.
    private let maxTextureMemoryMB: Double = 800
    private let pauseTexturesBelowMB: Double = 400
    private let pauseScanBelowMB: Double = 200

    // MARK: - Initialization

    override init() {
        self.arSession = ARSession()
        super.init()
        self.arSession.delegate = self
    }

    // MARK: - LiDAR Availability

    static var isLiDARAvailable: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    static var isLiDARWithClassificationAvailable: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
    }

    // MARK: - Camera Preview

    func startPreview() {
        guard !isPreviewing && !isScanning && !isFinalizing else { return }
        guard LiDARScanner.isLiDARAvailable else { return }

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        arSession.run(configuration)
        isPreviewing = true
        scanProgress = "Point camera at area to scan"
    }

    func stopPreview() {
        guard isPreviewing && !isScanning else { return }
        arSession.pause()
        isPreviewing = false
    }

    // MARK: - Session Control

    func startScanning(
        captureTexture: Bool = true,
        meshMode: ScanSettings.MeshMode = .free,
        rangeMeters: Float = 3.0,
        captureMode: ScanSettings.CaptureMode = .fast,
        detailMM: Float = 10,
        highResPhotos: Bool = false,
        alignToNorth: Bool = false
    ) {
        guard !isScanning, !isFinalizing else { return }
        guard LiDARScanner.isLiDARAvailable else {
            scanError = "LiDAR is not available on this device"
            return
        }

        arSession.pause()
        arSession.delegate = nil
        isPreviewing = false
        arSession = ARSession()
        arSession.delegate = self
        clearScanData()

        self.captureTexture = captureTexture
        self.rangeMeters = rangeMeters
        self.meshMode = meshMode
        self.captureMode = captureMode
        anchorPathIndex = PathRangeIndex(points: [], radius: rangeMeters + 4)

        let usesPhotos = captureMode == .highQuality || captureMode == .splatExport
        if usesPhotos {
            guard let folder = makeCaptureFolder() else {
                scanError = "Cannot create the photo folder. Free storage and try again."
                startPreview()
                return
            }
            captureFolderURL = folder
        }

        textureMapper.configure(quality: scanQuality)

        // All modes retain capture-time depth evidence. Raw ARKit anchor extents
        // and the camera's walked path must never expand the accepted range.
        let dense = captureMode == .pointCloud || captureMode == .splatExport
        let budget = Int(max(200, Self.availableMemoryMB() - 600) * 1_048_576 * 0.35 / 100)
        depthCloud.configure(voxelSize: dense ? max(0.004, detailMM / 1000) : 0.025,
                             maxPoints: min(dense ? 4_000_000 : 600_000, budget))

        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = LiDARScanner.isLiDARWithClassificationAvailable
            ? .meshWithClassification : .mesh
        configuration.planeDetection = [.horizontal, .vertical]
        // Compass alignment: -Z = true north, +X = east (needs a working compass).
        configuration.worldAlignment = alignToNorth ? .gravityAndHeading : .gravity
        // Depth is used to hide occluded surfaces when colouring and for the point cloud.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        // 12 MP stills (High Quality / Splat): needs a special camera format and disk space.
        useHighResPhotos = false
        if usesPhotos && highResPhotos {
            if Self.freeDiskSpaceGB() < 3 {
                scanError = "Not enough free storage for 12 MP photos (needs about 3 GB). Using standard photos."
            } else if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
                configuration.videoFormat = format
                useHighResPhotos = true
            }
        }
        captureDevice = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera

        // Tracking restarts from scratch; the scan origin is taken from the first
        // well-tracked frame of the NEW session (see captureCurrentFrame).
        arSession.run(configuration, options: [.removeExistingAnchors, .resetTracking])

        isPreviewing = false
        isScanning = true
        isPaused = false
        scanProgress = "Scanning... Move slowly around the area"
        scanError = nil

        startFrameCapture()
        startMemoryMonitor()
    }

    func pauseScanning() {
        arSession.pause()
        isPaused = true
        scanProgress = "Scanning paused"
        stopFrameCapture()
    }

    func resumeScanning() {
        guard isScanning, !isFinalizing, !needsRecoveryCheckpoint else { return }
        guard let config = arSession.configuration else { return }
        arSession.run(config)
        isPaused = false
        scanProgress = "Scanning resumed..."
        startFrameCapture()
    }

    func stopScanning(completion: @escaping () -> Void = {}) {
        if isFinalizing { finalizationCallbacks.append(completion); return }
        guard isScanning else { completion(); return }
        isFinalizing = true
        finalizationCallbacks.append(completion)
        unlockWhiteBalance()
        arSession.pause()
        isScanning = false
        isPaused = false
        scanProgress = "Finishing accepted capture work…"
        stopFrameCapture()
        stopMemoryMonitor()
        let token = epoch.current
        let draining = DispatchGroup()
        draining.enter()
        textureMapper.drain { draining.leave() }
        draining.enter()
        depthCloud.drain { draining.leave() }
        draining.enter()
        photoWork.notify(queue: .main) { draining.leave() }
        draining.notify(queue: .main) { [weak self] in
            guard let self, self.epoch.isCurrent(token) else { return }
            self.isFinalizing = false
            self.scanProgress = "Scan complete"
            let callbacks = self.finalizationCallbacks
            self.finalizationCallbacks.removeAll()
            callbacks.forEach { $0() }
        }
    }

    /// Continue a stopped (not reset) scan, keeping everything captured so far.
    func continueScanning() {
        guard let config = arSession.configuration, !isScanning, !isFinalizing, !needsRecoveryCheckpoint else { return }
        arSession.run(config)
        isScanning = true
        isPaused = false
        scanProgress = "Scanning... Move slowly around the area"
        startFrameCapture()
        startMemoryMonitor()
    }

    func resetScanning(keepPhotos: Bool = false) {
        stopScanning { [weak self] in
            guard let self else { return }
            if keepPhotos { self.captureFolderURL = nil }
            self.clearScanData()
            self.scanProgress = "Ready to scan"
            self.startPreview()
        }
    }

    /// Drop everything from the previous scan, including its temporary photo folder.
    private func clearScanData() {
        epoch.invalidate()
        nextPhotoIndex = 0
        pendingHighResSaves = 0
        needsRecoveryCheckpoint = false
        meshAnchorsByID.removeAll()
        retiredMeshSnapshots.removeAll()
        planeAnchorsByID.removeAll()
        vertexCount = 0
        faceCount = 0
        detectedPlaneCount = 0
        capturedFrameCount = 0
        memoryUsageMB = 0
        estimatedFileSizeMB = 0
        scanCapacityPercent = 0
        textureCapturePaused = false
        textureMapper.reset()
        if let folder = captureFolderURL {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: PoseFile.url(forPhotoFolder: folder))
        }
        captureFolderURL = nil
        highResFrameCount = 0
        lastHighResSaveTime = 0
        capturedPoses = []
        photoLimitReached = false
        lastPhotoTransform = nil
        highResCaptureInFlight = false
        lastTickTransform = nil
        lastTickTime = 0
        normalTrackingSince = nil
        unlockWhiteBalance()
        depthCloud.reset()
        depthPointCount = 0
        pointBudgetReached = false
        captureHint = nil
        captureMode = .fast
        cameraPath = []
        needsOrigin = true
        scanOrigin = SIMD3<Float>(0, 0, 0)
        trackingWarning = nil
    }

    // MARK: - Frame Capture

    private func startFrameCapture() {
        stopFrameCapture()
        frameCaptureTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.captureCurrentFrame()
        }
    }

    private func stopFrameCapture() {
        frameCaptureTimer?.invalidate()
        frameCaptureTimer = nil
    }

    private func captureCurrentFrame() {
        guard isScanning && !isPaused,
              let frame = arSession.currentFrame else { return }
        let token = epoch.current

        // Poses are unreliable while tracking is limited (starting up, moving too
        // fast, too dark). Capturing then produces smeared textures and bad photos.
        guard case .normal = frame.camera.trackingState else { return }

        let camPos = frame.camera.transform.position
        if needsOrigin {
            scanOrigin = camPos
            cameraPath = [camPos]
            anchorPathIndex.insert(camPos)
            needsOrigin = false
        } else if let last = cameraPath.last,
                  simd_distance(camPos, last) >= cameraPathMinStep,
                  cameraPath.count < cameraPathMaxCount {
            cameraPath.append(camPos)
            anchorPathIndex.insert(camPos)
        }

        // Motion blur estimate from movement since the previous tick.
        let now = frame.timestamp
        var blurPixels = 0.0
        if let prev = lastTickTransform, now > lastTickTime {
            let dt = now - lastTickTime
            let turn = Double(TextureMapper.angle(between: prev, and: frame.camera.transform))
            let move = Double(simd_distance(prev.position, camPos))
            let exposure = frame.camera.exposureDuration > 0 ? frame.camera.exposureDuration : 1.0 / 60.0
            blurPixels = (turn / dt + move / dt / 1.5) * exposure * Double(frame.camera.intrinsics[0][0])
        }
        lastTickTransform = frame.camera.transform
        lastTickTime = now

        // Fast mode: colour keyframes (+ white balance lock once it has settled).
        if captureMode == .fast && captureTexture && !textureCapturePaused {
            if !whiteBalanceLocked {
                if let since = normalTrackingSince {
                    if now - since > 1.5 { lockWhiteBalance() }
                } else {
                    normalTrackingSince = now
                }
            }
            textureMapper.captureFrame(from: frame, exposure: currentExposure()) { [weak self] count in
                guard let self, self.epoch.isCurrent(token) else { return }
                self.capturedFrameCount = count
            }
        }

        // Commit depth before showing coverage; one worker is in flight at most.
        do {
            depthCloud.integrate(frame, maxDistance: min(rangeMeters, 5)) { [weak self] count, full in
                guard let self = self, self.epoch.isCurrent(token) else { return }
                self.depthPointCount = count
                if full && !self.pointBudgetReached {
                    self.pointBudgetReached = true
                    self.scanProgress = "Capture budget reached — tap Stop to save"
                }
            }
        }

        // High Quality / Splat: posed photos.
        if captureMode == .highQuality || captureMode == .splatExport {
            considerPhoto(frame, blurPixels: blurPixels)
        }
    }

    // MARK: - Camera control

    private func currentExposure() -> (iso: Double, duration: Double)? {
        guard let device = captureDevice else { return nil }
        return (Double(device.iso), device.exposureDuration.seconds)
    }

    private func lockWhiteBalance() {
        whiteBalanceLocked = true
        guard let device = captureDevice, device.isWhiteBalanceModeSupported(.locked) else { return }
        do {
            try device.lockForConfiguration()
            device.whiteBalanceMode = .locked
            device.unlockForConfiguration()
        } catch {
            DebugLogger.shared.warn("Could not lock white balance: \(error)", category: "Scanner")
        }
    }

    private func unlockWhiteBalance() {
        guard whiteBalanceLocked else { return }
        whiteBalanceLocked = false
        guard let device = captureDevice, device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else { return }
        do {
            try device.lockForConfiguration()
            device.whiteBalanceMode = .continuousAutoWhiteBalance
            device.unlockForConfiguration()
        } catch {}
    }

    static func freeDiskSpaceGB() -> Double {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Double(values?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000
    }

    // MARK: - High-Quality Capture

    private func makeCaptureFolder() -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("Captures").appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    /// Take a photo when the camera has moved to a new viewpoint and isn't
    /// blurred. Spreads photos over the scene instead of every fraction of a second.
    private func considerPhoto(_ frame: ARFrame, blurPixels: Double) {
        guard captureFolderURL != nil else { return }
        if highResFrameCount >= maxHighResFrames {
            if !photoLimitReached {
                photoLimitReached = true
                scanProgress = "Photo limit reached (\(maxHighResFrames)) — tap Stop to save"
            }
            return
        }
        let now = frame.timestamp
        guard now - lastHighResSaveTime >= 0.35, blurPixels <= 2.0,
              pendingHighResSaves < 2, !highResCaptureInFlight else { return }
        let transform = frame.camera.transform
        if let last = lastPhotoTransform {
            let moved = simd_distance(last.position, transform.position)
            let turned = TextureMapper.angle(between: last, and: transform)
            guard moved >= 0.10 || turned >= 10 * .pi / 180 else { return }
        }
        lastHighResSaveTime = now
        lastPhotoTransform = transform

        guard useHighResPhotos, Self.availableMemoryMB() > 700 else {
            savePhoto(frame)
            return
        }
        highResCaptureInFlight = true
        let token = epoch.current
        let request = PhotoRequest(PhotoSample(frame, range: rangeMeters))
        let photoRange = rangeMeters
        photoWork.enter()
        let finishRequest: (PhotoSample?) -> Void = { [weak self] supplied in
            guard let self, !request.completed else { return }
            request.completed = true
            let sample = supplied ?? request.fallback
            request.fallback = nil // release the camera buffer immediately on success
            defer { self.photoWork.leave() }
            guard self.epoch.isCurrent(token), let sample else { return }
            self.highResCaptureInFlight = false
            self.savePhoto(sample)
        }
        // ARKit may cancel a still request when the session is interrupted. A
        // bounded fallback keeps Stop from waiting indefinitely for that callback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finishRequest(nil) }
        arSession.captureHighResolutionFrame { [weak self] hiRes, _ in
            guard self != nil else { return }
            let sample = hiRes.map { PhotoSample($0, range: photoRange) }
            DispatchQueue.main.async { finishRequest(sample?.rangeMask == nil ? nil : sample) }
        }
    }

    private func savePhoto(_ frame: ARFrame) {
        savePhoto(PhotoSample(frame, range: rangeMeters))
    }

    private struct PhotoSample {
        let image: CVPixelBuffer
        let transform: simd_float4x4
        let intrinsics: simd_float3x3
        let resolution: CGSize
        let rangeMask: PhotoRangeMask?
        init(_ frame: ARFrame, range: Float) {
            image = frame.capturedImage
            transform = frame.camera.transform
            intrinsics = frame.camera.intrinsics
            resolution = frame.camera.imageResolution
            rangeMask = CaptureDepthFrame(frame)?.photoMask(range: range)
        }
    }

    private final class PhotoRequest {
        var fallback: PhotoSample?
        var completed = false // main queue only
        init(_ fallback: PhotoSample) { self.fallback = fallback }
    }

    private func savePhoto(_ sample: PhotoSample) {
        guard let folder = captureFolderURL, highResFrameCount + pendingHighResSaves < maxHighResFrames else { return }
        guard let mask = sample.rangeMask, mask.isValid, mask.pixels.contains(255) else {
            captureHint = "Aim at a surface within range — no reliable in-range depth for this photo"
            return
        }
        let index = nextPhotoIndex
        nextPhotoIndex += 1
        let token = epoch.current

        let pixelBuffer = sample.image
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        // Intrinsics must describe THIS image. If ARKit reports them for a
        // different resolution (e.g. the video stream), rescale them.
        var intrinsics = sample.intrinsics
        let res = sample.resolution
        if res.width > 0, res.height > 0, abs(Double(w) - Double(res.width)) > 1 {
            let sx = Float(Double(w) / Double(res.width)), sy = Float(Double(h) / Double(res.height))
            intrinsics[0][0] *= sx; intrinsics[2][0] *= sx
            intrinsics[1][1] *= sy; intrinsics[2][1] *= sy
        }
        let pose = CapturedPose(index: index, transform: sample.transform, intrinsics: intrinsics, width: w, height: h, rangeMask: mask)

        // JPEG with EXIF focal length — PhotogrammetrySession needs it.
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let url = folder.appendingPathComponent(String(format: "frame_%04d.jpg", index))
        let focalLengthPx = Double(intrinsics[0][0])
        let sensorWidthMM = 6.17   // approximate iPhone wide-camera sensor width
        let physicalFocalMM = focalLengthPx * sensorWidthMM / Double(w)
        let focalLength35mm = physicalFocalMM * 36.0 / sensorWidthMM

        pendingHighResSaves += 1
        photoWork.enter()
        hqSaveQueue.async { [ciContext] in
            var failure: Error?
            var saved = false
            defer {
                DispatchQueue.main.async {
                    defer { self.photoWork.leave() }
                    guard self.epoch.isCurrent(token) else { return }
                    self.pendingHighResSaves -= 1
                    if saved {
                        self.capturedPoses.append(pose)
                        self.highResFrameCount = self.capturedPoses.count
                        self.updateParallaxHint()
                    } else {
                        self.scanError = "A photo could not be saved. Existing photos are kept. \(failure?.localizedDescription ?? "JPEG encoding failed")"
                    }
                }
            }
            let temporary = folder.appendingPathComponent(".pending-\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent),
                  let dest = CGImageDestinationCreateWithURL(temporary as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
            let exif: [CFString: Any] = [
                kCGImagePropertyExifFocalLength: physicalFocalMM,
                kCGImagePropertyExifFocalLenIn35mmFilm: Int(focalLength35mm),
                kCGImagePropertyExifPixelXDimension: w,
                kCGImagePropertyExifPixelYDimension: h
            ]
            let tiff: [CFString: Any] = [
                kCGImagePropertyTIFFMake: "Apple",
                kCGImagePropertyTIFFModel: "iPhone"
            ]
            let properties: [CFString: Any] = [
                kCGImagePropertyExifDictionary: exif,
                kCGImagePropertyTIFFDictionary: tiff,
                kCGImagePropertyOrientation: 1,
                kCGImageDestinationLossyCompressionQuality: 0.9
            ]
            CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return }
            do {
                try FileManager.default.moveItem(at: temporary, to: url)
                var poses = try PoseFile.read(forPhotoFolder: folder)
                poses.append(pose)
                try PoseFile.write(poses, forPhotoFolder: folder)
                saved = true
            } catch { failure = error }
        }
    }

    /// Photogrammetry and splats need the camera to MOVE between photos, not
    /// just turn. Warn if the photos all come from roughly one spot.
    private func updateParallaxHint() {
        guard capturedPoses.count >= 15, capturedPoses.count % 5 == 0 else { return }
        let positions = capturedPoses.map { $0.transform.position }
        let centre = positions.reduce(SIMD3<Float>(0, 0, 0)) { $0 + $1 } / Float(positions.count)
        let spread = (positions.map { simd_distance_squared($0, centre) }.reduce(0, +) / Float(positions.count)).squareRoot()
        let hint: String? = spread < 0.25 ? "Walk around the subject — turning on the spot gives a poor 3D result" : nil
        if hint != captureHint { captureHint = hint }
    }

    /// Folder of full-res photos for photogrammetry, or nil if not a High-Quality scan.
    func getPhotogrammetryInputURL() -> URL? {
        guard captureMode == .highQuality, let folder = captureFolderURL else { return nil }
        return folder
    }

    /// Folder of captured posed photos for splat export, or nil.
    func getCaptureFolderURL() -> URL? {
        guard captureMode == .splatExport || captureMode == .highQuality else { return nil }
        return captureFolderURL
    }

    // MARK: - Memory Monitoring

    private func startMemoryMonitor() {
        stopMemoryMonitor()
        memoryMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateMemoryStats()
        }
    }

    private func stopMemoryMonitor() {
        memoryMonitorTimer?.invalidate()
        memoryMonitorTimer = nil
    }

    private func updateMemoryStats() {
        let textureMemoryMB = textureMapper.estimatedMemoryUsageMB
        let meshMemoryMB = Double(vertexCount * 48 + faceCount * 12) / (1024.0 * 1024.0)
        let totalMB = textureMemoryMB + meshMemoryMB + Double(depthPointCount * 80) / 1_048_576
        let estFileMB = Double(vertexCount * 80 + faceCount * 30) / (1024.0 * 1024.0)
        let available = Self.availableMemoryMB()

        memoryUsageMB = totalMB
        estimatedFileSizeMB = estFileMB + textureMapper.estimatedAtlasSizeMB
        // Capacity = share of the app's real memory budget in use.
        scanCapacityPercent = min(100, max(0, 100 * (1 - (available - pauseScanBelowMB) / 2000)))

        if (available < pauseTexturesBelowMB || textureMemoryMB > maxTextureMemoryMB) && !textureCapturePaused {
            textureCapturePaused = true
            scanProgress = "Photo capture paused (memory) — scan continues"
            DebugLogger.shared.warn("Texture capture paused: available=\(Int(available))MB", category: "Scanner")
        }

        // Pause (not stop) so the user can still tap Stop and save everything.
        if available < pauseScanBelowMB && !isPaused {
            pauseScanning()
            scanProgress = "Memory nearly full — tap Stop to save"
            scanError = "Your phone is running out of memory, so scanning was paused. Tap Stop to save what you have."
            DebugLogger.shared.error("Low memory: \(Int(available))MB available, pausing", category: "Scanner")
        }
    }

    /// Memory the app can still use before iOS terminates it (MB).
    static func availableMemoryMB() -> Double {
        let bytes = os_proc_available_memory()
        return bytes > 0 ? Double(bytes) / 1_048_576 : 1024
    }

    // MARK: - Mesh Data Access

    /// Combine the scan into one mesh on a background queue.
    /// Copy the Metal buffer bytes on the delegate/main queue before dispatching.
    /// Retaining an ARMeshAnchor alone does not give a worker owned geometry.
    func buildCombinedMesh(completion: @escaping (MeshData?) -> Void) {
        let anchors = meshAnchors.map(MeshAnchorSnapshot.init) + Array(retiredMeshSnapshots.values)
        let evidence = depthCloud.surfaceEvidence
        let mode = meshMode
        let wantCameraColors = captureTexture && captureMode == .fast
        let mapper = textureMapper
        let cloud = (captureMode == .pointCloud || captureMode == .splatExport) ? depthCloud : nil

        DispatchQueue.global(qos: .userInitiated).async {
            // Point modes: the depth-sensor cloud is far denser than mesh vertices.
            if let cloudMesh = cloud?.pointCloud() {
                DispatchQueue.main.async { completion(cloudMesh) }
                return
            }
            var mesh = LiDARScanner.combine(anchors: anchors, evidence: evidence, meshMode: mode)
            if let m = mesh, wantCameraColors, mapper.frameCount > 0 {
                let colors = mapper.sampleVertexColors(vertices: m.vertices, normals: m.normals)
                mesh = MeshData(vertices: m.vertices, normals: m.normals, faces: m.faces, colors: colors,
                                boundingBoxMin: m.boundingBoxMin, boundingBoxMax: m.boundingBoxMax)
            }
            DispatchQueue.main.async { completion(mesh) }
        }
    }

    /// Merge anchors into world space, keeping triangles within `range` of the
    /// walked path whose ARKit classification passes the mesh mode.
    private static func combine(anchors: [MeshAnchorSnapshot], evidence: CapturedSurfaceIndex,
                                meshMode: ScanSettings.MeshMode) -> MeshData? {
        guard !anchors.isEmpty else { return nil }

        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allFaces: [[UInt32]] = []
        var allColors: [SIMD4<Float>] = []

        for anchor in anchors {
            let transform = anchor.transform

            let geometry = anchor.geometry
            let vertexCount = geometry.vertices.count
            let rotation = simd_float3x3(
                SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            )

            var world = [SIMD3<Float>](repeating: .zero, count: vertexCount)
            var inRange = [Bool](repeating: false, count: vertexCount)
            for i in 0..<vertexCount {
                let v = geometry.vertex(at: UInt32(i))
                let w = transform * SIMD4<Float>(v.x, v.y, v.z, 1)
                world[i] = SIMD3<Float>(w.x, w.y, w.z)
                inRange[i] = evidence.contains(world[i])
            }

            // ARKit classifies FACES (one UInt8 per triangle), not vertices.
            var localIndex = [Int32](repeating: -1, count: vertexCount)

            for f in 0..<geometry.faceCount {
                let indices = geometry.vertexIndicesOf(face: f)
                guard indices.count == 3,
                      indices.allSatisfy({ Int($0) < vertexCount && inRange[Int($0)] }) else { continue }
                // Do not bridge a hole / unseen background with a large triangle.
                let a = world[Int(indices[0])], b = world[Int(indices[1])], c = world[Int(indices[2])]
                guard evidence.contains((a + b + c) / 3), evidence.contains((a + b) / 2),
                      evidence.contains((b + c) / 2), evidence.contains((c + a) / 2) else { continue }

                let faceClass = geometry.classificationOf(face: f)
                guard meshMode.includes(classification: faceClass) else { continue }

                var mapped: [UInt32] = []
                mapped.reserveCapacity(3)
                for vi in indices {
                    let v = Int(vi)
                    if localIndex[v] < 0 {
                        localIndex[v] = Int32(allVertices.count)
                        allVertices.append(world[v])
                        let n = rotation * geometry.normal(at: vi)
                        let len = simd_length(n)
                        allNormals.append(len > 1e-6 ? n / len : SIMD3<Float>(0, 1, 0))
                        allColors.append(colorForClassification(faceClass))
                    }
                    mapped.append(UInt32(localIndex[v]))
                }
                allFaces.append(mapped)
            }
        }

        guard !allVertices.isEmpty else { return nil }
        let (minB, maxB) = MeshData.bounds(of: allVertices)
        return MeshData(vertices: allVertices, normals: allNormals, faces: allFaces, colors: allColors,
                        boundingBoxMin: minB, boundingBoxMax: maxB)
    }

    /// Build clean room geometry from detected planes (for Area mode)
    func getPlaneBasedMeshData() -> MeshData? {
        let planes = planeAnchors
        guard !planes.isEmpty else { return nil }

        let index = PathRangeIndex(points: cameraPath.isEmpty ? [scanOrigin] : cameraPath, radius: rangeMeters)
        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allFaces: [[UInt32]] = []
        var allColors: [SIMD4<Float>] = []

        for plane in planes {
            let transform = plane.transform
            guard index.contains(transform.position) else { continue }

            let color: SIMD4<Float>
            switch plane.classification {
            case .floor: color = SIMD4<Float>(0.6, 0.6, 0.65, 1.0)
            case .ceiling: color = SIMD4<Float>(0.85, 0.85, 0.9, 1.0)
            case .wall: color = SIMD4<Float>(0.9, 0.9, 0.85, 1.0)
            case .door: color = SIMD4<Float>(0.55, 0.35, 0.15, 1.0)
            case .window: color = SIMD4<Float>(0.5, 0.7, 0.9, 1.0)
            default: continue   // non-structural planes
            }

            let hw = plane.extent.x / 2.0
            let hz = plane.extent.z / 2.0
            let subdivisions = 4
            let baseIndex = UInt32(allVertices.count)
            let rotation = simd_float3x3(
                SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            )
            let worldNormal = simd_normalize(rotation * SIMD3<Float>(0, 1, 0))

            for row in 0...subdivisions {
                for col in 0...subdivisions {
                    let lx = -hw + (2.0 * hw) * Float(col) / Float(subdivisions)
                    let lz = -hz + (2.0 * hz) * Float(row) / Float(subdivisions)
                    let worldPos = transform * SIMD4<Float>(plane.center.x + lx, plane.center.y, plane.center.z + lz, 1.0)
                    allVertices.append(SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z))
                    allNormals.append(worldNormal)
                    allColors.append(color)
                }
            }

            let stride = UInt32(subdivisions + 1)
            for row in 0..<UInt32(subdivisions) {
                for col in 0..<UInt32(subdivisions) {
                    let tl = baseIndex + row * stride + col
                    let tr = tl + 1
                    let bl = tl + stride
                    let br = bl + 1
                    allFaces.append([tl, bl, tr])
                    allFaces.append([tr, bl, br])
                }
            }
        }

        guard !allVertices.isEmpty else { return nil }
        let (minB, maxB) = MeshData.bounds(of: allVertices)
        return MeshData(vertices: allVertices, normals: allNormals, faces: allFaces, colors: allColors,
                        boundingBoxMin: minB, boundingBoxMax: maxB)
    }

    /// Bake a high-resolution UV texture atlas for the given mesh (any thread).
    func bakeTexture(meshData: MeshData) -> BakedTexture? {
        textureMapper.bakeTexture(meshData: meshData, atlasSize: scanQuality.bakeAtlasSize)
    }

    // MARK: - Counts for display

    private func updateMeshCounts() {
        var totalVertices = 0
        var totalFaces = 0
        for anchor in meshAnchorsByID.values where anchorPathIndex.contains(anchor.transform.position) {
            totalVertices += anchor.geometry.vertices.count
            totalFaces += anchor.geometry.faces.count
        }
        if totalVertices != vertexCount { vertexCount = totalVertices }
        if totalFaces != faceCount { faceCount = totalFaces }
    }

    // MARK: - Helpers

    private static func colorForClassification(_ classIndex: UInt8) -> SIMD4<Float> {
        switch ARMeshClassification(rawValue: Int(classIndex)) {
        case .ceiling: return SIMD4<Float>(0.8, 0.8, 0.9, 1.0)
        case .door: return SIMD4<Float>(0.6, 0.4, 0.2, 1.0)
        case .floor: return SIMD4<Float>(0.5, 0.5, 0.5, 1.0)
        case .seat: return SIMD4<Float>(0.3, 0.6, 0.3, 1.0)
        case .table: return SIMD4<Float>(0.6, 0.4, 0.1, 1.0)
        case .wall: return SIMD4<Float>(0.9, 0.9, 0.85, 1.0)
        case .window: return SIMD4<Float>(0.5, 0.7, 0.9, 1.0)
        default: return SIMD4<Float>(0.7, 0.7, 0.7, 1.0)
        }
    }

    static func trackingMessage(for state: ARCamera.TrackingState) -> String? {
        switch state {
        case .normal:
            return nil
        case .notAvailable:
            return "Tracking unavailable"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: return "Move slower"
            case .insufficientFeatures: return "Too little detail — add light or aim at textured surfaces"
            case .initializing: return "Starting up — move the phone slowly"
            case .relocalizing: return "Finding position — return to where you were"
            @unknown default: return "Tracking limited"
            }
        }
    }
}

// MARK: - ARSessionDelegate
// Delegate callbacks arrive on the main queue (ARSession.delegateQueue is nil).

extension LiDARScanner: ARSessionDelegate {
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard session === arSession else { return }
        handle(anchors: anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard session === arSession else { return }
        handle(anchors: anchors)
    }

    private func handle(anchors: [ARAnchor]) {
        guard isScanning, !isPaused else { return }
        var meshChanged = false
        var planesChanged = false
        for anchor in anchors {
            if let mesh = anchor as? ARMeshAnchor {
                retiredMeshSnapshots.removeValue(forKey: mesh.identifier)
                meshAnchorsByID[mesh.identifier] = mesh
                meshChanged = true
            } else if let plane = anchor as? ARPlaneAnchor {
                planeAnchorsByID[plane.identifier] = plane
                planesChanged = true
            }
        }
        if meshChanged { updateMeshCounts() }
        if planesChanged && detectedPlaneCount != planeAnchorsByID.count {
            detectedPlaneCount = planeAnchorsByID.count
        }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        guard session === arSession, isScanning else { return }
        var meshChanged = false
        for anchor in anchors {
            if let removed = meshAnchorsByID.removeValue(forKey: anchor.identifier) {
                retiredMeshSnapshots[anchor.identifier] = MeshAnchorSnapshot(removed)
                meshChanged = true
            }
            planeAnchorsByID.removeValue(forKey: anchor.identifier)
        }
        if meshChanged { updateMeshCounts() }
        detectedPlaneCount = planeAnchorsByID.count
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        guard session === arSession else { return }
        let message = LiDARScanner.trackingMessage(for: camera.trackingState)
        if message != trackingWarning { trackingWarning = message }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        guard session === arSession else { return }
        scanError = "AR Session Error: \(error.localizedDescription)"
        if isScanning { pauseScanning(); needsRecoveryCheckpoint = true }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        guard session === arSession else { return }
        scanProgress = "Session interrupted"
        isPaused = true
        stopFrameCapture()
        if isScanning { needsRecoveryCheckpoint = true }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        guard session === arSession else { return }
        scanProgress = "Capture interrupted — save the checkpoint or start a new scan"
        // Never silently assume the interrupted AR coordinate frame is unchanged.
    }
}

/// A background checkpoint must not keep reading buffers owned by an updating
/// ARKit session. Data(bytes:count:) makes an owned copy, preserving packed float3
/// layout (12 bytes, not SIMD3's 16-byte stride) and per-source offsets/strides.
private struct MeshAnchorSnapshot {
    let transform: simd_float4x4
    let geometry: Geometry

    init(_ anchor: ARMeshAnchor) {
        transform = anchor.transform
        geometry = Geometry(anchor.geometry)
    }

    struct Source {
        let bytes: Data
        let count: Int
        let offset: Int
        let stride: Int

        init(_ source: ARGeometrySource) {
            bytes = Data(bytes: source.buffer.contents(), count: source.buffer.length)
            count = source.count
            offset = source.offset
            stride = source.stride
        }

        func vector(at index: UInt32) -> SIMD3<Float> {
            let start = offset + stride * Int(index)
            return bytes.withUnsafeBytes { data in
                SIMD3<Float>(data.loadUnaligned(fromByteOffset: start, as: Float.self),
                             data.loadUnaligned(fromByteOffset: start + 4, as: Float.self),
                             data.loadUnaligned(fromByteOffset: start + 8, as: Float.self))
            }
        }
    }

    struct Geometry {
        let vertices: Source
        let normals: Source
        let classifications: Source?
        let faces: Data
        let faceCount: Int
        let indicesPerFace: Int
        let bytesPerIndex: Int

        init(_ geometry: ARMeshGeometry) {
            vertices = Source(geometry.vertices)
            normals = Source(geometry.normals)
            classifications = geometry.classification.map(Source.init)
            faces = Data(bytes: geometry.faces.buffer.contents(), count: geometry.faces.buffer.length)
            faceCount = geometry.faces.count
            indicesPerFace = geometry.faces.indexCountPerPrimitive
            bytesPerIndex = geometry.faces.bytesPerIndex
        }

        func vertex(at index: UInt32) -> SIMD3<Float> { vertices.vector(at: index) }
        func normal(at index: UInt32) -> SIMD3<Float> { normals.vector(at: index) }

        func vertexIndicesOf(face: Int) -> [UInt32] {
            guard indicesPerFace == 3, bytesPerIndex == 2 || bytesPerIndex == 4 else { return [] }
            return faces.withUnsafeBytes { data in
                (0..<3).map { corner in
                    let start = (face * 3 + corner) * bytesPerIndex
                    return bytesPerIndex == 4
                        ? data.loadUnaligned(fromByteOffset: start, as: UInt32.self)
                        : UInt32(data.loadUnaligned(fromByteOffset: start, as: UInt16.self))
                }
            }
        }

        func classificationOf(face: Int) -> UInt8 {
            guard let source = classifications, face < source.count else { return 0 }
            return source.bytes[source.offset + source.stride * face]
        }
    }
}

// MARK: - LiDAR depth point cloud

/// Builds a dense coloured point cloud straight from the LiDAR depth maps
/// (much denser than mesh vertices). Points are merged into a voxel grid at the
/// Detail setting, so 5 mm really means one point per 5 mm cube.
final class DepthPointAccumulator {
    private struct Cell {
        var position = SIMD3<Float>(0, 0, 0)
        var color = SIMD3<Float>(0, 0, 0)
        var count: Float = 0
    }

    private let queue = DispatchQueue(label: "scanview.depthcloud", qos: .utility)
    private let epoch = CaptureEpoch()
    private let lock = NSLock()
    private var cells: [SIMD3<Int32>: Cell] = [:]
    private var voxelSize: Float = 0.01
    private var maxPoints = 2_000_000
    private var full = false
    private var inFlight = false          // main thread
    private var evidence = CapturedSurfaceIndex()
    private var coverage: AcceptedDepthFrame?

    var acceptedFrame: AcceptedDepthFrame? {
        lock.lock(); defer { lock.unlock() }; return coverage
    }
    var surfaceEvidence: CapturedSurfaceIndex {
        lock.lock(); defer { lock.unlock() }; return evidence
    }

    var pointCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cells.count
    }

    func configure(voxelSize: Float, maxPoints: Int) {
        lock.lock()
        self.voxelSize = voxelSize
        self.maxPoints = max(100_000, maxPoints)
        lock.unlock()
    }

    func reset() {
        epoch.invalidate()
        inFlight = false
        lock.lock()
        cells.removeAll()
        evidence = CapturedSurfaceIndex()
        coverage = nil
        full = false
        lock.unlock()
    }

    func drain(completion: @escaping () -> Void) {
        queue.async { DispatchQueue.main.async(execute: completion) }
    }

    /// Main thread. Converts one frame in the background (one at a time, so
    /// ARKit's camera buffers are never held for long).
    func integrate(_ frame: ARFrame, maxDistance: Float, onUpdate: @escaping (Int, Bool) -> Void) {
        guard !inFlight, let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let sensor = CaptureDepthFrame(frame) else { return }
        inFlight = true
        let token = epoch.current
        let depthMap = depthData.depthMap
        let confidence = depthData.confidenceMap
        let image = frame.capturedImage
        let transform = frame.camera.transform
        let intrinsics = frame.camera.intrinsics
        let imageW = Float(CVPixelBufferGetWidth(image)), imageH = Float(CVPixelBufferGetHeight(image))

        queue.async { [weak self] in
            guard let self = self else { return }
            let batch = DepthPointAccumulator.points(depth: depthMap, confidence: confidence, image: image,
                                                     transform: transform, intrinsics: intrinsics,
                                                     imageSize: SIMD2<Float>(imageW, imageH), maxDistance: maxDistance)
            var count = 0
            var isFull = false
            self.epoch.withCurrent(token) {
                self.lock.lock()
                defer { self.lock.unlock() }
                let inv = 1 / self.voxelSize
                var acceptedDepth = [Float](repeating: 0, count: sensor.depth.count)
                for (p, c, pixel) in batch {
                    let s = p * inv
                    let key = SIMD3<Int32>(Int32(s.x.rounded(.down)), Int32(s.y.rounded(.down)), Int32(s.z.rounded(.down)))
                    if var cell = self.cells[key] {
                        // Keep a real accepted point (not an average that can
                        // move beyond the range boundary); average only colour.
                        if cell.count < 1000 { cell.color += c; cell.count += 1 }
                        self.cells[key] = cell
                    } else if self.cells.count < self.maxPoints {
                        self.cells[key] = Cell(position: p, color: c, count: 1)
                    } else {
                        self.full = true
                        continue
                    }
                    if self.evidence.insert(p, camera: transform.position, range: maxDistance) {
                        acceptedDepth[pixel] = sensor.depth[pixel]
                    } else { self.full = true }
                }
                self.coverage = AcceptedDepthFrame(frame: sensor, depth: acceptedDepth)
                count = self.cells.count
                isFull = self.full
            }
            DispatchQueue.main.async {
                guard self.epoch.isCurrent(token) else { return }
                self.inFlight = false
                onUpdate(count, isFull)
            }
        }
    }

    /// World-space points with camera colours from one frame.
    private static func points(depth: CVPixelBuffer, confidence: CVPixelBuffer?, image: CVPixelBuffer,
                               transform: simd_float4x4, intrinsics: simd_float3x3,
                               imageSize: SIMD2<Float>, maxDistance: Float) -> [(SIMD3<Float>, SIMD3<Float>, Int)] {
        guard CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32 else { return [] }
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        if let c = confidence { CVPixelBufferLockBaseAddress(c, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depth, .readOnly)
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            if let c = confidence { CVPixelBufferUnlockBaseAddress(c, .readOnly) }
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(depth) else { return [] }
        let dw = CVPixelBufferGetWidth(depth), dh = CVPixelBufferGetHeight(depth)
        let depthRow = CVPixelBufferGetBytesPerRow(depth)
        let confBase = confidence.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confRow = confidence.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        // Camera colour (YCbCr 4:2:0 full range, as ARKit delivers it).
        let isYCbCr = CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            && CVPixelBufferGetPlaneCount(image) >= 2
        let yBase = isYCbCr ? CVPixelBufferGetBaseAddressOfPlane(image, 0) : nil
        let cBase = isYCbCr ? CVPixelBufferGetBaseAddressOfPlane(image, 1) : nil
        let yRow = isYCbCr ? CVPixelBufferGetBytesPerRowOfPlane(image, 0) : 0
        let cRow = isYCbCr ? CVPixelBufferGetBytesPerRowOfPlane(image, 1) : 0
        let iw = Int(imageSize.x), ih = Int(imageSize.y)

        // Intrinsics are for the camera image; scale them to the depth map.
        let sx = Float(dw) / imageSize.x, sy = Float(dh) / imageSize.y
        let fx = intrinsics[0][0] * sx, fy = intrinsics[1][1] * sy
        let cx = intrinsics[2][0] * sx, cy = intrinsics[2][1] * sy

        var out: [(SIMD3<Float>, SIMD3<Float>, Int)] = []
        out.reserveCapacity(dw * dh)
        for y in 0..<dh {
            let depthRowPtr = depthBase.advanced(by: y * depthRow).assumingMemoryBound(to: Float32.self)
            for x in 0..<dw {
                let d = depthRowPtr[x]
                guard d.isFinite, d > 0.1, d <= maxDistance else { continue }
                if let cb = confBase {
                    // ARConfidenceLevel: 0 low, 1 medium, 2 high. Far points need high.
                    let conf = cb.advanced(by: y * confRow + x).assumingMemoryBound(to: UInt8.self).pointee
                    if conf < 1 || (d > 3 && conf < 2) { continue }
                }
                // Pixel → camera (vision convention) → ARKit camera space (Y up, -Z forward).
                let u = Float(x) + 0.5, v = Float(y) + 0.5
                let xc = (u - cx) / fx * d
                let yc = (v - cy) / fy * d
                guard CaptureRange.accepts(SIMD3(xc, -yc, -d), metres: maxDistance) else { continue }
                let w = transform * SIMD4<Float>(xc, -yc, -d, 1)

                var color = SIMD3<Float>(0.7, 0.7, 0.7)
                if let yb = yBase, let cb2 = cBase {
                    let ix = min(iw - 1, Int(u / sx)), iy = min(ih - 1, Int(v / sy))
                    let yy = Float(yb.advanced(by: iy * yRow + ix).assumingMemoryBound(to: UInt8.self).pointee)
                    let cptr = cb2.advanced(by: (iy / 2) * cRow + (ix / 2) * 2).assumingMemoryBound(to: UInt8.self)
                    let cbv = Float(cptr[0]) - 128, crv = Float(cptr[1]) - 128
                    color = SIMD3<Float>(yy + 1.402 * crv, yy - 0.344136 * cbv - 0.714136 * crv, yy + 1.772 * cbv) / 255
                    color = simd_clamp(color, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
                }
                out.append((SIMD3<Float>(w.x, w.y, w.z), color, y * dw + x))
            }
        }
        return out
    }

    /// Averaged point per voxel, ready to save / view.
    func pointCloud() -> MeshData? {
        lock.lock()
        let snapshot = cells
        lock.unlock()
        guard !snapshot.isEmpty else { return nil }
        var vertices: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>] = []
        vertices.reserveCapacity(snapshot.count)
        colors.reserveCapacity(snapshot.count)
        for cell in snapshot.values {
            vertices.append(cell.position)
            let c = cell.color / cell.count
            colors.append(SIMD4<Float>(c.x, c.y, c.z, 1))
        }
        let (minB, maxB) = MeshData.bounds(of: vertices)
        return MeshData(vertices: vertices, normals: [], faces: [], colors: colors,
                        boundingBoxMin: minB, boundingBoxMax: maxB)
    }
}
#endif

// MARK: - Shared types (device + simulator)

/// ARKit's camera pose for each High-Quality photo. Stored NEXT TO the photo
/// folder ("<folder>_poses.json"), not inside it, so the photogrammetry input
/// folder only ever contains images.
enum PoseFile {
    static let suffix = "_poses.json"

    private struct Entry: Codable {
        let index: Int
        let width: Int
        let height: Int
        let transform: [Float]
        let intrinsics: [Float]
        let rangeMask: PhotoRangeMask?
    }

    static func write(_ poses: [CapturedPose], forPhotoFolder folder: URL) throws {
        let entries = poses.map { pose -> Entry in
            let m = pose.transform
            let k = pose.intrinsics
            return Entry(index: pose.index, width: pose.width, height: pose.height,
                         transform: [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] },
                         intrinsics: [k.columns.0, k.columns.1, k.columns.2].flatMap { [$0.x, $0.y, $0.z] }, rangeMask: pose.rangeMask)
        }
        try JSONEncoder().encode(entries).write(to: url(forPhotoFolder: folder), options: .atomic)
    }

    static func read(forPhotoFolder folder: URL) throws -> [CapturedPose] {
        let file = url(forPhotoFolder: folder)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
        var seen = Set<Int>()
        return try entries.map { entry in
            let k = entry.intrinsics
            guard entry.index >= 0, seen.insert(entry.index).inserted, entry.width > 0, entry.height > 0,
                  entry.transform.count == 16, entry.transform.allSatisfy({ $0.isFinite }),
                  k.count == 9, k.allSatisfy({ $0.isFinite }), k[0] > 0, k[4] > 0,
                  let transform = Scan.matrix(entry.transform), entry.rangeMask?.isValid != false else { throw CocoaError(.fileReadCorruptFile) }
            return CapturedPose(index: entry.index, transform: transform,
                intrinsics: simd_float3x3(SIMD3(k[0], k[1], k[2]), SIMD3(k[3], k[4], k[5]), SIMD3(k[6], k[7], k[8])),
                width: entry.width, height: entry.height, rangeMask: entry.rangeMask)
        }
    }

    static func url(forPhotoFolder folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + suffix)
    }

    /// Camera positions by photo index (world space, metres).
    static func cameraPositions(forPhotoFolder folder: URL) -> [Int: SIMD3<Float>] {
        guard let data = try? Data(contentsOf: url(forPhotoFolder: folder)),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var result: [Int: SIMD3<Float>] = [:]
        for entry in list {
            guard let index = entry["index"] as? Int,
                  let t = entry["transform"] as? [Double], t.count == 16 else { continue }
            result[index] = SIMD3<Float>(Float(t[12]), Float(t[13]), Float(t[14]))
        }
        return result
    }
}

/// Combined mesh data from all scan anchors
struct MeshData: Codable {
    let vertices: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let faces: [[UInt32]]
    let colors: [SIMD4<Float>]
    let boundingBoxMin: SIMD3<Float>
    let boundingBoxMax: SIMD3<Float>

    var vertexCount: Int { vertices.count }
    var faceCount: Int { faces.count }

    var dimensions: SIMD3<Float> {
        return boundingBoxMax - boundingBoxMin
    }

    static func bounds(of points: [SIMD3<Float>]) -> (SIMD3<Float>, SIMD3<Float>) {
        guard var minB = points.first else { return (.zero, .zero) }
        var maxB = minB
        for p in points {
            minB = simd_min(minB, p)
            maxB = simd_max(maxB, p)
        }
        return (minB, maxB)
    }
}

/// Answers "is this point within `radius` of any path point?" in roughly constant
/// time, using a hash grid with cell size = radius (only 27 cells are checked).
struct PathRangeIndex {
    private let radius: Float
    private let radiusSq: Float
    private var cells: [SIMD3<Int32>: [SIMD3<Float>]] = [:]

    init(points: [SIMD3<Float>], radius: Float) {
        self.radius = max(radius, 0.01)
        self.radiusSq = self.radius * self.radius
        for p in points { insert(p) }
    }

    mutating func insert(_ p: SIMD3<Float>) {
        guard let k = cellKey(p) else { return }
        cells[k, default: []].append(p)
    }

    func contains(_ p: SIMD3<Float>) -> Bool {
        guard let k = cellKey(p) else { return false }
        for dx: Int32 in -1...1 {
            for dy: Int32 in -1...1 {
                for dz: Int32 in -1...1 {
                    guard let bucket = cells[SIMD3<Int32>(k.x + dx, k.y + dy, k.z + dz)] else { continue }
                    for c in bucket where simd_distance_squared(c, p) <= radiusSq {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func cellKey(_ p: SIMD3<Float>) -> SIMD3<Int32>? {
        let s = p / radius
        guard s.x.isFinite, s.y.isFinite, s.z.isFinite,
              abs(s.x) < 1e6, abs(s.y) < 1e6, abs(s.z) < 1e6 else { return nil }
        return SIMD3<Int32>(Int32(s.x.rounded(.down)), Int32(s.y.rounded(.down)), Int32(s.z.rounded(.down)))
    }
}
