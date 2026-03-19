#if !targetEnvironment(simulator)
import SwiftUI
import ARKit
import RealityKit

/// UIViewRepresentable wrapper for ARView used in scanning
struct ARScannerViewRepresentable: UIViewRepresentable {
    @ObservedObject var scanner: LiDARScanner
    @Binding var showMeshOverlay: Bool

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.session = scanner.arSession
        arView.automaticallyConfigureSession = false

        // Enable debug options for mesh visualization
        if showMeshOverlay {
            arView.debugOptions.insert(.showSceneUnderstanding)
        }

        // Configure rendering
        arView.environment.sceneUnderstanding.options = [.occlusion, .receivesLighting]
        arView.renderOptions = [.disableMotionBlur]

        context.coordinator.arView = arView

        return arView
    }

    func updateUIView(_ arView: ARView, context: Context) {
        if showMeshOverlay {
            arView.debugOptions.insert(.showSceneUnderstanding)
        } else {
            arView.debugOptions.remove(.showSceneUnderstanding)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var arView: ARView?
    }
}

/// Standalone AR scanning view controller for more advanced control
class ARScannerViewController: UIViewController {
    var arView: ARView!
    var scanner: LiDARScanner?
    var meshVisualizationEnabled = true

    private var meshNodes: [UUID: ModelEntity] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()

        arView = ARView(frame: view.bounds)
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(arView)

        if let scanner = scanner {
            arView.session = scanner.arSession
            arView.automaticallyConfigureSession = false
        }

        // Add coaching overlay to guide user
        let coachingOverlay = ARCoachingOverlayView()
        coachingOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coachingOverlay.session = arView.session
        coachingOverlay.goal = .anyPlane
        arView.addSubview(coachingOverlay)
    }

    func updateMeshVisualization(anchors: [ARMeshAnchor]) {
        guard meshVisualizationEnabled else { return }

        for anchor in anchors {
            if let existingEntity = meshNodes[anchor.identifier] {
                // Update existing mesh entity
                updateMeshEntity(existingEntity, with: anchor)
            } else {
                // Create new mesh entity
                if let entity = createMeshEntity(from: anchor) {
                    meshNodes[anchor.identifier] = entity

                    let anchorEntity = AnchorEntity(world: anchor.transform)
                    anchorEntity.addChild(entity)
                    arView.scene.addAnchor(anchorEntity)
                }
            }
        }
    }

    func removeMeshVisualization(for anchorIDs: [UUID]) {
        for id in anchorIDs {
            if let entity = meshNodes[id] {
                entity.removeFromParent()
                meshNodes.removeValue(forKey: id)
            }
        }
    }

    private func createMeshEntity(from anchor: ARMeshAnchor) -> ModelEntity? {
        let geometry = anchor.geometry

        // Create mesh descriptor
        var descriptor = MeshDescriptor(name: "mesh_\(anchor.identifier)")

        // Vertices
        var positions: [SIMD3<Float>] = []
        for i in 0..<geometry.vertices.count {
            positions.append(geometry.vertex(at: UInt32(i)))
        }
        descriptor.positions = MeshBuffers.Positions(positions)

        // Normals
        var normals: [SIMD3<Float>] = []
        for i in 0..<geometry.normals.count {
            normals.append(geometry.normal(at: UInt32(i)))
        }
        descriptor.normals = MeshBuffers.Normals(normals)

        // Face indices
        var indices: [UInt32] = []
        for f in 0..<geometry.faces.count {
            let faceIndices = geometry.vertexIndicesOf(face: f)
            indices.append(contentsOf: faceIndices)
        }
        descriptor.primitives = .triangles(indices)

        do {
            let meshResource = try MeshResource.generate(from: [descriptor])

            // Semi-transparent material for mesh overlay
            var material = SimpleMaterial()
            material.color = .init(tint: UIColor(white: 0.8, alpha: 0.3))

            let entity = ModelEntity(mesh: meshResource, materials: [material])
            return entity
        } catch {
            print("Error creating mesh entity: \(error)")
            return nil
        }
    }

    private func updateMeshEntity(_ entity: ModelEntity, with anchor: ARMeshAnchor) {
        // For simplicity, recreate the mesh
        // In production, you'd want incremental updates
        if let newEntity = createMeshEntity(from: anchor) {
            entity.model = newEntity.model
        }
    }
}
#endif
