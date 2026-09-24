#if !targetEnvironment(simulator)
import ARKit
import RealityKit
import Combine
import CoreImage
import os

/// Manages LiDAR scanning sessions using ARKit
class LiDARScanner: NSObject, ObservableObject {
    // MARK: - Published State

    @Published var isScanning = false
    @Published var isPaused = false
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

    // MARK: - Properties

    private(set) var arSession: ARSession
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
    private let highResInterval: TimeInterval = 0.25
    private let maxHighResFrames: Int = 250
    private var pendingHighResSaves = 0
    private let ciContext = CIContext()
    private let hqSaveQueue = DispatchQueue(label: "scanview.hq.save", qos: .utility)
    private(set) var capturedPoses: [CapturedPose] = []

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
        guard !isPreviewing && !isScanning else { return }
        guard LiDARScanner.isLiDARAvailable else { return }

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
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
        captureMode: ScanSettings.CaptureMode = .fast
    ) {
        guard LiDARScanner.isLiDARAvailable else {
            scanError = "LiDAR is not available on this device"
            return
        }

        clearScanData()

        self.captureTexture = captureTexture
        self.rangeMeters = rangeMeters
        self.meshMode = meshMode
        self.captureMode = captureMode
        anchorPathIndex = PathRangeIndex(points: [], radius: rangeMeters + 4)

        if captureMode == .highQuality || captureMode == .splatExport {
            captureFolderURL = makeCaptureFolder()
        }

        textureMapper.configure(quality: scanQuality)

        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = LiDARScanner.isLiDARWithClassificationAvailable
            ? .meshWithClassification : .mesh
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

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
        guard let config = arSession.configuration else { return }
        arSession.run(config)
        isPaused = false
        scanProgress = "Scanning resumed..."
        startFrameCapture()
    }

    func stopScanning() {
        arSession.pause()
        isScanning = false
        isPaused = false
        scanProgress = "Scan complete"
        stopFrameCapture()
        stopMemoryMonitor()
    }

    /// Continue a stopped (not reset) scan, keeping everything captured so far.
    func continueScanning() {
        guard let config = arSession.configuration, !isScanning else { return }
        arSession.run(config)
        isScanning = true
        isPaused = false
        scanProgress = "Scanning... Move slowly around the area"
        startFrameCapture()
        startMemoryMonitor()
    }

    func resetScanning() {
        stopScanning()
        clearScanData()
        scanProgress = "Ready to scan"
    }

    /// Drop everything from the previous scan, including its temporary photo folder.
    private func clearScanData() {
        meshAnchorsByID.removeAll()
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
        }
        captureFolderURL = nil
        highResFrameCount = 0
        lastHighResSaveTime = 0
        capturedPoses = []
        photoLimitReached = false
        captureMode = .fast
        cameraPath = []
        needsOrigin = true
        scanOrigin = SIMD3<Float>(0, 0, 0)
        trackingWarning = nil
    }

    // MARK: - Frame Capture

    private func startFrameCapture() {
        stopFrameCapture()
        frameCaptureTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
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

        // Downscaled frames for colour (all modes except High-Quality photogrammetry)
        if captureMode != .highQuality && captureTexture && !textureCapturePaused {
            textureMapper.captureFrame(from: frame) { [weak self] count in
                self?.capturedFrameCount = count
            }
        }

        // Full-resolution posed photos (High-Quality and Splat)
        if captureMode == .highQuality || captureMode == .splatExport {
            saveHighResFrame(frame)
        }
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

    private func saveHighResFrame(_ frame: ARFrame) {
        guard let folder = captureFolderURL else { return }

        if highResFrameCount >= maxHighResFrames {
            if !photoLimitReached {
                photoLimitReached = true
                scanProgress = "Photo limit reached (\(maxHighResFrames)) — tap Stop to save"
            }
            return
        }

        let now = frame.timestamp
        guard now - lastHighResSaveTime >= highResInterval else { return }
        // Don't queue up camera buffers if encoding falls behind: holding ARFrame
        // buffers starves ARKit and makes the camera feed stutter.
        guard pendingHighResSaves < 2 else { return }
        lastHighResSaveTime = now

        let index = highResFrameCount
        highResFrameCount = index + 1

        let pixelBuffer = frame.capturedImage
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        capturedPoses.append(CapturedPose(
            index: index,
            transform: frame.camera.transform,
            intrinsics: frame.camera.intrinsics,
            width: w,
            height: h
        ))

        // JPEG with EXIF focal length — PhotogrammetrySession needs it.
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let url = folder.appendingPathComponent(String(format: "frame_%04d.jpg", index))
        let focalLengthPx = Double(frame.camera.intrinsics[0][0])
        let sensorWidthMM = 6.17   // approximate iPhone wide-camera sensor width
        let physicalFocalMM = focalLengthPx * sensorWidthMM / Double(w)
        let focalLength35mm = physicalFocalMM * 36.0 / sensorWidthMM

        pendingHighResSaves += 1
        hqSaveQueue.async { [ciContext] in
            defer { DispatchQueue.main.async { self.pendingHighResSaves -= 1 } }
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }

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
            CGImageDestinationFinalize(dest)
        }
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
        let totalMB = textureMemoryMB + meshMemoryMB
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
    /// Anchor data is snapshotted on the main thread first, so it is safe to call
    /// while ARKit is still delivering updates.
    func buildCombinedMesh(completion: @escaping (MeshData?) -> Void) {
        let anchors = meshAnchors
        let path = cameraPath.isEmpty ? [scanOrigin] : cameraPath
        let range = rangeMeters
        let mode = meshMode
        let wantCameraColors = captureTexture
        let mapper = textureMapper

        DispatchQueue.global(qos: .userInitiated).async {
            var mesh = LiDARScanner.combine(anchors: anchors, path: path, range: range, meshMode: mode)
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
    private static func combine(anchors: [ARMeshAnchor], path: [SIMD3<Float>], range: Float,
                                meshMode: ScanSettings.MeshMode) -> MeshData? {
        guard !anchors.isEmpty else { return nil }
        let vertexIndex = PathRangeIndex(points: path, radius: range)
        let anchorIndex = PathRangeIndex(points: path, radius: range + 4)

        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allFaces: [[UInt32]] = []
        var allColors: [SIMD4<Float>] = []

        for anchor in anchors {
            let transform = anchor.transform
            // Anchor blocks span a few metres; skip ones the camera never came near.
            guard anchorIndex.contains(transform.position) else { continue }

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
                inRange[i] = vertexIndex.contains(world[i])
            }

            // ARKit classifies FACES (one UInt8 per triangle), not vertices.
            let classification = geometry.classification
            var localIndex = [Int32](repeating: -1, count: vertexCount)

            for f in 0..<geometry.faces.count {
                let indices = geometry.vertexIndicesOf(face: f)
                guard indices.count == 3,
                      indices.allSatisfy({ Int($0) < vertexCount && inRange[Int($0)] }) else { continue }

                var faceClass: UInt8 = 0
                if let c = classification {
                    faceClass = c.buffer.contents()
                        .advanced(by: c.offset + c.stride * f)
                        .assumingMemoryBound(to: UInt8.self).pointee
                }
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
        handle(anchors: anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        handle(anchors: anchors)
    }

    private func handle(anchors: [ARAnchor]) {
        guard isScanning else { return }
        var meshChanged = false
        var planesChanged = false
        for anchor in anchors {
            if let mesh = anchor as? ARMeshAnchor {
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
        var meshChanged = false
        for anchor in anchors {
            if meshAnchorsByID.removeValue(forKey: anchor.identifier) != nil { meshChanged = true }
            planeAnchorsByID.removeValue(forKey: anchor.identifier)
        }
        if meshChanged { updateMeshCounts() }
        detectedPlaneCount = planeAnchorsByID.count
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let message = LiDARScanner.trackingMessage(for: camera.trackingState)
        if message != trackingWarning { trackingWarning = message }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        scanError = "AR Session Error: \(error.localizedDescription)"
        if isScanning { pauseScanning() }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        scanProgress = "Session interrupted"
        isPaused = true
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        scanProgress = "Resuming scan..."
        isPaused = false
    }
}
#endif

// MARK: - Shared types (device + simulator)

/// Combined mesh data from all scan anchors
struct MeshData {
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
