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
    /// Share of the scan's point/coverage budget in use (0–100).
    @Published var captureBudgetPercent: Double = 0
    private var tooFastSince: TimeInterval?
    static let slowDownHint = "Slow down — moving too fast for sharp photos"
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

        let dense = captureMode == .pointCloud || captureMode == .splatExport
        let limits = Self.captureLimits(dense: dense, detailMM: detailMM, availableMB: Self.availableMemoryMB())
        guard limits.coverageCells > 0, !dense || limits.points > 0 else {
            scanError = "Not enough memory to capture and safely save a scan. Close other apps and try again."
            startPreview()
            return
        }
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
        depthCloud.configure(voxelSize: limits.voxelSize, maxPoints: limits.points, coverageCells: limits.coverageCells)

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
        // Full: resuming would only leave new areas out. Save instead.
        guard !pointBudgetReached else {
            scanError = "This scan is at full capacity. Tap Stop to save it, then start a new scan for the next area."
            return
        }
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
        // Stored-photo callbacks enqueue work on depthCloud. Drain that queue
        // AFTER the mapper has delivered every callback, not in parallel.
        textureMapper.drain { [weak self] in
            guard let self else { draining.leave(); return }
            self.depthCloud.drain { draining.leave() }
        }
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
        guard !pointBudgetReached else {
            scanError = "This scan is at full capacity. Save it, then start a new scan for the next area."
            return
        }
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
        captureBudgetPercent = 0
        tooFastSince = nil
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
            _ = textureMapper.captureFrame(from: frame, exposure: currentExposure(), onCountChanged: { [weak self] count, _ in
                guard let self, self.epoch.isCurrent(token) else { return }
                self.capturedFrameCount = count
            }, onStored: { [weak self] id, sensor, retained in
                guard let self, self.epoch.isCurrent(token) else { return }
                self.depthCloud.commitPhoto(id: id, sensor: sensor, retained: retained, range: self.rangeMeters)
            })
            // Warn when moving too fast for sharp photos (those areas would come out soft/grey).
            if blurPixels > 2.5 {
                if tooFastSince == nil { tooFastSince = now }
                if let since = tooFastSince, now - since > 0.4, captureHint != Self.slowDownHint {
                    captureHint = Self.slowDownHint
                }
            } else {
                tooFastSince = nil
                if captureHint == Self.slowDownHint { captureHint = nil }
            }
        } else {
            tooFastSince = nil
            if captureHint == Self.slowDownHint { captureHint = nil }
        }

        // Commit depth before showing coverage; one worker is in flight at most.
        do {
            // Memory-paused photo capture must not change the meaning of mint.
            let photoCoverage = captureMode == .fast && captureTexture
            depthCloud.integrate(frame, maxDistance: min(rangeMeters, 5),
                                 photoCoverage: photoCoverage) { [weak self] count, full, used in
                guard let self = self, self.epoch.isCurrent(token) else { return }
                self.depthPointCount = count
                self.captureBudgetPercent = used * 100
                if full && !self.pointBudgetReached {
                    // Stop here rather than keep scanning while new areas are quietly left out.
                    self.pointBudgetReached = true
                    if !self.isPaused { self.pauseScanning() }
                    self.scanProgress = "Scan capacity full — tap Stop to save"
                    self.scanError = "This scan has reached its capacity, so scanning was paused. Everything captured so far is kept. Tap Stop to save it, then start a new scan for the next area."
                    DebugLogger.shared.warn("Capture budget full: \(count) points, \(Int(used * 100))%", category: "Scanner")
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
            // Mark range-aware captures before the first photo. An interrupted
            // pose write must never fall back to unmasked folder reconstruction.
            try PoseFile.write([], forPhotoFolder: dir, requireRangeMasks: true)
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
            + depthCloud.coverageMemoryMB
        let estFileMB = Double(vertexCount * 80 + faceCount * 30) / (1024.0 * 1024.0)
        let available = Self.availableMemoryMB()

        memoryUsageMB = totalMB
        estimatedFileSizeMB = estFileMB + textureMapper.estimatedAtlasSizeMB
        // Capacity = share of the app's real memory budget in use.
        let memoryPercent = min(100, max(0, 100 * (1 - (available - pauseScanBelowMB) / 2000)))
        scanCapacityPercent = max(memoryPercent, captureBudgetPercent)

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

    /// Memory the coverage index holds; a mid-scan checkpoint may briefly copy it.
    var coverageMemoryMB: Double { depthCloud.coverageMemoryMB }

    /// Memory the app can still use before iOS terminates it (MB).
    static func availableMemoryMB() -> Double {
        let bytes = os_proc_available_memory()
        return bytes > 0 ? Double(bytes) / 1_048_576 : 1024
    }

    /// How much a capture may hold, from the memory free when it starts.
    /// Coverage cells (2.5 cm) and saved points (one per `detailMM`) share one
    /// budget sized by surface area, so coarser spacing really covers more
    /// ground. Leave headroom for checkpointing and final saving; fixed minimums
    /// must not override the actual memory budget on a smaller device.
    static func captureLimits(dense: Bool, detailMM: Float, availableMB: Double)
        -> (voxelSize: Float, points: Int, coverageCells: Int) {
        CaptureBudget.limits(dense: dense, detailMM: detailMM, availableMB: availableMB)
    }

    // MARK: - Mesh Data Access

    /// Combine the scan into one mesh on a background queue.
    /// Copy the Metal buffer bytes on the delegate/main queue before dispatching.
    /// Retaining an ARMeshAnchor alone does not give a worker owned geometry.
    /// - lightweight: skips expensive photo reprojection, retaining sampled
    ///   depth-camera vertex colour for a usable recovery checkpoint.
    func buildCombinedMesh(lightweight: Bool = false, completion: @escaping (MeshData?) -> Void) {
        let cloud = (captureMode == .pointCloud || captureMode == .splatExport) ? depthCloud : nil
        // Point modes return the depth cloud, so don't copy all mesh buffers for nothing.
        let anchors: [MeshAnchorSnapshot] = cloud != nil && cloud!.pointCount > 0 ? []
            : meshAnchors.map(MeshAnchorSnapshot.init) + Array(retiredMeshSnapshots.values)
        let depthSource = depthCloud
        let mode = meshMode
        let wantCameraColors = captureTexture && captureMode == .fast && !lightweight
        let mapper = textureMapper

        DispatchQueue.global(qos: .userInitiated).async {
            // Point modes: the depth-sensor cloud is far denser than mesh vertices.
            if let cloudMesh = cloud?.pointCloud() {
                DispatchQueue.main.async { completion(cloudMesh) }
                return
            }
            let evidence = depthSource.surfaceEvidence
            var mesh = LiDARScanner.combine(anchors: anchors, evidence: evidence, meshMode: mode)
            if let m = mesh, wantCameraColors, mapper.frameCount > 0 {
                let colors = mapper.sampleVertexColors(vertices: m.vertices, normals: m.normals, fallbackColors: m.colors)
                mesh = MeshData(vertices: m.vertices, normals: m.normals, faces: m.faces, colors: colors,
                                boundingBoxMin: m.boundingBoxMin, boundingBoxMax: m.boundingBoxMax)
            }
            DispatchQueue.main.async { completion(mesh) }
        }
    }

    /// Merge anchors into world space using actual observation-time range
    /// evidence and the requested ARKit classification filter.
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
            var observations = [CapturedSurfaceIndex.Sample?](repeating: nil, count: vertexCount)
            for i in 0..<vertexCount {
                let v = geometry.vertex(at: UInt32(i))
                let w = transform * SIMD4<Float>(v.x, v.y, v.z, 1)
                world[i] = SIMD3<Float>(w.x, w.y, w.z)
                observations[i] = evidence.sample(at: world[i])
            }

            // ARKit classifies FACES (one UInt8 per triangle), not vertices.
            var localIndex = [Int32](repeating: -1, count: vertexCount)

            for f in 0..<geometry.faceCount {
                let indices = geometry.vertexIndicesOf(face: f)
                guard indices.count == 3, indices.allSatisfy({ Int($0) < vertexCount }) else { continue }
                let a = world[Int(indices[0])], b = world[Int(indices[1])], c = world[Int(indices[2])]
                let cornerSamples = indices.compactMap { observations[Int($0)] }
                let centreSample = evidence.sample(at: (a + b + c) / 3, tolerance: 0.05)
                let samples = cornerSamples + (centreSample.map { [$0] } ?? [])
                // Keep Claude's small-face hole reduction, but only when the
                // ENTIRE face fits a recorded observation's range sphere.
                guard CapturedSurfaceIndex.withinObservedRange(a, b, c, observations: samples) else { continue }
                let longest = max(simd_distance(a, b), simd_distance(b, c), simd_distance(c, a))
                if longest > 0.25 {
                    // A long triangle may bridge a real gap or unseen background:
                    // keep it only if fully seen and its centre and edges were observed.
                    guard cornerSamples.count == 3, centreSample != nil, evidence.contains((a + b) / 2),
                          evidence.contains((b + c) / 2), evidence.contains((c + a) / 2) else { continue }
                }

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
                        // Real sampled colour is cheap and survives a lightweight
                        // checkpoint even when the temporary photo atlas is lost.
                        let rgb = observations[v]?.color ?? centreSample?.color ?? samples[0].color
                        allColors.append(SIMD4(rgb, 1))
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
    /// 0 = coverage only (Fast / HQ), no saved point cloud is kept.
    private var maxPoints = 2_000_000
    private var coverageCells = 600_000
    private var full = false
    private var inFlight = false          // main thread
    private var evidence = CapturedSurfaceIndex()
    private var coverage: AcceptedDepthFrame?
    private let coverageLock = NSLock()
    // Main-thread HUD reads never wait for a full depth-map integration.
    private var publishedPointCount = 0
    private var publishedCoverageCount = 0
    private var publishedBudgetFraction = 0.0

    var acceptedFrame: AcceptedDepthFrame? {
        coverageLock.lock(); defer { coverageLock.unlock() }; return coverage
    }
    var surfaceEvidence: CapturedSurfaceIndex {
        lock.lock(); defer { lock.unlock() }; return evidence
    }

    var pointCount: Int {
        coverageLock.lock(); defer { coverageLock.unlock() }
        return publishedPointCount
    }

    /// Share of the capture budget in use (0…1): coverage or points, whichever is fuller.
    var budgetFraction: Double {
        coverageLock.lock(); defer { coverageLock.unlock() }
        return publishedBudgetFraction
    }

    /// Approximate memory held by the coverage index (a checkpoint may copy it).
    var coverageMemoryMB: Double {
        coverageLock.lock(); defer { coverageLock.unlock() }
        return Double(publishedCoverageCount) * CaptureBudget.bytesPerEntry / 1_048_576
    }

    private func fraction() -> Double {
        let cover = Double(evidence.cells.count) / Double(max(1, evidence.capacity))
        let points = maxPoints > 0 ? Double(cells.count) / Double(maxPoints) : 0
        return min(1, max(cover, points))
    }

    func configure(voxelSize: Float, maxPoints: Int, coverageCells: Int) {
        lock.lock()
        self.voxelSize = voxelSize
        self.maxPoints = max(0, maxPoints)
        self.coverageCells = max(1, coverageCells)
        // Only an empty index is resized; captured coverage is never dropped.
        if evidence.cells.isEmpty { evidence = CapturedSurfaceIndex(capacity: self.coverageCells) }
        lock.unlock()
    }

    func reset() {
        epoch.invalidate()
        inFlight = false
        lock.lock()
        cells.removeAll()
        evidence = CapturedSurfaceIndex(capacity: coverageCells)
        coverageLock.lock()
        coverage = nil
        publishedPointCount = 0; publishedCoverageCount = 0; publishedBudgetFraction = 0
        coverageLock.unlock()
        full = false
        lock.unlock()
    }

    func drain(completion: @escaping () -> Void) {
        queue.async { DispatchQueue.main.async(execute: completion) }
    }

    /// Main thread. Converts one frame in the background (one at a time, so
    /// ARKit's camera buffers are never held for long).
    /// - photoCoverage: publish a separate mask of retained sharp-photo coverage.
    /// - Returns: false if skipped (previous frame still processing).
    @discardableResult
    func integrate(_ frame: ARFrame, maxDistance: Float, photoCoverage: Bool = false,
                   onUpdate: @escaping (Int, Bool, Double) -> Void) -> Bool {
        guard !inFlight, let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let confidence = depthData.confidenceMap,
              let sensor = CaptureDepthFrame(frame) else { return false }
        inFlight = true
        let token = epoch.current
        let depthMap = depthData.depthMap
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
            var used = 0.0
            self.epoch.withCurrent(token) {
                self.lock.lock()
                defer { self.lock.unlock() }
                let inv = 1 / self.voxelSize
                var acceptedDepth = [Float](repeating: 0, count: sensor.depth.count)
                var photoDepth = [Float](repeating: 0, count: photoCoverage ? sensor.depth.count : 0)
                let keepsPoints = self.maxPoints > 0
                for (p, c, pixel, reliable) in batch {
                    // Weak depth can retain OLD coverage below, never create new
                    // evidence for geometry that was not accepted into the scan.
                    guard reliable else { continue }
                    if keepsPoints && reliable {
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
                            continue
                        }
                    }
                    if self.evidence.insert(p, camera: transform.position, range: maxDistance, color: c) {
                        acceptedDepth[pixel] = sensor.depth[pixel]
                    }
                }
                // Full = a real capacity limit, not a point rejected at the range edge.
                if (keepsPoints && self.cells.count >= self.maxPoints)
                    || self.evidence.cells.count >= self.evidence.capacity { self.full = true }
                // Confidence can fluctuate on a surface already captured. Keep
                // its coverage if current depth still agrees with stored world
                // evidence; do not blink or add low-confidence geometry.
                for pixel in sensor.depth.indices where acceptedDepth[pixel] == 0 {
                    let cameraPoint = sensor.cameraPoint(at: pixel)
                    guard CaptureRange.accepts(cameraPoint, metres: maxDistance) else { continue }
                    let w = sensor.cameraToWorld * SIMD4(cameraPoint, 1)
                    if self.evidence.contains(SIMD3(w.x, w.y, w.z), tolerance: 0.035) {
                        acceptedDepth[pixel] = sensor.depth[pixel]
                    }
                }
                if photoCoverage {
                    for pixel in sensor.depth.indices where acceptedDepth[pixel] > 0 {
                        let w = sensor.cameraToWorld * SIMD4(sensor.cameraPoint(at: pixel), 1)
                        if self.evidence.isPhotographed(SIMD3(w.x, w.y, w.z)) {
                            photoDepth[pixel] = acceptedDepth[pixel]
                        }
                    }
                }
                self.coverageLock.lock()
                self.coverage = AcceptedDepthFrame(frame: sensor, depth: acceptedDepth, photoDepth: photoCoverage ? photoDepth : nil)
                self.publishedPointCount = self.cells.count
                self.publishedCoverageCount = self.evidence.cells.count
                self.publishedBudgetFraction = self.fraction()
                self.coverageLock.unlock()
                count = self.cells.count
                isFull = self.full
                used = self.fraction()
            }
            DispatchQueue.main.async {
                guard self.epoch.isCurrent(token) else { return }
                self.inFlight = false
                onUpdate(count, isFull, used)
            }
        }
        return true
    }

    /// Serialized with integration; the image has already been written. No
    /// pending flag is ever transferred to a later camera pose.
    func commitPhoto(id: Int, sensor: CaptureDepthFrame?, retained: Set<Int>, range: Float) {
        let token = epoch.current
        queue.async { [weak self] in
            guard let self else { return }
            self.epoch.withCurrent(token) {
                self.lock.lock(); defer { self.lock.unlock() }
                self.evidence.retainPhotos(retained)
                guard let sensor else { return }
                for pixel in sensor.depth.indices where sensor.accepts(pixel, range: range) {
                    let w = sensor.cameraToWorld * SIMD4(sensor.cameraPoint(at: pixel), 1)
                    self.evidence.markPhotographed(SIMD3(w.x, w.y, w.z), photoID: id)
                }
            }
        }
    }

    /// World-space points with camera colours from one frame.
    private static func points(depth: CVPixelBuffer, confidence: CVPixelBuffer?, image: CVPixelBuffer,
                               transform: simd_float4x4, intrinsics: simd_float3x3,
                               imageSize: SIMD2<Float>, maxDistance: Float) -> [(SIMD3<Float>, SIMD3<Float>, Int, Bool)] {
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

        var out: [(SIMD3<Float>, SIMD3<Float>, Int, Bool)] = []
        out.reserveCapacity(dw * dh)
        for y in 0..<dh {
            let depthRowPtr = depthBase.advanced(by: y * depthRow).assumingMemoryBound(to: Float32.self)
            for x in 0..<dw {
                let d = depthRowPtr[x]
                guard d.isFinite, d > 0.1, d <= maxDistance else { continue }
                // ARConfidenceLevel: 0 low, 1 medium, 2 high. Saved points need
                // medium (high when far). Weak depth can match previous evidence,
                // but must never add a new captured surface by itself.
                var reliable = true
                if let cb = confBase {
                    let conf = cb.advanced(by: y * confRow + x).assumingMemoryBound(to: UInt8.self).pointee
                    if d > 3 && conf < 1 { continue }
                    reliable = conf >= 1 && !(d > 3 && conf < 2)
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
                out.append((SIMD3<Float>(w.x, w.y, w.z), color, y * dw + x, reliable))
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

    private struct Envelope: Codable {
        let version: Int
        let requiresRangeMasks: Bool
        let entries: [Entry]
    }

    private static func envelope(for folder: URL) throws -> Envelope {
        let file = url(forPhotoFolder: folder)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return Envelope(version: 1, requiresRangeMasks: false, entries: [])
        }
        let data = try Data(contentsOf: file)
        // The original sidecar was a bare array. Keep those captures readable.
        if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 91 {
            return Envelope(version: 1, requiresRangeMasks: false,
                            entries: try JSONDecoder().decode([Entry].self, from: data))
        }
        let decoded = try JSONDecoder().decode(Envelope.self, from: data)
        guard decoded.version == 2 else { throw CocoaError(.fileReadCorruptFile) }
        return decoded
    }

    static func requiresRangeMasks(forPhotoFolder folder: URL) throws -> Bool {
        try envelope(for: folder).requiresRangeMasks
    }

    static func write(_ poses: [CapturedPose], forPhotoFolder folder: URL, requireRangeMasks: Bool = false) throws {
        let required = try requireRangeMasks || poses.contains { $0.rangeMask != nil } || envelope(for: folder).requiresRangeMasks
        guard !required || poses.allSatisfy({ $0.rangeMask?.isValid == true }) else { throw CocoaError(.fileReadCorruptFile) }
        let entries = poses.map { pose -> Entry in
            let m = pose.transform
            let k = pose.intrinsics
            return Entry(index: pose.index, width: pose.width, height: pose.height,
                         transform: [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] },
                         intrinsics: [k.columns.0, k.columns.1, k.columns.2].flatMap { [$0.x, $0.y, $0.z] }, rangeMask: pose.rangeMask)
        }
        try JSONEncoder().encode(Envelope(version: 2, requiresRangeMasks: required, entries: entries))
            .write(to: url(forPhotoFolder: folder), options: .atomic)
    }

    static func read(forPhotoFolder folder: URL) throws -> [CapturedPose] {
        let saved = try envelope(for: folder)
        let entries = saved.entries
        guard !saved.requiresRangeMasks || entries.allSatisfy({ $0.rangeMask?.isValid == true }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
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
        guard let poses = try? read(forPhotoFolder: folder) else { return [:] }
        return Dictionary(uniqueKeysWithValues: poses.map {
            ($0.index, SIMD3<Float>($0.transform.columns.3.x, $0.transform.columns.3.y, $0.transform.columns.3.z))
        })
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

    init(vertices: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [[UInt32]], colors: [SIMD4<Float>],
         boundingBoxMin: SIMD3<Float>, boundingBoxMax: SIMD3<Float>) {
        self.vertices = vertices
        self.normals = normals
        self.faces = faces
        self.colors = colors
        self.boundingBoxMin = boundingBoxMin
        self.boundingBoxMax = boundingBoxMax
    }

    // MARK: Compact encoding
    // Recovery checkpoints encode whole scans. The synthesized Codable form stores
    // every number as its own object (millions for a big scan → gigabytes of
    // memory while encoding). Instead each array is one packed binary blob.

    private enum CodingKeys: String, CodingKey {
        case packedVertices, packedNormals, packedFaces, packedColors, boundsMin, boundsMax
        case vertices, normals, faces, colors, boundingBoxMin, boundingBoxMax   // older format
    }

    func encode(to encoder: Encoder) throws {
        try validateCheckpoint()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(MeshData.pack(vertices), forKey: .packedVertices)
        try c.encode(MeshData.pack(normals), forKey: .packedNormals)
        var faceData = Data(capacity: faces.count * 12)
        for f in faces {
            for i in f { withUnsafeBytes(of: i.littleEndian) { faceData.append(contentsOf: $0) } }
        }
        try c.encode(faceData, forKey: .packedFaces)
        var colorData = Data(capacity: colors.count * 4)
        for col in colors {
            colorData.append(contentsOf: [col.x, col.y, col.z, col.w].map { UInt8(max(0, min(255, ($0 * 255).rounded()))) })
        }
        try c.encode(colorData, forKey: .packedColors)
        try c.encode([boundingBoxMin.x, boundingBoxMin.y, boundingBoxMin.z], forKey: .boundsMin)
        try c.encode([boundingBoxMax.x, boundingBoxMax.y, boundingBoxMax.z], forKey: .boundsMax)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.packedVertices) {
            vertices = try MeshData.unpack(c.decode(Data.self, forKey: .packedVertices))
            normals = try MeshData.unpack(c.decode(Data.self, forKey: .packedNormals))
            let faceData = try c.decode(Data.self, forKey: .packedFaces)
            guard faceData.count % 12 == 0, faceData.count / 12 <= 16_000_000 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let indexCount = faceData.count / 4
            var decodedFaces: [[UInt32]] = []
            decodedFaces.reserveCapacity(indexCount / 3)
            faceData.withUnsafeBytes { raw in
                var i = 0
                while i + 2 < indexCount {
                    decodedFaces.append([
                        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)),
                        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: (i + 1) * 4, as: UInt32.self)),
                        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: (i + 2) * 4, as: UInt32.self))
                    ])
                    i += 3
                }
            }
            faces = decodedFaces
            let colorData = try c.decode(Data.self, forKey: .packedColors)
            guard colorData.count % 4 == 0, colorData.isEmpty || colorData.count / 4 == vertices.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var decodedColors: [SIMD4<Float>] = []
            decodedColors.reserveCapacity(colorData.count / 4)
            var j = colorData.startIndex
            while j + 3 < colorData.endIndex {
                decodedColors.append(SIMD4<Float>(Float(colorData[j]), Float(colorData[j + 1]),
                                                  Float(colorData[j + 2]), Float(colorData[j + 3])) / 255)
                j += 4
            }
            colors = decodedColors
            let lo = try c.decode([Float].self, forKey: .boundsMin)
            let hi = try c.decode([Float].self, forKey: .boundsMax)
            guard lo.count == 3, hi.count == 3 else { throw CocoaError(.fileReadCorruptFile) }
            boundingBoxMin = SIMD3<Float>(lo[0], lo[1], lo[2])
            boundingBoxMax = SIMD3<Float>(hi[0], hi[1], hi[2])
        } else {
            vertices = try c.decode([SIMD3<Float>].self, forKey: .vertices)
            normals = try c.decode([SIMD3<Float>].self, forKey: .normals)
            faces = try c.decode([[UInt32]].self, forKey: .faces)
            colors = try c.decode([SIMD4<Float>].self, forKey: .colors)
            boundingBoxMin = try c.decode(SIMD3<Float>.self, forKey: .boundingBoxMin)
            boundingBoxMax = try c.decode(SIMD3<Float>.self, forKey: .boundingBoxMax)
        }
        try validateCheckpoint()
    }

    /// Never silently truncate a checkpoint or restore partially corrupt geometry.
    /// Older uncompressed checkpoints pass the same structural checks.
    private func validateCheckpoint() throws {
        func finite(_ p: SIMD3<Float>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite }
        guard vertices.count <= 8_000_000, faces.count <= 16_000_000,
              (normals.isEmpty || normals.count == vertices.count),
              (colors.isEmpty || colors.count == vertices.count),
              vertices.allSatisfy(finite), normals.allSatisfy(finite),
              colors.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }),
              finite(boundingBoxMin), finite(boundingBoxMax),
              boundingBoxMin.x <= boundingBoxMax.x, boundingBoxMin.y <= boundingBoxMax.y,
              boundingBoxMin.z <= boundingBoxMax.z,
              faces.allSatisfy({ $0.count == 3 && $0.allSatisfy { Int($0) < vertices.count } }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private static func pack(_ values: [SIMD3<Float>]) -> Data {
        var data = Data(capacity: values.count * 12)
        for v in values {
            for f in [v.x, v.y, v.z] { withUnsafeBytes(of: f.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        }
        return data
    }

    private static func unpack(_ data: Data) throws -> [SIMD3<Float>] {
        guard data.count % 12 == 0, data.count / 12 <= 8_000_000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let count = data.count / 12
        var result = [SIMD3<Float>](repeating: .zero, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                func f(_ k: Int) -> Float {
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 12 + k * 4, as: UInt32.self)))
                }
                result[i] = SIMD3<Float>(f(0), f(1), f(2))
            }
        }
        return result
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
