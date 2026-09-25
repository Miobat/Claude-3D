#if !targetEnvironment(simulator)
import SwiftUI
import ARKit
import RealityKit

struct ARScannerViewRepresentable: UIViewRepresentable {
    @ObservedObject var scanner: LiDARScanner
    @Binding var showMeshOverlay: Bool
    var previewRange: Float

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.session = scanner.arSession
        view.automaticallyConfigureSession = false
        view.environment.sceneUnderstanding.options = []
        view.renderOptions = [.disableMotionBlur]
        let coordinator = context.coordinator
        coordinator.view = view; coordinator.scanner = scanner
        if let feedback = coordinator.feedback {
            view.renderCallbacks.postProcess = { [weak feedback] context in feedback?.render(context) }
        } else {
            DispatchQueue.main.async {
                scanner.scanError = "Live coverage preview could not start. Capture range filtering still applies. Reopen the scanner to retry."
            }
        }
        coordinator.start()
        let coaching = ARCoachingOverlayView()
        coaching.session = scanner.arSession
        coaching.goal = .tracking
        coaching.activatesAutomatically = true
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coaching.frame = view.bounds
        view.addSubview(coaching)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        if view.session !== scanner.arSession {
            context.coordinator.feedback?.reset()
            view.session = scanner.arSession
            for case let coaching as ARCoachingOverlayView in view.subviews { coaching.session = scanner.arSession }
        }
        context.coordinator.showCoverage = showMeshOverlay
        context.coordinator.previewRange = previewRange
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        coordinator.link?.invalidate(); coordinator.link = nil
        view.renderCallbacks.postProcess = nil
        coordinator.feedback?.reset()
    }

    final class Coordinator: NSObject {
        weak var view: ARView?
        weak var scanner: LiDARScanner?
        let feedback = LiveCaptureFeedback()
        var showCoverage = true
        var previewRange: Float = 3
        var link: CADisplayLink?

        func start() {
            link = CADisplayLink(target: self, selector: #selector(update))
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link?.add(to: .main, forMode: .common)
        }

        @objc private func update() {
            guard let view, let scanner, let frame = view.session.currentFrame,
                  view.bounds.width > 0, view.bounds.height > 0 else { return }
            feedback?.update(frame: frame, accepted: scanner.acceptedDepthFrame, viewport: view.bounds.size,
                orientation: view.window?.windowScene?.interfaceOrientation ?? .portrait,
                range: scanner.isScanning ? scanner.rangeMeters : previewRange,
                showCoverage: showCoverage && scanner.isScanning)
        }
    }
}
#endif
