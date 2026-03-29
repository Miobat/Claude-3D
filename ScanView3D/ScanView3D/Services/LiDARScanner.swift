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

    // MARK: - Properties

    private(set) var arSession: ARSession
    private var meshDetail: ScanSettings.MeshDetail = .medium
    private var captureTexture: Bool = true
    private var scanRange: ScanSettings.ScanRange = .room
    private var scanQuality: ScanSettings.ScanQuality = .standard
    let textureMapper = TextureMapper()
    private var frameCaptureTimer: Timer?

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

        // Configure texture mapper
        textureMapper.configure(quality: quality)
        textureMapper.reset()
        capturedFrameCount = 0

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

        isScanning = true
        isPaused = false
        scanProgress = "Scanning... Move slowly around the area"
        scanError = nil

        // Start periodic frame capture for texture mapping
        startFrameCapture()
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
    }

    func resetScanning() {
        stopScanning()
        meshAnchors.removeAll()
        vertexCount = 0
        faceCount = 0
        capturedFrameCount = 0
        textureMapper.reset()
        scanProgress = "Ready to scan"
    }

    // MARK: - Frame Capture

    private func startFrameCapture() {
        stopFrameCapture()
        // Use a timer to periodically check for new frames
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
              captureTexture,
              let frame = arSession.currentFrame else { return }
        textureMapper.captureFrame(from: frame)
        DispatchQueue.main.async {
            self.capturedFrameCount = self.textureMapper.frameCount
        }
    }

    // MARK: - Mesh Data Access

    /// Returns all mesh data combined from all anchors, filtered by scan range
    func getCombinedMeshData() -> MeshData? {
        guard !meshAnchors.isEmpty else { return nil }

        // Get camera position for range filtering
        let cameraPosition: SIMD3<Float>
        if let frame = arSession.currentFrame {
            let t = frame.camera.transform
            cameraPosition = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        } else {
            cameraPosition = SIMD3<Float>(0, 0, 0)
        }

        let maxDist = scanRange.maxDistance

        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allFaces: [[UInt32]] = []
        var allColors: [SIMD4<Float>] = []
        var vertexOffset: UInt32 = 0

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let transform = anchor.transform

            // Check if anchor center is within range
            let anchorPos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let anchorDist = length(anchorPos - cameraPosition)
            if anchorDist > maxDist + 2.0 { continue } // Skip anchors clearly out of range

            var localVertices: [SIMD3<Float>] = []
            var localNormals: [SIMD3<Float>] = []
            var localColors: [SIMD4<Float>] = []
            var vertexInRange = [Bool]()
            var localIndexMap = [UInt32](repeating: 0, count: geometry.vertices.count)

            for i in 0..<geometry.vertices.count {
                let localVertex = geometry.vertex(at: UInt32(i))
                let worldVertex4 = transform * SIMD4<Float>(localVertex.x, localVertex.y, localVertex.z, 1.0)
                let worldVertex = SIMD3<Float>(worldVertex4.x, worldVertex4.y, worldVertex4.z)

                let dist = length(worldVertex - cameraPosition)
                if dist <= maxDist {
                    localIndexMap[i] = UInt32(localVertices.count)
                    localVertices.append(worldVertex)
                    vertexInRange.append(true)

                    // Transform normals
                    let localNormal = geometry.normal(at: UInt32(i))
                    let rotationMatrix = simd_float3x3(
                        SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                        SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                        SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
                    )
                    let worldNormal = rotationMatrix * localNormal
                    localNormals.append(worldNormal)

                    // Get vertex color from classification if available
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

            // Process faces - only include faces where all vertices are in range
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

        // If we have camera texture data, replace classification colors with camera colors
        if captureTexture && textureMapper.frameCount > 0 {
            let cameraColors = textureMapper.sampleVertexColors(vertices: allVertices, normals: allNormals)
            allColors = cameraColors
        }

        // Calculate bounding box
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
        var totalVertices = 0
        var totalFaces = 0
        for anchor in meshAnchors {
            totalVertices += anchor.geometry.vertices.count
            totalFaces += anchor.geometry.faces.count
        }
        self.vertexCount = totalVertices
        self.faceCount = totalFaces
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
