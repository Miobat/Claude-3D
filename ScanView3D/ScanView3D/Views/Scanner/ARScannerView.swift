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

        // Disable default scene understanding debug vis - we'll draw our own range-limited mesh
        arView.debugOptions = []

        // Configure rendering
        arView.environment.sceneUnderstanding.options = [.occlusion, .receivesLighting]
        arView.renderOptions = [.disableMotionBlur]

        context.coordinator.arView = arView
        context.coordinator.scanner = scanner

        return arView
    }

    func updateUIView(_ arView: ARView, context: Context) {
        context.coordinator.showMeshOverlay = showMeshOverlay

        if showMeshOverlay && scanner.isScanning {
            // Update mesh visualization with range filtering
            context.coordinator.updateRangeFilteredMesh()
        } else if !showMeshOverlay {
            context.coordinator.clearMeshVisualization()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var arView: ARView?
        var scanner: LiDARScanner?
        var showMeshOverlay = true
        private var meshAnchors: [UUID: AnchorEntity] = [:]
        private var lastUpdateTime: TimeInterval = 0
        private let updateInterval: TimeInterval = 0.3

        func updateRangeFilteredMesh() {
            guard let arView = arView, let scanner = scanner else { return }

            let now = CACurrentMediaTime()
            guard now - lastUpdateTime >= updateInterval else { return }
            lastUpdateTime = now

            let scanOrigin = scanner.scanOrigin
            let maxDist = scanner.rangeMeters

            // Track which anchors are still valid
            var activeIDs = Set<UUID>()

            for anchor in scanner.meshAnchors {
                let anchorPos = SIMD3<Float>(
                    anchor.transform.columns.3.x,
                    anchor.transform.columns.3.y,
                    anchor.transform.columns.3.z
                )
                let dist = length(anchorPos - scanOrigin)

                if dist <= maxDist + 1.0 && showMeshOverlay {
                    activeIDs.insert(anchor.identifier)

                    if meshAnchors[anchor.identifier] == nil {
                        // Create new mesh entity for this anchor
                        if let entity = createMeshEntity(from: anchor, tint: UIColor.cyan.withAlphaComponent(0.15)) {
                            let anchorEntity = AnchorEntity(world: anchor.transform)
                            anchorEntity.addChild(entity)
                            arView.scene.addAnchor(anchorEntity)
                            meshAnchors[anchor.identifier] = anchorEntity
                        }
                    }
                }
            }

            // Remove anchors that are out of range
            let toRemove = meshAnchors.keys.filter { !activeIDs.contains($0) }
            for id in toRemove {
                meshAnchors[id]?.removeFromParent()
                meshAnchors.removeValue(forKey: id)
            }
        }

        func clearMeshVisualization() {
            for (_, entity) in meshAnchors {
                entity.removeFromParent()
            }
            meshAnchors.removeAll()
        }

        private func createMeshEntity(from anchor: ARMeshAnchor, tint: UIColor) -> ModelEntity? {
            let geometry = anchor.geometry
            var descriptor = MeshDescriptor(name: "mesh_\(anchor.identifier)")

            var positions: [SIMD3<Float>] = []
            for i in 0..<geometry.vertices.count {
                positions.append(geometry.vertex(at: UInt32(i)))
            }
            descriptor.positions = MeshBuffers.Positions(positions)

            var normals: [SIMD3<Float>] = []
            for i in 0..<geometry.normals.count {
                normals.append(geometry.normal(at: UInt32(i)))
            }
            descriptor.normals = MeshBuffers.Normals(normals)

            var indices: [UInt32] = []
            for f in 0..<geometry.faces.count {
                let faceIndices = geometry.vertexIndicesOf(face: f)
                indices.append(contentsOf: faceIndices)
            }
            descriptor.primitives = .triangles(indices)

            do {
                let meshResource = try MeshResource.generate(from: [descriptor])
                // Use brighter, more visible overlay so user can clearly see scanned area
                var material = SimpleMaterial()
                material.color = .init(tint: UIColor.cyan.withAlphaComponent(0.35))
                return ModelEntity(mesh: meshResource, materials: [material])
            } catch {
                return nil
            }
        }
    }
}
#endif
