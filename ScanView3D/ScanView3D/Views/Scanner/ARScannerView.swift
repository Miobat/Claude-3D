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

        // Use ARKit's built-in mesh visualization - it's GPU-optimized,
        // always up-to-date, and shows exactly what's been scanned
        arView.debugOptions.insert(.showSceneUnderstanding)

        // Configure scene understanding for occlusion and lighting
        arView.environment.sceneUnderstanding.options = [.occlusion, .receivesLighting]
        arView.renderOptions = [.disableMotionBlur]

        return arView
    }

    func updateUIView(_ arView: ARView, context: Context) {
        // Toggle mesh overlay visibility
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
#endif
