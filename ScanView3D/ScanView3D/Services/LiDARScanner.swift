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
    @Published var planeAnchors: [ARPlaneAnchor] = []
    @Published var scanProgress: String = "Ready to scan"
    @Published var vertexCount: Int = 0
    @Published var faceCount: Int = 0
    @Published var confidenceThreshold: Float = 0.5
    @Published var scanError: String?
    @Published var capturedFrameCount: Int = 0
    @Published var detectedPlaneCount: Int = 0
    @Published var isPreviewing = false
    @Published var memoryUsageMB: Double = 0
    @Published var estimatedFileSizeMB: Double = 0
    @Published var scanCapacityPercent: Double = 0

    // MARK: - Properties

    private(set) var arSession: ARSession
    private var meshDetail: ScanSettings.MeshDetail = .medium
    private var captureTexture: Bool = true
    private(set) var currentRange: ScanSettings.ScanRange = .room
    private var scanQuality: ScanSettings.ScanQuality = .standard
    private(set) var meshMode: ScanSettings.MeshMode = .free
    let textureMapper = TextureMapper()
    private var frameCaptureTimer: Timer?
    private var memoryMonitorTimer: Timer?
    private(set) var scanOrigin: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
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
        quality: ScanSettings.ScanQuality = .standard,
        meshMode: ScanSettings.MeshMode = .free
    ) {
        guard LiDARScanner.isLiDARAvailable else {
            scanError = "LiDAR is not available on this device"
            return
        }

        self.meshDetail = detail
        self.captureTexture = captureTexture
        self.currentRange = range
        self.scanQuality = quality
        self.meshMode = meshMode
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
        planeAnchors.removeAll()
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

        let maxDist = currentRange.maxDistance

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

                    // Get classification for mesh mode filtering
                    var classIndex: UInt8 = 0
                    if let classification = anchor.geometry.classification {
                        classIndex = classification.buffer.contents()
                            .advanced(by: classification.offset + classification.stride * Int(i))
                            .assumingMemoryBound(to: UInt8.self).pointee
                    }

                    // Apply mesh mode filter
                    if !meshMode.shouldIncludeVertex(classification: classIndex) {
                        vertexInRange.append(false)
                        continue
                    }

                    localColors.append(colorForClassification(classIndex))
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

    /// Build clean room geometry from detected planes (for Area mode)
    func getPlaneBasedMeshData() -> MeshData? {
        guard !planeAnchors.isEmpty else { return nil }

        let maxDist = currentRange.maxDistance
        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allFaces: [[UInt32]] = []
        var allColors: [SIMD4<Float>] = []

        for plane in planeAnchors {
            let transform = plane.transform
            let planeCenter = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)

            // Range check
            let dist = length(planeCenter - scanOrigin)
            if dist > maxDist { continue }

            // Get plane extent
            let extent = plane.extent
            let hw = extent.x / 2.0
            let hz = extent.z / 2.0

            // Color based on plane classification
            let color: SIMD4<Float>
            switch plane.classification {
            case .floor:
                color = SIMD4<Float>(0.6, 0.6, 0.65, 1.0)
            case .ceiling:
                color = SIMD4<Float>(0.85, 0.85, 0.9, 1.0)
            case .wall:
                color = SIMD4<Float>(0.9, 0.9, 0.85, 1.0)
            case .door:
                color = SIMD4<Float>(0.55, 0.35, 0.15, 1.0)
            case .window:
                color = SIMD4<Float>(0.5, 0.7, 0.9, 1.0)
            default:
                // Skip non-structural planes
                continue
            }

            // Build a subdivided quad for the plane (subdivisions help with lighting)
            let subdivisions = 4
            let baseIndex = UInt32(allVertices.count)

            // Get plane normal in world space
            let localNormal = SIMD3<Float>(0, 1, 0) // ARKit planes face up in local space
            let rotationMatrix = simd_float3x3(
                SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            )
            let worldNormal = normalize(rotationMatrix * localNormal)

            // Generate vertices in a grid
            for row in 0...subdivisions {
                for col in 0...subdivisions {
                    let lx = -hw + (2.0 * hw) * Float(col) / Float(subdivisions)
                    let lz = -hz + (2.0 * hz) * Float(row) / Float(subdivisions)
                    let localPos = SIMD4<Float>(plane.center.x + lx, plane.center.y, plane.center.z + lz, 1.0)
                    let worldPos = transform * localPos

                    allVertices.append(SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z))
                    allNormals.append(worldNormal)
                    allColors.append(color)
                }
            }

            // Generate faces
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

        var minB = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxB = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        for v in allVertices {
            minB = min(minB, v)
            maxB = max(maxB, v)
        }

        return MeshData(
            vertices: allVertices,
            normals: allNormals,
            faces: allFaces,
            colors: allColors,
            boundingBoxMin: minB,
            boundingBoxMax: maxB
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
        let maxDist = currentRange.maxDistance

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
        let newPlaneAnchors = anchors.compactMap { $0 as? ARPlaneAnchor }
        DispatchQueue.main.async {
            if !newMeshAnchors.isEmpty {
                self.meshAnchors.append(contentsOf: newMeshAnchors)
                self.updateMeshCounts()
            }
            if !newPlaneAnchors.isEmpty {
                self.planeAnchors.append(contentsOf: newPlaneAnchors)
                self.detectedPlaneCount = self.planeAnchors.count
            }
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let updatedMeshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        let updatedPlaneAnchors = anchors.compactMap { $0 as? ARPlaneAnchor }
        DispatchQueue.main.async {
            for updated in updatedMeshAnchors {
                if let index = self.meshAnchors.firstIndex(where: { $0.identifier == updated.identifier }) {
                    self.meshAnchors[index] = updated
                }
            }
            for updated in updatedPlaneAnchors {
                if let index = self.planeAnchors.firstIndex(where: { $0.identifier == updated.identifier }) {
                    self.planeAnchors[index] = updated
                } else {
                    self.planeAnchors.append(updated)
                }
            }
            if !updatedMeshAnchors.isEmpty { self.updateMeshCounts() }
            if !updatedPlaneAnchors.isEmpty { self.detectedPlaneCount = self.planeAnchors.count }
        }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let removedMeshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        let removedPlaneAnchors = anchors.compactMap { $0 as? ARPlaneAnchor }
        DispatchQueue.main.async {
            if !removedMeshAnchors.isEmpty {
                self.meshAnchors.removeAll { anchor in
                    removedMeshAnchors.contains { $0.identifier == anchor.identifier }
                }
                self.updateMeshCounts()
            }
            if !removedPlaneAnchors.isEmpty {
                self.planeAnchors.removeAll { anchor in
                    removedPlaneAnchors.contains { $0.identifier == anchor.identifier }
                }
                self.detectedPlaneCount = self.planeAnchors.count
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
