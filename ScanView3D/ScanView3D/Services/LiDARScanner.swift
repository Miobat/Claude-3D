#if !targetEnvironment(simulator)
import ARKit
import RealityKit
import Combine

/// Manages LiDAR scanning sessions using ARKit
class LiDARScanner: NSObject, ObservableObject {
    // MARK: - Published State

    @Published var isScanning = false
    @Published var isPaused = false
    @Published var meshAnchors: [ARMeshAnchor] = []
    @Published var scanProgress: String = "Ready to scan"
    @Published var vertexCount: Int = 0
    @Published var faceCount: Int = 0
    @Published var confidenceThreshold: Float = 0.5
    @Published var scanError: String?
    @Published var capturedFrameCount: Int = 0
    @Published var isPreviewing = false
    @Published var memoryUsageMB: Double = 0
    @Published var estimatedFileSizeMB: Double = 0
    @Published var scanCapacityPercent: Double = 0

    // MARK: - Properties

    private(set) var arSession: ARSession
    private var meshDetail: ScanSettings.MeshDetail = .medium
    private var captureTexture: Bool = true
    private var scanRange: ScanSettings.ScanRange = .room
    private var scanQuality: ScanSettings.ScanQuality = .standard
    let textureMapper = TextureMapper()
    private var frameCaptureTimer: Timer?
    private var memoryMonitorTimer: Timer?
    private var scanOrigin: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    private var textureCapturePaused = false

