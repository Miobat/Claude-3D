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

    // MARK: - Properties

    private(set) var arSession: ARSession
    private var meshDetail: ScanSettings.MeshDetail = .medium
    private var captureTexture: Bool = true

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

    func startScanning(detail: ScanSettings.MeshDetail = .medium, captureTexture: Bool = true) {
        guard LiDARScanner.isLiDARAvailable else {
            scanError = "LiDAR is not available on this device"
            return
        }

        self.meshDetail = detail
        self.captureTexture = captureTexture

        let configuration = ARWorldTrackingConfiguration()

        // Enable mesh reconstruction
        if LiDARScanner.isLiDARWithClassificationAvailable {
            configuration.sceneReconstruction = .meshWithClassification
        } else {
            configuration.sceneReconstruction = .mesh
        }

        // Configure environment texturing for color capture
        if captureTexture {
            configuration.environmentTexturing = .automatic
        }

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
    }

    func pauseScanning() {
        arSession.pause()
        isPaused = true
        scanProgress = "Scanning paused"
    }

    func resumeScanning() {
        guard let config = arSession.configuration else { return }
        arSession.run(config)
        isPaused = false
        scanProgress = "Scanning resumed..."
    }

    func stopScanning() {
        arSession.pause()
        isScanning = false
        isPaused = false
        scanProgress = "Scan complete"
    }

    func resetScanning() {
        stopScanning()
        meshAnchors.removeAll()
        vertexCount = 0
        faceCount = 0
        scanProgress = "Ready to scan"
    }

    // MARK: - Mesh Data Access

    /// Returns all mesh data combined from all anchors
    func getCombinedMeshData() -> MeshData? {
        guard !meshAnchors.isEmpty else { return nil }

        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allFaces: [[UInt32]] = []
        var allColors: [SIMD4<Float>] = []
        var vertexOffset: UInt32 = 0

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let transform = anchor.transform

            // Transform vertices to world space
            for i in 0..<geometry.vertices.count {
                let localVertex = geometry.vertex(at: UInt32(i))
                let worldVertex = transform * SIMD4<Float>(localVertex.x, localVertex.y, localVertex.z, 1.0)
                allVertices.append(SIMD3<Float>(worldVertex.x, worldVertex.y, worldVertex.z))

                // Transform normals
                let localNormal = geometry.normal(at: UInt32(i))
                let rotationMatrix = simd_float3x3(
                    SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                    SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                    SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
                )
                let worldNormal = rotationMatrix * localNormal
                allNormals.append(worldNormal)

                // Get vertex color from classification if available
                if let classification = anchor.geometry.classification {
                    let classIndex = classification.buffer.contents()
                        .advanced(by: classification.offset + classification.stride * Int(i))
                        .assumingMemoryBound(to: UInt8.self).pointee
                    allColors.append(colorForClassification(classIndex))
                } else {
                    allColors.append(SIMD4<Float>(0.7, 0.7, 0.7, 1.0))
                }
            }

            // Process face indices with offset
            for f in 0..<geometry.faces.count {
                let indices = geometry.vertexIndicesOf(face: f)
                let offsetIndices = indices.map { $0 + vertexOffset }
                allFaces.append(offsetIndices)
            }

            vertexOffset += UInt32(geometry.vertices.count)
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
