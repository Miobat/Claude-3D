import SwiftUI
import SceneKit
import SpriteKit
import Combine

/// UIViewRepresentable wrapper for SceneKit 3D viewer
struct SceneKitViewRepresentable: UIViewRepresentable {
    let scan: Scan
    let project: Project
    let storageManager: StorageManager
    @Binding var modelNode: SCNNode?
    @Binding var isLoading: Bool
    @Binding var loadError: String?
    @Binding var showGrid: Bool
    @Binding var showBoundingBox: Bool
    @Binding var vizMode: ModelViewerView.VisualizationMode
    @Binding var activeTool: ModelViewerView.ViewerTool
    let session: MeasurementSession
    @ObservedObject var navigation: WalkNavigation

    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView(frame: .zero)
        sceneView.scene = SCNScene()
        sceneView.backgroundColor = UIColor(FieldStyle.viewport)
        sceneView.autoenablesDefaultLighting = false
        sceneView.allowsCameraControl = false   // our own touch navigation below
        sceneView.antialiasingMode = .multisampling4X

        setupLighting(sceneView.scene!)
        setupCamera(sceneView)

        let coordinator = context.coordinator
        if let cameraNode = sceneView.pointOfView {
            let controller = OrbitCameraController(view: sceneView, cameraNode: cameraNode)
            controller.surfacePoint = { [weak coordinator] location in coordinator?.surfacePointForFocus(at: location) }
            controller.groundPoint = { [weak coordinator] point in coordinator?.ground(at: point) }
            controller.movementBlocked = { [weak coordinator] a, b in coordinator?.walkBlocked(from: a, to: b) ?? true }
            controller.walkMessage = { [weak coordinator] message in
                guard let coordinator, coordinator.parent.navigation.message != message else { return }
                coordinator.parent.navigation.message = message
            }
            let doubleTap = controller.install()
            coordinator.cameraController = controller

            let tapGesture = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
            tapGesture.require(toFail: doubleTap)
            sceneView.addGestureRecognizer(tapGesture)
        }

        context.coordinator.sceneView = sceneView

        // Flat measurement overlay (constant-size lines and labels) drawn by
        // SpriteKit on top of the 3D view, refreshed from the render loop.
        let overlay = MeasurementOverlayScene(size: CGSize(width: 400, height: 800))
        sceneView.overlaySKScene = overlay
        sceneView.delegate = context.coordinator
        context.coordinator.attach(session: session, overlay: overlay)

        loadModel(sceneView: sceneView, context: context)