    // Memory limits
    private let maxMemoryUsageMB: Double = 400
    private let criticalMemoryMB: Double = 150 // available memory threshold

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
        // No mesh reconstruction in preview - just camera feed
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
        detail: ScanSettings.MeshDetail = .medium,
        captureTexture: Bool = true,
        range: ScanSettings.ScanRange = .room,
        quality: ScanSettings.ScanQuality = .standard
    ) {
        guard LiDARScanner.isLiDARAvailable else {
            scanError = "LiDAR is not available on this device"
            return
        }

        self.meshDetail = detail
        self.captureTexture = captureTexture
        self.scanRange = range
        self.scanQuality = quality
        self.confidenceThreshold = quality.confidenceThreshold
        self.textureCapturePaused = false

        // Configure texture mapper
        textureMapper.configure(quality: quality)
        textureMapper.reset()
        capturedFrameCount = 0
        memoryUsageMB = 0
        estimatedFileSizeMB = 0
        scanCapacityPercent = 0

        // Record scan origin from current camera position
        if let frame = arSession.currentFrame {
            let t = frame.camera.transform
            scanOrigin = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        } else {
            scanOrigin = SIMD3<Float>(0, 0, 0)
        }

        let configuration = ARWorldTrackingConfiguration()

        // Enable mesh reconstruction
        if LiDARScanner.isLiDARWithClassificationAvailable {
            configuration.sceneReconstruction = .meshWithClassification
        } else {
            configuration.sceneReconstruction = .mesh
        }

        // Always enable environment texturing for camera capture
        configuration.environmentTexturing = .automatic

        // Enable plane detection for better mesh alignment
        configuration.planeDetection = [.horizontal, .vertical]

        // Set frame semantics for depth
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }

        arSession.run(configuration, options: [.removeExistingAnchors, .resetTracking])

        isPreviewing = false
        isScanning = true
        isPaused = false
        scanProgress = "Scanning... Move slowly around the area"
        scanError = nil

        // Start periodic frame capture for texture mapping
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

    func resetScanning() {
        stopScanning()
        meshAnchors.removeAll()
        vertexCount = 0
        faceCount = 0
        capturedFrameCount = 0
        memoryUsageMB = 0
        estimatedFileSizeMB = 0
        scanCapacityPercent = 0
        textureMapper.reset()
        scanProgress = "Ready to scan"
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
        guard isScanning && !isPaused && !textureCapturePaused,
              captureTexture,
              let frame = arSession.currentFrame else { return }
        textureMapper.captureFrame(from: frame)
        DispatchQueue.main.async {
            self.capturedFrameCount = self.textureMapper.frameCount
        }
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
        let meshMemoryMB = Double(vertexCount * 48 + faceCount * 12) / (1024.0 * 1024.0) // rough estimate
        let totalMB = textureMemoryMB + meshMemoryMB

        // Estimate file size: vertices * ~80 bytes (pos + normal + color + uv) + faces * ~30 bytes
        let estFileMB = Double(vertexCount * 80 + faceCount * 30) / (1024.0 * 1024.0)
        // Add texture atlas size estimate
        let textureSizeMB = textureMapper.estimatedAtlasSizeMB

        // Available memory check
        let availableMemory = Self.availableMemoryMB()

        DispatchQueue.main.async {
            self.memoryUsageMB = totalMB
            self.estimatedFileSizeMB = estFileMB + textureSizeMB

            // Capacity is based on memory pressure
            let memoryPressure = totalMB / self.maxMemoryUsageMB
            self.scanCapacityPercent = min(memoryPressure * 100, 100)

            // Auto-pause texture capture if memory is getting tight
            if availableMemory < self.criticalMemoryMB || totalMB > self.maxMemoryUsageMB {
                if !self.textureCapturePaused {
                    self.textureCapturePaused = true
                    self.scanProgress = "Memory limit - texture capture paused"
                    DebugLogger.shared.warn("Texture capture paused: available=\(Int(availableMemory))MB, used=\(Int(totalMB))MB", category: "Scanner")
                }
            }

            // Critical: auto-stop if about to crash
            if availableMemory < 80 {
                self.scanProgress = "Low memory - stopping scan"
                DebugLogger.shared.error("Critical memory: \(Int(availableMemory))MB available, force stopping", category: "Scanner")
                self.stopScanning()
            }
        }
    }

    static func availableMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let usedMB = Double(info.resident_size) / (1024.0 * 1024.0)
            let totalMB = Double(ProcessInfo.processInfo.physicalMemory) / (1024.0 * 1024.0)
            return totalMB - usedMB
        }
        return 500 // fallback assumption
    }

    // MARK: - Mesh Data Access

    /// Returns all mesh data combined from all anchors, filtered by scan range
    func getCombinedMeshData() -> MeshData? {
        guard !meshAnchors.isEmpty else { return nil }

        let maxDist = scanRange.maxDistance

        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allFaces: [[UInt32]] = []
        var allColors: [SIMD4<Float>] = []
        var vertexOffset: UInt32 = 0

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let transform = anchor.transform

            // Check if anchor center is within range from scan origin
            let anchorPos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let anchorDist = length(anchorPos - scanOrigin)
            if anchorDist > maxDist + 2.0 { continue }

            var localVertices: [SIMD3<Float>] = []
            var localNormals: [SIMD3<Float>] = []
            var localColors: [SIMD4<Float>] = []
            var vertexInRange = [Bool]()
            var localIndexMap = [UInt32](repeating: 0, count: geometry.vertices.count)

            for i in 0..<geometry.vertices.count {
                let localVertex = geometry.vertex(at: UInt32(i))
                let worldVertex4 = transform * SIMD4<Float>(localVertex.x, localVertex.y, localVertex.z, 1.0)
                let worldVertex = SIMD3<Float>(worldVertex4.x, worldVertex4.y, worldVertex4.z)

                let dist = length(worldVertex - scanOrigin)
                if dist <= maxDist {
                    localIndexMap[i] = UInt32(localVertices.count)
                    localVertices.append(worldVertex)
                    vertexInRange.append(true)

                    let localNormal = geometry.normal(at: UInt32(i))
                    let rotationMatrix = simd_float3x3(
                        SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                        SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                        SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
                    )
                    let worldNormal = rotationMatrix * localNormal
                    localNormals.append(worldNormal)

                    if let classification = anchor.geometry.classification {
                        let classIndex = classification.buffer.contents()
                            .advanced(by: classification.offset + classification.stride * Int(i))
                            .assumingMemoryBound(to: UInt8.self).pointee
                        localColors.append(colorForClassification(classIndex))
                    } else {
                        localColors.append(SIMD4<Float>(0.7, 0.7, 0.7, 1.0))
                    }
                } else {
                    vertexInRange.append(false)
                }
            }

            for f in 0..<geometry.faces.count {
                let indices = geometry.vertexIndicesOf(face: f)
                let allInRange = indices.allSatisfy { idx in
                    Int(idx) < vertexInRange.count && vertexInRange[Int(idx)]
                }
                guard allInRange else { continue }
                let mappedIndices = indices.map { localIndexMap[Int($0)] + vertexOffset }
                allFaces.append(mappedIndices)
            }

            allVertices.append(contentsOf: localVertices)
            allNormals.append(contentsOf: localNormals)
            allColors.append(contentsOf: localColors)
            vertexOffset += UInt32(localVertices.count)
        }

        guard !allVertices.isEmpty else { return nil }

        // Replace classification colors with camera colors if available
        if captureTexture && textureMapper.frameCount > 0 {
            let cameraColors = textureMapper.sampleVertexColors(vertices: allVertices, normals: allNormals)
            allColors = cameraColors
        }

        var minBound = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxBound = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        for vertex in allVertices {
            minBound = min(minBound, vertex)
            maxBound = max(maxBound, vertex)
        }

        return MeshData(
            vertices: allVertices,
            normals: allNormals,
            faces: allFaces,
            colors: allColors,
            boundingBoxMin: minBound,
            boundingBoxMax: maxBound
        )
    }

    /// Build texture atlas for current mesh data
    func buildTextureAtlas(meshData: MeshData) -> TextureAtlasResult? {
        return textureMapper.buildTextureAtlas(
            meshData: meshData,
            tileSize: scanQuality.textureAtlasTileSize
        )
    }

    /// Returns the current camera frame for texture capture
    func getCurrentFrame() -> ARFrame? {
        return arSession.currentFrame
    }

    // MARK: - Filtered counts for display

    /// Get vertex/face counts respecting the range filter
    func getFilteredCounts() -> (vertices: Int, faces: Int) {
        var totalVertices = 0
        var totalFaces = 0
        let maxDist = scanRange.maxDistance

        for anchor in meshAnchors {
            let transform = anchor.transform
            let anchorPos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let anchorDist = length(anchorPos - scanOrigin)
            if anchorDist <= maxDist + 2.0 {
                totalVertices += anchor.geometry.vertices.count
                totalFaces += anchor.geometry.faces.count
            }
        }

        return (totalVertices, totalFaces)
    }

    // MARK: - Helpers

    private func colorForClassification(_ classIndex: UInt8) -> SIMD4<Float> {
        switch ARMeshClassification(rawValue: Int(classIndex)) {
        case .ceiling:
            return SIMD4<Float>(0.8, 0.8, 0.9, 1.0)
        case .door:
            return SIMD4<Float>(0.6, 0.4, 0.2, 1.0)
        case .floor:
            return SIMD4<Float>(0.5, 0.5, 0.5, 1.0)
        case .seat:
            return SIMD4<Float>(0.3, 0.6, 0.3, 1.0)
        case .table:
            return SIMD4<Float>(0.6, 0.4, 0.1, 1.0)
        case .wall:
            return SIMD4<Float>(0.9, 0.9, 0.85, 1.0)
        case .window:
            return SIMD4<Float>(0.5, 0.7, 0.9, 1.0)
        default:
            return SIMD4<Float>(0.7, 0.7, 0.7, 1.0)
        }
    }

    private func updateMeshCounts() {
        let filtered = getFilteredCounts()
        self.vertexCount = filtered.vertices
        self.faceCount = filtered.faces
    }
}

// MARK: - ARSessionDelegate

extension LiDARScanner: ARSessionDelegate {
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let newMeshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        if !newMeshAnchors.isEmpty {
            DispatchQueue.main.async {
                self.meshAnchors.append(contentsOf: newMeshAnchors)
                self.updateMeshCounts()
            }
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let updatedMeshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        if !updatedMeshAnchors.isEmpty {
            DispatchQueue.main.async {
                for updated in updatedMeshAnchors {
                    if let index = self.meshAnchors.firstIndex(where: { $0.identifier == updated.identifier }) {
                        self.meshAnchors[index] = updated
                    }
                }
                self.updateMeshCounts()
            }
        }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let removedMeshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        if !removedMeshAnchors.isEmpty {
            DispatchQueue.main.async {
                self.meshAnchors.removeAll { anchor in
                    removedMeshAnchors.contains { $0.identifier == anchor.identifier }
                }
                self.updateMeshCounts()
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.scanError = "AR Session Error: \(error.localizedDescription)"
            self.isScanning = false
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async {
            self.scanProgress = "Session interrupted"
            self.isPaused = true
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async {
            self.scanProgress = "Resuming scan..."
            self.isPaused = false
        }
    }
}
#endif

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
}
