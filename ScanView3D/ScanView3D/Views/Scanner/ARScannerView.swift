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

        // Don't use debugOptions - we render our own bright mesh overlay
        arView.debugOptions = []
        arView.environment.sceneUnderstanding.options = [.occlusion, .receivesLighting]
        arView.renderOptions = [.disableMotionBlur]

        context.coordinator.arView = arView
        context.coordinator.scanner = scanner
        context.coordinator.startUpdateLoop()

        return arView
    }

    func updateUIView(_ arView: ARView, context: Context) {
        context.coordinator.showMeshOverlay = showMeshOverlay
        if !showMeshOverlay {
            context.coordinator.clearAllMesh()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var arView: ARView?
        var scanner: LiDARScanner?
        var showMeshOverlay = true

        private var meshEntities: [UUID: (anchor: AnchorEntity, version: Int)] = [:]
        private var displayLink: CADisplayLink?
        private var frameCount = 0

        func startUpdateLoop() {
            displayLink?.invalidate()
            displayLink = CADisplayLink(target: self, selector: #selector(updateFrame))
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 5, maximum: 15, preferred: 10)
            displayLink?.add(to: .main, forMode: .common)
        }

        deinit {
            displayLink?.invalidate()
        }

        @objc private func updateFrame() {
            guard showMeshOverlay, let arView = arView, let scanner = scanner,
                  scanner.isScanning else { return }

            frameCount += 1
            // Update every ~3 frames at 10fps = ~3 updates/second
            guard frameCount % 3 == 0 else { return }

            let anchors = scanner.meshAnchors
            var activeIDs = Set<UUID>()

            for anchor in anchors {
                activeIDs.insert(anchor.identifier)

                if let existing = meshEntities[anchor.identifier] {
                    // Update position if anchor moved
                    existing.anchor.transform = Transform(matrix: anchor.transform)
                } else {
                    // Create new mesh entity
                    if let entity = buildMeshEntity(from: anchor) {
                        let anchorEntity = AnchorEntity(world: anchor.transform)
                        anchorEntity.addChild(entity)
                        arView.scene.addAnchor(anchorEntity)
                        meshEntities[anchor.identifier] = (anchorEntity, 0)
                    }
                }
            }

            // Remove anchors that no longer exist
            let stale = meshEntities.keys.filter { !activeIDs.contains($0) }
            for id in stale {
                meshEntities[id]?.anchor.removeFromParent()
                meshEntities.removeValue(forKey: id)
            }
        }

        func clearAllMesh() {
            for (_, entry) in meshEntities {
                entry.anchor.removeFromParent()
            }
            meshEntities.removeAll()
        }

        private func buildMeshEntity(from anchor: ARMeshAnchor) -> ModelEntity? {
            let geometry = anchor.geometry
            var descriptor = MeshDescriptor(name: "live_\(anchor.identifier.uuidString.prefix(8))")

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

                // Bright green semi-transparent material - very visible on camera
                var material = SimpleMaterial()
                material.color = .init(tint: UIColor(red: 0.1, green: 0.9, blue: 0.3, alpha: 0.4))
                material.metallic = .float(0.0)
                material.roughness = .float(0.9)

                return ModelEntity(mesh: meshResource, materials: [material])
            } catch {
                return nil
            }
        }
    }
}
#endif