        // Register for all notifications
        let nc = NotificationCenter.default
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.resetCamera), name: .resetCameraView, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.handleJoystickMove(_:)), name: .joystickMove, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.handleJoystickLook(_:)), name: .joystickLook, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.handleJoystickElevate(_:)), name: .joystickElevate, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.stopNavigation), name: .stopViewerNavigation, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.stopNavigation), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.handleSetCameraView(_:)), name: .setCameraView, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.handleSetCameraProjection(_:)), name: .setCameraProjection, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.handleSetVisualizationMode(_:)), name: .setVisualizationMode, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.handleCaptureTopDown), name: .captureTopDownImage, object: nil)

        return sceneView
    }

    func updateUIView(_ sceneView: SCNView, context: Context) {
        // Grid
        let gridNode = sceneView.scene?.rootNode.childNode(withName: "grid", recursively: false)
        if showGrid && gridNode == nil, let model = modelNode { addGrid(to: sceneView.scene!, under: model) }
        else if !showGrid { gridNode?.removeFromParentNode() }

        // Bounding box
        let bbNode = sceneView.scene?.rootNode.childNode(withName: "boundingBox", recursively: false)
        if showBoundingBox && bbNode == nil, let model = modelNode {
            addBoundingBox(to: sceneView.scene!, for: model)
        } else if !showBoundingBox { bbNode?.removeFromParentNode() }

        context.coordinator.activeTool = activeTool
        context.coordinator.updateWalkMode()
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.stopNavigation()
        coordinator.tearDown()
        view.delegate = nil
        view.overlaySKScene = nil
        view.gestureRecognizers?.forEach { view.removeGestureRecognizer($0) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: - Scene Setup

    private func setupLighting(_ scene: SCNScene) {
        let ambientNode = SCNNode()
        ambientNode.light = SCNLight()
        ambientNode.light!.type = .ambient
        ambientNode.light!.color = UIColor(white: 0.4, alpha: 1.0)
        ambientNode.light!.intensity = 500
        scene.rootNode.addChildNode(ambientNode)

        let keyLightNode = SCNNode()
        keyLightNode.light = SCNLight()
        keyLightNode.light!.type = .directional
        keyLightNode.light!.color = UIColor.white
        keyLightNode.light!.intensity = 800
        keyLightNode.light!.castsShadow = true
        keyLightNode.position = SCNVector3(5, 10, 5)
        keyLightNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(keyLightNode)

        let fillLightNode = SCNNode()
        fillLightNode.light = SCNLight()
        fillLightNode.light!.type = .directional
        fillLightNode.light!.color = UIColor(white: 0.8, alpha: 1.0)
        fillLightNode.light!.intensity = 400
        fillLightNode.position = SCNVector3(-5, 5, -5)
        fillLightNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(fillLightNode)

        let bottomLightNode = SCNNode()
        bottomLightNode.light = SCNLight()
        bottomLightNode.light!.type = .directional
        bottomLightNode.light!.intensity = 200
        bottomLightNode.position = SCNVector3(0, -5, 0)
        bottomLightNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(bottomLightNode)
    }

    private func setupCamera(_ sceneView: SCNView) {
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        cameraNode.camera = SCNCamera()
        cameraNode.camera!.zNear = 0.01
        cameraNode.camera!.zFar = 1000
        cameraNode.camera!.fieldOfView = 60
        cameraNode.camera!.usesOrthographicProjection = false
        cameraNode.position = SCNVector3(0, 2, 5)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        sceneView.scene?.rootNode.addChildNode(cameraNode)
        sceneView.pointOfView = cameraNode
    }

    /// Grid lying under the model (at its lowest point, i.e. the floor), sized to fit.
    private func addGrid(to scene: SCNScene, under model: SCNNode) {
        let (minB, maxB) = SceneKitViewRepresentable.worldBounds(of: model)
        let extent = max(maxB.x - minB.x, maxB.z - minB.z)
        let spacing: Float = extent > 40 ? 5 : (extent > 12 ? 1 : 0.5)
        let half = (max(extent * 0.75, 2) / spacing).rounded(.up) * spacing
        let lineRadius = CGFloat(max(0.002, spacing * 0.004))
        let color = UIColor(white: 0.5, alpha: 0.35)

        let gridNode = SCNNode()
        gridNode.name = "grid"
        gridNode.position = SCNVector3((minB.x + maxB.x) / 2, minB.y, (minB.z + maxB.z) / 2)
        let lineCount = Int(half / spacing)
        for i in -lineCount...lineCount {
            let pos = Float(i) * spacing
            let xGeometry = SCNCylinder(radius: lineRadius, height: CGFloat(half * 2))
            xGeometry.firstMaterial?.diffuse.contents = color
            let xNode = SCNNode(geometry: xGeometry)
            xNode.position = SCNVector3(0, 0, pos)
            xNode.eulerAngles = SCNVector3(0, 0, Float.pi / 2)
            gridNode.addChildNode(xNode)

            let zGeometry = SCNCylinder(radius: lineRadius, height: CGFloat(half * 2))
            zGeometry.firstMaterial?.diffuse.contents = color
            let zNode = SCNNode(geometry: zGeometry)
            zNode.position = SCNVector3(pos, 0, 0)
            zNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            gridNode.addChildNode(zNode)
        }
        scene.rootNode.addChildNode(gridNode)
    }

    /// World-space bounds of the model node (its own box, moved by its transform).
    static func worldBounds(of node: SCNNode) -> (SIMD3<Float>, SIMD3<Float>) {
        let (mn, mx) = node.boundingBox
        let m = node.simdTransform
        var corners: [SIMD3<Float>] = []
        for x in [mn.x, mx.x] { for y in [mn.y, mx.y] { for z in [mn.z, mx.z] {
            let w = m * SIMD4<Float>(Float(x), Float(y), Float(z), 1)
            corners.append(SIMD3<Float>(w.x, w.y, w.z))
        } } }
        return MeshData.bounds(of: corners)
    }

    private func addBoundingBox(to scene: SCNScene, for model: SCNNode) {
        let (minB, maxB) = SceneKitViewRepresentable.worldBounds(of: model)
        let size = maxB - minB
        let center = (minB + maxB) / 2

        let box = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0)
        box.firstMaterial?.diffuse.contents = UIColor.clear
        box.firstMaterial?.fillMode = .lines
        box.firstMaterial?.emission.contents = UIColor.cyan.withAlphaComponent(0.5)
        box.firstMaterial?.isDoubleSided = true

        let boxNode = SCNNode(geometry: box)
        boxNode.name = "boundingBox"
        boxNode.simdPosition = center
        scene.rootNode.addChildNode(boxNode)
    }

    private func loadModel(sceneView: SCNView, context: Context) {
        let fileURL = storageManager.getScanFileURL(scan: scan, project: project)

        // Try native SceneKit format first (faster, preserves materials), fall back to OBJ
        let scnURL = fileURL.deletingPathExtension().appendingPathExtension("scn")

        DispatchQueue.global(qos: .userInitiated).async {
            var node: SCNNode?

            // Prefer .scn for internal viewing (preserves vertex colors, materials)
            if FileManager.default.fileExists(atPath: scnURL.path) {
                if let scene = try? SCNScene(url: scnURL, options: [.checkConsistency: false]) {
                    let container = SCNNode()
                    for child in scene.rootNode.childNodes {
                        let cloned = child.clone()
                        cloned.geometry?.materials.forEach { $0.isDoubleSided = true }
                        cloned.enumerateChildNodes { n, _ in
                            n.geometry?.materials.forEach { $0.isDoubleSided = true }
                        }
                        container.addChildNode(cloned)
                    }
                    node = container
                }
            }

            // Fall back to OBJ/PLY loading
            if node == nil {
                node = MeshProcessor.createSceneKitNode(fromOBJ: fileURL)
            }

            DispatchQueue.main.async {
                if let node = node {
                    // Metric scale correction for photogrammetry models (which have
                    // no inherent real-world scale). Measurements use world-space
                    // hit coordinates, so scaling the node makes them read true metres.
                    if let m = scan.modelMatrix {
                        node.simdTransform = m
                    }
                    sceneView.scene?.rootNode.addChildNode(node)
                    self.modelNode = node

                    let (minB, maxB) = SceneKitViewRepresentable.worldBounds(of: node)
                    let centerV = (minB + maxB) / 2
                    let center = SCNVector3(centerV.x, centerV.y, centerV.z)
                    let extent = maxB - minB
                    let distance = max(max(extent.x, max(extent.y, extent.z)) * 2.0, 0.1)

                    context.coordinator.cameraController?.frame(center: centerV, extent: distance / 2)

                    context.coordinator.modelCenter = center
                    context.coordinator.modelExtent = extent
                    context.coordinator.viewDistance = distance
                    context.coordinator.collectPickablePoints(from: node)

                    // Surface index for snapping (corners, edges, wall directions).
                    let sources = ModelGeometryIndex.sources(in: node)
                    DispatchQueue.global(qos: .utility).async {
                        let index = ModelGeometryIndex.build(from: sources)
                        DispatchQueue.main.async { context.coordinator.geometryIndex = index }
                    }
                    self.isLoading = false
                } else {
                    self.loadError = "Failed to load model file"
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, SCNSceneRendererDelegate, MeasurementGeometryProvider {
        var parent: SceneKitViewRepresentable
        var sceneView: SCNView?
        var activeTool: ModelViewerView.ViewerTool = .orbit
        weak var session: MeasurementSession?
        var cameraController: OrbitCameraController?
        private var overlay: MeasurementOverlayScene?
        var geometryIndex: ModelGeometryIndex?
        private var previewTimer: Timer?
        private var activeCancellable: AnyCancellable?
        private var lastPreviewCamera: simd_float4x4?
        private var lastPreviewDraftCount = -1
        var modelCenter: SCNVector3 = SCNVector3(0, 0, 0)
        var modelExtent = SIMD3<Float>(1, 1, 1)
        var viewDistance: Float = 5.0

        /// World positions of point-cloud points (SceneKit can't hit-test points).
        private var pickablePoints: [SIMD3<Float>] = []
        private var pointPicker: PointCloudPicker?
        private var disposed = false
        private var walkEnabled = false
        /// Original material look, so "Textured" can restore it after Flat/Wireframe.
        private var originalMaterials: [ObjectIdentifier: (diffuse: Any?, emission: Any?, lighting: SCNMaterial.LightingModel, fill: SCNFillMode, shaders: [SCNShaderModifierEntryPoint: String]?)] = [:]

        private var navigationTimer: Timer?
        private var lastNavigationTick: TimeInterval = 0
        private var currentMoveDX: CGFloat = 0
        private var currentMoveDY: CGFloat = 0
        private var currentLookDX: CGFloat = 0
        private var currentLookDY: CGFloat = 0
        private var currentElevation: CGFloat = 0

        /// How close (on screen, in points) a tap must be to snap.
        private let snapDistance: CGFloat = 24

        init(parent: SceneKitViewRepresentable) { self.parent = parent }

        deinit {
            navigationTimer?.invalidate()
            previewTimer?.invalidate()
        }

        func tearDown() {
            disposed = true
            NotificationCenter.default.removeObserver(self)
            previewTimer?.invalidate(); previewTimer = nil
            activeCancellable?.cancel()
            session?.geometry = nil
            session?.renderSink = nil
        }

        func attach(session: MeasurementSession, overlay: MeasurementOverlayScene) {
            self.session = session
            self.overlay = overlay
            session.geometry = self
            session.renderSink = { [weak overlay] state in overlay?.update(state) }
            activeCancellable = session.$isActive
                .removeDuplicates()
                .sink { [weak self] on in self?.measuringChanged(on) }
        }

        // MARK: - Overlay refresh (SceneKit render thread)

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let overlay = overlay, let pov = renderer.pointOfView else { return }
            let height = overlay.size.height
            let ortho: Double = (pov.camera?.usesOrthographicProjection ?? false) ? (pov.camera?.orthographicScale ?? 0) : -1
            overlay.redrawIfNeeded(camera: pov.simdWorldTransform, ortho: ortho) { p in
                let v = renderer.projectPoint(SCNVector3(p.x, p.y, p.z))
                guard v.z > 0, v.z < 1 else { return nil }
                return CGPoint(x: CGFloat(v.x), y: height - CGFloat(v.y))
            }
        }

        // MARK: - Live snap preview at the crosshair

        private func measuringChanged(_ on: Bool) {
            sceneView?.rendersContinuously = on
            previewTimer?.invalidate()
            previewTimer = nil
            lastPreviewCamera = nil
            if on {
                previewTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                    self?.updatePreview()
                }
            } else if session?.preview != nil {
                session?.preview = nil
            }
        }

        private func updatePreview() {
            guard let view = sceneView, let session = session, session.isActive,
                  let camera = view.pointOfView?.simdWorldTransform else { return }
            // Only recompute when the view or the measurement in progress changed.
            if let last = lastPreviewCamera, Self.same(last, camera),
               lastPreviewDraftCount == session.draftPoints.count + (session.snappingEnabled ? 1000 : 0) + session.tool.hashValue {
                return
            }
            lastPreviewCamera = camera
            lastPreviewDraftCount = session.draftPoints.count + (session.snappingEnabled ? 1000 : 0) + session.tool.hashValue
            let result = snap(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
            if result != session.preview { session.preview = result }
        }

        private static func same(_ a: simd_float4x4, _ b: simd_float4x4) -> Bool {
            simd_distance(a.columns.3, b.columns.3) < 1e-5 &&
            simd_distance(a.columns.2, b.columns.2) < 1e-5 &&
            simd_distance(a.columns.0, b.columns.0) < 1e-5
        }

        // MARK: - Point Picking Support

        func collectPickablePoints(from root: SCNNode) {
            var points: [SIMD3<Float>] = []
            func visit(_ node: SCNNode) {
                if let geometry = node.geometry,
                   geometry.elements.contains(where: { $0.primitiveType == .point }),
                   let source = geometry.sources(for: .vertex).first {
                    let m = node.simdWorldTransform
                    let stride = source.dataStride, offset = source.dataOffset
                    let count = source.vectorCount
                    points.reserveCapacity(points.count + count)
                    source.data.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress, source.bytesPerComponent == 4 else { return }
                        for i in 0..<count {
                            let p = base.advanced(by: offset + stride * i).assumingMemoryBound(to: Float.self)
                            let w = m * SIMD4<Float>(p[0], p[1], p[2], 1)
                            points.append(SIMD3<Float>(w.x, w.y, w.z))
                        }
                    }
                }
                node.childNodes.forEach(visit)
            }
            visit(root)
            pickablePoints = points
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let picker = PointCloudPicker(points: points)
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.disposed else { return }
                    self.pointPicker = picker
                    self.lastPreviewCamera = nil
                }
            }
        }

        /// Front-most point-cloud point near a screen location.
        private func pickPoint(at location: CGPoint, in view: SCNView) -> SCNVector3? {
            guard let picker = pointPicker, let camera = view.pointOfView, let lens = camera.camera else { return nil }
            let projection = SCNMatrix4ToMat4(lens.projectionTransform(withViewportSize: view.bounds.size)) * camera.simdWorldTransform.inverse
            return picker.pick(at: SIMD2(Float(location.x), Float(location.y)),
                viewport: SIMD2(Float(view.bounds.width), Float(view.bounds.height)), projection: projection)
                .map { SCNVector3($0.x, $0.y, $0.z) }
        }

        // MARK: - Camera View Presets

        private var center: SIMD3<Float> { SIMD3<Float>(modelCenter.x, modelCenter.y, modelCenter.z) }

        @objc func handleSetCameraView(_ notification: Notification) {
            exitWalk()
            guard let viewStr = notification.userInfo?["view"] as? String, let rig = cameraController else { return }
            switch viewStr {
            case "top":
                rig.set(yaw: 0, pitch: -.pi / 2, target: center, distance: viewDistance * 0.75)
            case "front":
                rig.set(yaw: 0, pitch: 0, target: center, distance: viewDistance * 0.6)
            case "side":
                rig.set(yaw: .pi / 2, pitch: 0, target: center, distance: viewDistance * 0.6)
            default:
                break
            }
        }

        // MARK: - Camera Projection

        /// Orthographic scale that fits the model's footprint in the view.
        private func fittingOrthoScale(for view: SCNView) -> Double {
            let aspect = max(0.1, Float(view.bounds.width / max(view.bounds.height, 1)))
            let halfHeight = max(modelExtent.z / 2, modelExtent.x / 2 / aspect)
            return Double(max(halfHeight * 1.1, 0.05))
        }

        @objc func handleSetCameraProjection(_ notification: Notification) {
            exitWalk()
            guard let sceneView = sceneView,
                  let projStr = notification.userInfo?["projection"] as? String,
                  let camera = sceneView.pointOfView?.camera else { return }

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.4
            switch projStr {
            case "Ortho":
                camera.usesOrthographicProjection = true
                camera.orthographicScale = Double(viewDistance) * 0.5
            case "FloorPlan":
                camera.usesOrthographicProjection = true
                camera.orthographicScale = fittingOrthoScale(for: sceneView)
                cameraController?.set(yaw: 0, pitch: -.pi / 2, target: center, distance: viewDistance, animated: false)
            default: // Perspective
                camera.usesOrthographicProjection = false
                camera.fieldOfView = 60
            }
            SCNTransaction.commit()
        }

        /// Top-down orthographic snapshot with a scale bar, shared as an image.
        @objc func handleCaptureTopDown() {
            exitWalk()
            guard let sceneView = sceneView, let camera = sceneView.pointOfView?.camera else { return }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            camera.usesOrthographicProjection = true
            camera.orthographicScale = fittingOrthoScale(for: sceneView)
            SCNTransaction.commit()
            cameraController?.set(yaw: 0, pitch: -.pi / 2, target: center, distance: viewDistance, animated: false)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak sceneView] in
                guard let view = sceneView, let cam = view.pointOfView?.camera else { return }
                let metresPerPoint = Float(cam.orthographicScale) * 2 / Float(max(view.bounds.height, 1))
                let image = FloorPlanImage.addScaleBar(to: view.snapshot(), metresPerPoint: metresPerPoint,
                                                       unit: .preferred)
                ShareSheetPresenter.present([image])
            }
        }

        /// Surface point for double-tap focus.
        func surfacePointForFocus(at location: CGPoint) -> SIMD3<Float>? {
            guard let view = sceneView else { return nil }
            return surfaceHit(at: location, in: view)?.point
        }

        // MARK: - Visualization Mode

        @objc func handleSetVisualizationMode(_ notification: Notification) {
            guard let modeStr = notification.userInfo?["mode"] as? String,
                  let model = parent.modelNode else { return }

            let (minB, maxB) = SceneKitViewRepresentable.worldBounds(of: model)
            let step = Coordinator.contourStep(for: maxB.y - minB.y)

            func apply(to node: SCNNode) {
                for material in node.geometry?.materials ?? [] {
                    let id = ObjectIdentifier(material)
                    if originalMaterials[id] == nil {
                        originalMaterials[id] = (material.diffuse.contents, material.emission.contents,
                                                 material.lightingModel, material.fillMode, material.shaderModifiers)
                    }
                    // Start every mode from the original look.
                    if let original = originalMaterials[id] {
                        material.diffuse.contents = original.diffuse
                        material.emission.contents = original.emission
                        material.lightingModel = original.lighting
                        material.fillMode = original.fill
                        material.shaderModifiers = original.shaders
                    }
                    switch modeStr {
                    case "Flat":
                        material.diffuse.contents = UIColor(white: 0.85, alpha: 1.0)
                        material.emission.contents = UIColor.black
                        material.lightingModel = .physicallyBased
                    case "Wireframe":
                        material.fillMode = .lines
                        material.diffuse.contents = UIColor.cyan
                        material.lightingModel = .constant
                    case "Height":
                        material.shaderModifiers = [.surface: Coordinator.heightShader]
                        material.setValue(NSNumber(value: minB.y), forKey: "heightMin")
                        material.setValue(NSNumber(value: maxB.y), forKey: "heightMax")
                        material.setValue(NSNumber(value: step), forKey: "contourStep")
                    default:
                        break   // Textured: the original look restored above
                    }
                    material.isDoubleSided = true
                }
            }
            apply(to: model)
            model.enumerateChildNodes { child, _ in apply(to: child) }
        }

        /// Colours the surface by world height (blue low → red high) with dark
        /// contour lines every `contourStep` metres.
        static let heightShader = """
        #pragma arguments
        float heightMin;
        float heightMax;
        float contourStep;
        #pragma body
        float4 worldPos = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
        float h = worldPos.y;
        float t = clamp((h - heightMin) / max(heightMax - heightMin, 0.001), 0.0, 1.0);
        float3 c;
        if (t < 0.25) { c = mix(float3(0.10, 0.20, 0.80), float3(0.00, 0.70, 0.90), t / 0.25); }
        else if (t < 0.5) { c = mix(float3(0.00, 0.70, 0.90), float3(0.20, 0.80, 0.20), (t - 0.25) / 0.25); }
        else if (t < 0.75) { c = mix(float3(0.20, 0.80, 0.20), float3(0.95, 0.85, 0.10), (t - 0.5) / 0.25); }
        else { c = mix(float3(0.95, 0.85, 0.10), float3(0.90, 0.20, 0.10), (t - 0.75) / 0.25); }
        float f = fract(h / max(contourStep, 0.001));
        float onLine = step(f, 0.03) + step(0.97, f);
        c = mix(c, float3(0.08, 0.08, 0.08), clamp(onLine, 0.0, 1.0) * 0.7);
        _surface.diffuse = float4(c, 1.0);
        """

        /// Contour spacing giving roughly 10 lines over the height range.
        static func contourStep(for range: Float) -> Float {
            let options: [Float] = [0.01, 0.02, 0.05, 0.1, 0.2, 0.25, 0.5, 1, 2, 5, 10, 20, 50]
            let wanted = max(range, 0.01) / 10
            return options.first(where: { $0 >= wanted }) ?? 50
        }

        // MARK: - Tap / Measure

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            if walkEnabled {
                guard let view = sceneView, let hit = surfaceHit(at: gesture.location(in: view), in: view),
                      let start = ground(at: hit.point), abs(start.y - hit.point.y) < 0.12,
                      !walkBlocked(from: start, to: start) else {
                    parent.navigation.message = "Choose a clear, scanned floor or ground surface"
                    return
                }
                stopNavigation()
                cameraController?.beginWalk(at: start)
                parent.navigation.isWalking = true
                parent.navigation.message = "Walk · Eye height 1.8 m · Ground locked"
                return
            }
            guard activeTool == .measure, let sceneView = sceneView, let session = session else { return }
            if let result = snap(at: gesture.location(in: sceneView)) {
                session.place(result)
            }
        }

        private let helperNames: Set<String> = ["measurementNode", "axisGuide", "grid", "boundingBox", "camera"]

        private func isHelper(_ node: SCNNode) -> Bool {
            var n: SCNNode? = node
            while let current = n {
                if let name = current.name, helperNames.contains(name) { return true }
                n = current.parent
            }
            return false
        }

        /// The model surface under a screen location: mesh hit (with its normal),
        /// or the nearest point for point clouds.
        private func surfaceHit(at location: CGPoint, in view: SCNView) -> (point: SIMD3<Float>, normal: SIMD3<Float>?)? {
            let hits = view.hitTest(location, options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .ignoreHiddenNodes: true
            ])
            if let hit = hits.first(where: { !isHelper($0.node) &&
                $0.node.geometry?.elements.contains(where: { $0.primitiveType == .triangles || $0.primitiveType == .triangleStrip }) == true }) {
                let p = hit.worldCoordinates, n = hit.worldNormal
                return (SIMD3<Float>(p.x, p.y, p.z), simd_normalize(SIMD3<Float>(n.x, n.y, n.z)))
            }
            if let p = pickPoint(at: location, in: view) {
                return (SIMD3<Float>(p.x, p.y, p.z), nil)
            }
            return nil
        }

        /// Model surfaces crossed by the segment a→b (world space).
        private func segmentHits(from a: SIMD3<Float>, to b: SIMD3<Float>) -> [SIMD3<Float>] {
            guard let root = sceneView?.scene?.rootNode else { return [] }
            let results = root.hitTestWithSegment(
                from: SCNVector3(a.x, a.y, a.z), to: SCNVector3(b.x, b.y, b.z),
                options: [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue,
                          SCNHitTestOption.backFaceCulling.rawValue: false])
            return results.filter { !isHelper($0.node) &&
                $0.node.geometry?.elements.contains(where: { $0.primitiveType == .triangles || $0.primitiveType == .triangleStrip }) == true }.map {
                SIMD3<Float>($0.worldCoordinates.x, $0.worldCoordinates.y, $0.worldCoordinates.z)
            }
        }

        /// Where a tap (or the crosshair) should land, following the snapping rules:
        /// existing point > corner > edge > vertical / wall direction > level > surface.
        /// All thresholds are screen distances, so it behaves the same at any scale.
        func snap(at location: CGPoint) -> SnapResult? {
            guard let view = sceneView, let session = session,
                  let hit = surfaceHit(at: location, in: view) else { return nil }
            let p = hit.point
            let surface = SnapResult(point: p, kind: .surface, normal: hit.normal)
            guard session.snappingEnabled else { return surface }
            // Point clouds must land on a rendered sample. A fitted corner / axis
            // can move the result off the touched surface, especially near edges.
            if !pickablePoints.isEmpty && hit.normal == nil { return surface }

            func screenDistance(_ q: SIMD3<Float>) -> CGFloat {
                let s = view.projectPoint(SCNVector3(q.x, q.y, q.z))
                guard s.z > 0, s.z < 1 else { return .greatestFiniteMagnitude }
                return hypot(CGFloat(s.x) - location.x, CGFloat(s.y) - location.y)
            }

            // 1. Existing points (to chain or close shapes)
            var bestPoint: (SIMD3<Float>, CGFloat)?
            for q in session.snapTargets {
                let d = screenDistance(q)
                if d < snapDistance, d < (bestPoint?.1 ?? .greatestFiniteMagnitude) { bestPoint = (q, d) }
            }
            if let bp = bestPoint { return SnapResult(point: bp.0, kind: .point, normal: hit.normal) }

            // 2. Corners and edges: fit up to three flat surfaces around the tap.
            var normal = hit.normal
            var edgeCandidate: SnapResult?
            if let index = geometryIndex {
                let nb = index.neighbours(of: p, radius: index.radius * 1.5, limit: 1200)
                if nb.count >= 30 {
                    let planes = GeometryMath.ransacPlanes(nb, tolerance: max(0.004, index.radius * 0.12),
                                                           maxPlanes: 3, minInliers: max(10, nb.count / 8))
                    if normal == nil, let own = planes.min(by: { abs($0.signedDistance(p)) < abs($1.signedDistance(p)) }) {
                        normal = own.normal
                    }
                    if planes.count >= 3, let c = GeometryMath.intersect(planes[0], planes[1], planes[2]),
                       simd_distance(c, p) < index.radius * 2, screenDistance(c) < snapDistance {
                        return SnapResult(point: c, kind: .corner, normal: normal)
                    }
                    if planes.count >= 2, let lineInfo = GeometryMath.intersect(planes[0], planes[1]) {
                        let e = lineInfo.point + lineInfo.direction * simd_dot(p - lineInfo.point, lineInfo.direction)
                        if simd_distance(e, p) < index.radius * 1.5, screenDistance(e) < snapDistance * 0.8 {
                            edgeCandidate = SnapResult(point: e, kind: .edge, normal: normal)
                        }
                    }
                }
            }
            if let edge = edgeCandidate { return edge }

            // 3. Straight up/down or along a wall direction from the previous point.
            if session.tool.usesAxisSnapping, let a = session.draftPoints.last {
                let near = view.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 0))
                let far = view.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 1))
                let o = SIMD3<Float>(near.x, near.y, near.z)
                let d = SIMD3<Float>(far.x, far.y, far.z) - o

                var axes: [(SIMD3<Float>, SnapKind)] = [(SIMD3<Float>(0, 1, 0), .vertical)]
                for w in geometryIndex?.wallAxes ?? [] { axes.append((w, .wallAxis)) }

                var bestAxis: (SIMD3<Float>, SIMD3<Float>, SnapKind, CGFloat)?
                for (u, kind) in axes {
                    guard let x = GeometryMath.closestPoint(onLine: a, direction: u, toRay: o, direction: d),
                          simd_distance(x, a) > 0.01 else { continue }
                    let sd = screenDistance(x)
                    if sd < snapDistance, sd < (bestAxis?.3 ?? .greatestFiniteMagnitude) { bestAxis = (x, u, kind, sd) }
                }
                if let best = bestAxis {
                    let landed = landOnSurface(from: a, along: best.1, near: best.0) ?? best.0
                    return SnapResult(point: landed, kind: best.2, normal: normal)
                }

                // Same height as the previous point (keeps the point on walls).
                let level = SIMD3<Float>(p.x, a.y, p.z)
                if abs(p.y - a.y) < simd_distance(SIMD2<Float>(p.x, p.z), SIMD2<Float>(a.x, a.z)),
                   screenDistance(level) < snapDistance {
                    return SnapResult(point: level, kind: .level, normal: normal)
                }
            }

            return SnapResult(point: p, kind: .surface, normal: normal)
        }

        /// Ray-cast from `a` along `u` and return the surface hit closest to `x`
        /// (e.g. the ceiling exactly above a floor point). Meshes only.
        private func landOnSurface(from a: SIMD3<Float>, along u: SIMD3<Float>, near x: SIMD3<Float>) -> SIMD3<Float>? {
            let offset = x - a
            let dist = simd_length(offset)
            guard dist > 0.02 else { return nil }
            let dir = simd_dot(offset, u) >= 0 ? u : -u
            let reach = dist * 1.3 + (geometryIndex?.radius ?? 0.1)
            let hits = segmentHits(from: a + dir * 0.01, to: a + dir * reach)
            guard let closest = hits.min(by: { simd_distance($0, x) < simd_distance($1, x) }) else { return nil }
            let tolerance = max(geometryIndex?.radius ?? 0.05, dist * 0.12)
            return simd_distance(closest, x) < tolerance ? closest : nil
        }

        // MARK: - MeasurementGeometryProvider

        func verticalSpan(at p: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>)? {
            let up = SIMD3<Float>(0, 1, 0)
            let reach = (geometryIndex.map { $0.maxY - $0.minY } ?? 10) + 1
            func nearest(_ pts: [SIMD3<Float>]) -> SIMD3<Float>? {
                pts.min(by: { simd_distance($0, p) < simd_distance($1, p) })
            }
            var top = nearest(segmentHits(from: p + up * 0.02, to: p + up * reach))
            var bottom = nearest(segmentHits(from: p - up * 0.02, to: p - up * reach))
            if top == nil && bottom == nil, let index = geometryIndex {
                // Point clouds: look for points in a thin column instead.
                let column = index.column(at: p, halfWidth: max(index.radius * 0.4, 0.02))
                top = column.above.map { SIMD3<Float>(p.x, $0, p.z) }
                bottom = column.below.map { SIMD3<Float>(p.x, $0, p.z) }
            }
            // Keep the measurement exactly vertical through the chosen point.
            let t = top.map { SIMD3<Float>(p.x, $0.y, p.z) }
            let b = bottom.map { SIMD3<Float>(p.x, $0.y, p.z) }
            if let b = b, let t = t { return (b, t) }
            if let t = t { return (p, t) }
            if let b = b { return (b, p) }
            return nil
        }

        func surfacePlane(at p: SIMD3<Float>, fallbackNormal: SIMD3<Float>?) -> (point: SIMD3<Float>, normal: SIMD3<Float>) {
            let fallback = (p, fallbackNormal ?? SIMD3<Float>(0, 1, 0))
            guard let index = geometryIndex else { return fallback }
            let nb = index.neighbours(of: p, radius: index.radius, limit: 800)
            guard nb.count >= 12 else { return fallback }
            // Near a corner the neighbourhood holds several surfaces; use the one the point is on.
            let planes = GeometryMath.ransacPlanes(nb, tolerance: max(0.004, index.radius * 0.12),
                                                   maxPlanes: 3, minInliers: max(10, nb.count / 5))
            guard let plane = planes.min(by: { abs($0.signedDistance(p)) < abs($1.signedDistance(p)) })
                    ?? GeometryMath.fitPlane(nb) else { return fallback }
            // Project onto the fitted surface: averages out LiDAR noise.
            return (p - plane.normal * plane.signedDistance(p), plane.normal)
        }

        @objc func resetCamera() {
            exitWalk()
            guard let camera = sceneView?.pointOfView?.camera else { return }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.4
            camera.usesOrthographicProjection = false
            camera.fieldOfView = 60
            SCNTransaction.commit()
            cameraController?.frame(center: center, extent: viewDistance / 2, animated: true)
        }

        // MARK: - Joystick Handlers

        @objc func handleJoystickMove(_ notification: Notification) {
            currentMoveDX = (notification.userInfo?["dx"] as? CGFloat) ?? 0
            currentMoveDY = (notification.userInfo?["dy"] as? CGFloat) ?? 0
            updateNavigationTimer()
        }

        @objc func handleJoystickLook(_ notification: Notification) {
            currentLookDX = (notification.userInfo?["dx"] as? CGFloat) ?? 0
            currentLookDY = (notification.userInfo?["dy"] as? CGFloat) ?? 0
            updateNavigationTimer()
        }

        @objc func handleJoystickElevate(_ notification: Notification) {
            currentElevation = (notification.userInfo?["dy"] as? CGFloat) ?? 0
            updateNavigationTimer()
        }

        @objc func stopNavigation() {
            currentMoveDX = 0; currentMoveDY = 0
            currentLookDX = 0; currentLookDY = 0; currentElevation = 0
            navigationTimer?.invalidate(); navigationTimer = nil
            cameraController?.stopInertia()
        }

        private func updateNavigationTimer() {
            if currentMoveDX == 0 && currentMoveDY == 0 && currentLookDX == 0 &&
                currentLookDY == 0 && currentElevation == 0 {
                navigationTimer?.invalidate(); navigationTimer = nil
            } else if navigationTimer == nil {
                lastNavigationTick = CACurrentMediaTime()
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.navigationTick() }
                RunLoop.main.add(timer, forMode: .common)
                navigationTimer = timer
            }
        }

        private func navigationTick() {
            let now = CACurrentMediaTime()
            let dt = Float(min(0.05, max(0, now - lastNavigationTick)))
            lastNavigationTick = now
            // Same deflection: old move 0.02/frame -> 0.01; look 0.02 -> 0.04,
            // with 30 legacy ticks/second. Time-based on 60 and 120 Hz displays.
            let speed = walkEnabled ? Float(1.4 / 0.56) : viewDistance * 0.01 * 30
            cameraController?.look(dx: Float(currentLookDX) * 0.04 * 30 * dt,
                                   dy: Float(currentLookDY) * 0.04 * 30 * dt)
            cameraController?.move(right: Float(currentMoveDX) * speed * dt,
                forward: Float(-currentMoveDY) * speed * dt,
                elevation: Float(currentElevation) * viewDistance * 0.01 * 30 * dt)
        }

        func updateWalkMode() {
            let enabled = parent.navigation.enabled && parent.scan.hasKnownScale
            guard enabled != walkEnabled else { return }
            stopNavigation()
            walkEnabled = enabled
            if enabled { cameraController?.choosingWalkStart = true }
            else { cameraController?.endWalk() }
        }

        private func exitWalk() {
            stopNavigation()
            walkEnabled = false
            cameraController?.endWalk()
            parent.navigation.enabled = false
            parent.navigation.isWalking = false
        }

        /// Downward mesh ray, or a locally supported point-cloud plane. Restrict
        /// height to one modest step so upstairs/ceilings cannot become the floor.
        func ground(at p: SIMD3<Float>) -> SIMD3<Float>? {
            guard let root = sceneView?.scene?.rootNode else { return nil }
            let reach = WalkGeometry.maximumStep
            let results = root.hitTestWithSegment(from: SCNVector3(p.x, p.y + reach + 0.01, p.z),
                to: SCNVector3(p.x, p.y - reach - 0.01, p.z),
                options: [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue,
                          SCNHitTestOption.backFaceCulling.rawValue: false])
            let groundHits = results.filter {
                !isHelper($0.node) && $0.node.geometry?.elements.contains(where: { $0.primitiveType == .triangles || $0.primitiveType == .triangleStrip }) == true &&
                WalkGeometry.acceptsGround(previousY: p.y, groundY: $0.worldCoordinates.y, normalY: $0.worldNormal.y)
            }
            if let hit = groundHits.min(by: { abs($0.worldCoordinates.y - p.y) < abs($1.worldCoordinates.y - p.y) }) {
                return SIMD3(p.x, hit.worldCoordinates.y, p.z)
            }
            guard !pickablePoints.isEmpty, let index = geometryIndex else { return nil }
            let neighbours = index.neighbours(of: p, radius: 0.18, limit: 300)
                .filter { abs($0.y - p.y) <= reach }
            guard neighbours.count >= 8, let plane = GeometryMath.fitPlane(neighbours),
                  abs(plane.normal.y) >= 0.75 else { return nil }
            let y = p.y - plane.signedDistance(p) / plane.normal.y
            guard WalkGeometry.acceptsGround(previousY: p.y, groundY: y, normalY: plane.normal.y),
                  neighbours.filter({ abs(plane.signedDistance($0)) < 0.035 }).count >= neighbours.count * 4 / 5,
                  neighbours.contains(where: { simd_distance(SIMD2($0.x, $0.z), SIMD2(p.x, p.z)) < 0.07 }) else { return nil }
            return SIMD3(p.x, y, p.z)
        }

        /// Prevent walking through scanned walls and ceilings. Missing geometry
        /// is not a physical safety guarantee; this is model navigation only.
        func walkBlocked(from a: SIMD3<Float>, to b: SIMD3<Float>) -> Bool {
            for height: Float in [0.35, 0.9, 1.5] {
                let up = SIMD3<Float>(0, height, 0)
                if !segmentHits(from: a + up, to: b + up).isEmpty { return true }
            }
            if !segmentHits(from: b + SIMD3(0, 0.3, 0), to: b + SIMD3(0, 1.9, 0)).isEmpty { return true }
            if !pickablePoints.isEmpty, let index = geometryIndex {
                for height: Float in [0.4, 0.8, 1.2, 1.6] {
                    if !index.neighbours(of: b + SIMD3(0, height, 0), radius: 0.16, limit: 1).isEmpty { return true }
                }
            }
            return false
        }
    }
}
