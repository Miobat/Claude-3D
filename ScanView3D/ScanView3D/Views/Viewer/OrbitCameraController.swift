import UIKit
import SceneKit
import simd

/// Touch navigation for the 3D viewer, replacing SceneKit's built-in camera
/// control (whose two-finger pan is hard to use):
/// - one finger: orbit around the focus point (model stays upright, no roll)
/// - two fingers: pan — the model moves with your fingers at any zoom level
/// - pinch: zoom (works together with the two-finger pan)
/// - double-tap: move the focus point to the tapped spot
final class OrbitCameraController: NSObject, UIGestureRecognizerDelegate {
    private weak var view: SCNView?
    private weak var cameraNode: SCNNode?

    /// Point the camera looks at and orbits around (world space).
    private(set) var target = SIMD3<Float>(0, 0, 0)
    /// Distance from the target (perspective camera).
    private(set) var distance: Float = 5
    /// Turn around the vertical axis and tilt up/down (radians).
    private(set) var yaw: Float = 0
    private(set) var pitch: Float = -0.29

    private var minDistance: Float = 0.02
    private var maxDistance: Float = 1000

    /// Returns the model surface under a screen point (for double-tap focus).
    var surfacePoint: ((CGPoint) -> SIMD3<Float>?)?

    private var orbitPan: UIPanGestureRecognizer!
    private var movePan: UIPanGestureRecognizer!
    private var pinch: UIPinchGestureRecognizer!
    private var inertia = SIMD2<Float>(0, 0)
    private var inertiaLink: CADisplayLink?

    private let orbitSpeed: Float = 0.006        // radians per point dragged
    private let maxPitch: Float = 89.5 * .pi / 180

    init(view: SCNView, cameraNode: SCNNode) {
        self.view = view
        self.cameraNode = cameraNode
        super.init()
    }

    deinit { inertiaLink?.invalidate() }

    /// Adds the gestures. Returns the double-tap recognizer so single-tap
    /// handlers can wait for it to fail.
    @discardableResult
    func install() -> UITapGestureRecognizer {
        guard let view = view else { return UITapGestureRecognizer() }
        orbitPan = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
        orbitPan.maximumNumberOfTouches = 1
        orbitPan.delegate = self
        movePan = UIPanGestureRecognizer(target: self, action: #selector(handleMove(_:)))
        movePan.minimumNumberOfTouches = 2
        movePan.maximumNumberOfTouches = 2
        movePan.delegate = self
        pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(orbitPan)
        view.addGestureRecognizer(movePan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(doubleTap)
        return doubleTap
    }

    // Two-finger pan and pinch run together; nothing else does.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g === movePan && other === pinch) || (g === pinch && other === movePan)
    }

    // MARK: - Placing the camera

    private var orientation: simd_quatf {
        simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)) * simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
    }

    /// Position the camera from target / distance / yaw / pitch.
    func apply(animated: Bool = false) {
        guard let node = cameraNode else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.4 : 0
        let q = orientation
        node.simdOrientation = q
        node.simdPosition = target + q.act(SIMD3<Float>(0, 0, distance))
        SCNTransaction.commit()
    }

    /// Frame a model: look at its centre from the front, slightly above.
    func frame(center: SIMD3<Float>, extent: Float, animated: Bool = false) {
        let size = max(extent, 0.05)
        minDistance = size * 0.01
        maxDistance = size * 30 + 10
        target = center
        distance = size * 2.1
        yaw = 0
        pitch = -0.29
        apply(animated: animated)
    }

    /// Jump to a fixed view (e.g. top/front/side).
    func set(yaw: Float, pitch: Float, target: SIMD3<Float>, distance: Float, animated: Bool = true) {
        stopInertia()
        self.yaw = yaw
        self.pitch = pitch
        self.target = target
        self.distance = min(max(distance, minDistance), maxDistance)
        apply(animated: animated)
    }

    /// Pick up where the camera is after something else moved it (joysticks).
    func syncFromCamera() {
        guard let node = cameraNode else { return }
        let m = node.simdWorldTransform
        let forward = -simd_normalize(SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        pitch = asin(min(1, max(-1, forward.y)))
        yaw = atan2(-forward.x, -forward.z)
        target = node.simdPosition + forward * distance
    }

    // MARK: - Gestures

    @objc private func handleOrbit(_ g: UIPanGestureRecognizer) {
        guard let view = view else { return }
        switch g.state {
        case .began:
            stopInertia()
        case .changed:
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            rotate(dx: Float(t.x), dy: Float(t.y))
        case .ended:
            let v = g.velocity(in: view)
            startInertia(SIMD2<Float>(Float(v.x), Float(v.y)))
        default:
            break
        }
    }

    private func rotate(dx: Float, dy: Float) {
        yaw -= dx * orbitSpeed
        pitch = min(maxPitch, max(-maxPitch, pitch - dy * orbitSpeed))
        apply()
    }

    @objc private func handleMove(_ g: UIPanGestureRecognizer) {
        guard let view = view, g.state == .changed || g.state == .began else { return }
        stopInertia()
        let t = g.translation(in: view)
        g.setTranslation(.zero, in: view)
        let k = worldUnitsPerPoint()
        let q = orientation
        let right = q.act(SIMD3<Float>(1, 0, 0))
        let up = q.act(SIMD3<Float>(0, 1, 0))
        // Screen y grows downwards.
        target += (-right * Float(t.x) + up * Float(t.y)) * k
        apply()
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard g.state == .changed || g.state == .began, g.scale > 0 else { return }
        stopInertia()
        let s = Float(g.scale)
        g.scale = 1
        if let camera = cameraNode?.camera, camera.usesOrthographicProjection {
            let scale = camera.orthographicScale / Double(s)
            camera.orthographicScale = min(max(scale, Double(minDistance) * 0.5), Double(maxDistance))
        } else {
            distance = min(max(distance / s, minDistance), maxDistance)
            apply()
        }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard let view = view, let p = surfacePoint?(g.location(in: view)) else { return }
        stopInertia()
        // Keep the camera's direction, move the focus to the tapped point, come a bit closer.
        target = p
        distance = max(minDistance, distance * 0.75)
        apply(animated: true)
    }

    /// World distance covered by one screen point at the focus depth.
    private func worldUnitsPerPoint() -> Float {
        guard let view = view, let camera = cameraNode?.camera else { return 0.001 }
        let height = Float(max(view.bounds.height, 1))
        if camera.usesOrthographicProjection {
            return Float(camera.orthographicScale) * 2 / height
        }
        let fov = Float(camera.fieldOfView) * .pi / 180
        return 2 * distance * tan(fov / 2) / height
    }

    // MARK: - Inertia (orbit only)

    private func startInertia(_ velocity: SIMD2<Float>) {
        guard simd_length(velocity) > 80 else { return }
        inertia = velocity
        inertiaLink?.invalidate()
        inertiaLink = CADisplayLink(target: self, selector: #selector(stepInertia(_:)))
        inertiaLink?.add(to: .main, forMode: .common)
    }

    @objc private func stepInertia(_ link: CADisplayLink) {
        let dt = Float(max(link.targetTimestamp - link.timestamp, 1.0 / 120))
        rotate(dx: inertia.x * dt, dy: inertia.y * dt)
        inertia *= 0.9
        if simd_length(inertia) < 15 { stopInertia() }
    }

    private func stopInertia() {
        inertiaLink?.invalidate()
        inertiaLink = nil
        inertia = .zero
    }
}
