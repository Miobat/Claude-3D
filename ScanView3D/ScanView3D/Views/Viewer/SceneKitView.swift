import SwiftUI
import SceneKit

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
    @Binding var measurementPoints: [SCNVector3]
    @Binding var measurementLabels: [MeasurementLabel]
    @Binding var measurementUnit: ScanSettings.MeasurementUnit

    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView(frame: .zero)
        sceneView.scene = SCNScene()
        sceneView.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)
        sceneView.autoenablesDefaultLighting = false
        sceneView.allowsCameraControl = true
        sceneView.antialiasingMode = .multisampling4X

        sceneView.defaultCameraController.interactionMode = .orbitTurntable
        sceneView.defaultCameraController.inertiaEnabled = true
        sceneView.defaultCameraController.inertiaFriction = 0.15
        sceneView.defaultCameraController.maximumVerticalAngle = 80

        setupLighting(sceneView.scene!)
        setupCamera(sceneView)

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        sceneView.addGestureRecognizer(tapGesture)

        context.coordinator.sceneView = sceneView
        loadModel(sceneView: sceneView, context: context)

        // Register for all notifications
        let nc = NotificationCenter.default
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.resetCamera), name: .resetCameraView, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.handleJoystickMove(_:)), name: .joystickMove, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.handleJoystickLook(_:)), name: .joystickLook, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.handleSetCameraView(_:)), name: .setCameraView, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.handleSetCameraProjection(_:)), name: .setCameraProjection, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.handleSetVisualizationMode(_:)), name: .setVisualizationMode, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.handleClearMeasurements), name: .clearMeasurements, object: nil)
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
        context.coordinator.measurementUnit = measurementUnit
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

    /// World-space bounds of the model node (it sits at the origin, possibly scaled).
    static func worldBounds(of node: SCNNode) -> (SIMD3<Float>, SIMD3<Float>) {
        let (mn, mx) = node.boundingBox
        let s = node.simdScale
        let a = SIMD3<Float>(Float(mn.x), Float(mn.y), Float(mn.z)) * s
        let b = SIMD3<Float>(Float(mx.x), Float(mx.y), Float(mx.z)) * s
        return (simd_min(a, b), simd_max(a, b))
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
                    if let s = scan.modelScale, s > 0, abs(s - 1.0) > 0.0001 {
                        node.simdScale = SIMD3<Float>(repeating: s)
                    }
                    sceneView.scene?.rootNode.addChildNode(node)
                    self.modelNode = node

                    let (minB, maxB) = SceneKitViewRepresentable.worldBounds(of: node)
                    let centerV = (minB + maxB) / 2
                    let center = SCNVector3(centerV.x, centerV.y, centerV.z)
                    let extent = maxB - minB
                    let distance = max(max(extent.x, max(extent.y, extent.z)) * 2.0, 0.1)

                    if let cameraNode = sceneView.scene?.rootNode.childNode(withName: "camera", recursively: false) {
                        cameraNode.position = SCNVector3(center.x, center.y + distance * 0.3, center.z + distance)
                        cameraNode.look(at: center)
                    }

                    context.coordinator.modelCenter = center
                    context.coordinator.modelExtent = extent
                    context.coordinator.viewDistance = distance
                    context.coordinator.collectPickablePoints(from: node)
                    self.isLoading = false
                } else {
                    self.loadError = "Failed to load model file"
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject {
        var parent: SceneKitViewRepresentable
        var sceneView: SCNView?
        var activeTool: ModelViewerView.ViewerTool = .orbit
        var measurementUnit: ScanSettings.MeasurementUnit = .meters
        var modelCenter: SCNVector3 = SCNVector3(0, 0, 0)
        var modelExtent = SIMD3<Float>(1, 1, 1)
        var viewDistance: Float = 5.0

        /// World positions of point-cloud points (SceneKit can't hit-test points).
        private var pickablePoints: [SIMD3<Float>] = []
        /// Original material look, so "Textured" can restore it after Flat/Wireframe.
        private var originalMaterials: [ObjectIdentifier: (diffuse: Any?, emission: Any?, lighting: SCNMaterial.LightingModel, fill: SCNFillMode)] = [:]

        private var joystickMoveTimer: Timer?
        private var joystickLookTimer: Timer?
        private var currentMoveDX: CGFloat = 0
        private var currentMoveDY: CGFloat = 0
        private var currentLookDX: CGFloat = 0
        private var currentLookDY: CGFloat = 0

        /// How close (on screen, in points) a tap must be to snap.
        private let snapDistance: CGFloat = 24

        init(parent: SceneKitViewRepresentable) { self.parent = parent }

        deinit {
            joystickMoveTimer?.invalidate()
            joystickLookTimer?.invalidate()
        }

        /// Marker/label sizes follow the model size so they stay readable on a
        /// shoe box and on a whole garden.
        private var markerRadius: CGFloat { CGFloat(max(0.003, viewDistance * 0.0025)) }
        private var labelSize: CGFloat { CGFloat(max(0.01, viewDistance * 0.012)) }

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
        }

        /// Front-most point-cloud point near a screen location.
        private func pickPoint(at location: CGPoint, in view: SCNView) -> SCNVector3? {
            guard !pickablePoints.isEmpty else { return nil }
            let step = max(1, pickablePoints.count / 400_000)
            var best: SCNVector3?
            var bestDepth: Float = .greatestFiniteMagnitude
            let maxDist = Float(snapDistance)
            var i = 0
            while i < pickablePoints.count {
                let p = pickablePoints[i]
                let s = view.projectPoint(SCNVector3(p.x, p.y, p.z))
                if s.z > 0, s.z < 1,
                   abs(s.x - Float(location.x)) < maxDist, abs(s.y - Float(location.y)) < maxDist,
                   hypotf(s.x - Float(location.x), s.y - Float(location.y)) < maxDist,
                   s.z < bestDepth {
                    bestDepth = s.z
                    best = SCNVector3(p.x, p.y, p.z)
                }
                i += step
            }
            return best
        }

        // MARK: - Camera View Presets

        private func topDownOrientation(_ cameraNode: SCNNode) {
            // Looking straight down: "up" on screen must not be the world up axis.
            cameraNode.look(at: modelCenter, up: SCNVector3(0, 0, -1), localFront: SCNVector3(0, 0, -1))
        }

        @objc func handleSetCameraView(_ notification: Notification) {
            guard let sceneView = sceneView,
                  let viewStr = notification.userInfo?["view"] as? String,
                  let cameraNode = sceneView.scene?.rootNode.childNode(withName: "camera", recursively: false) else { return }

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.5
            switch viewStr {
            case "top":
                cameraNode.position = SCNVector3(modelCenter.x, modelCenter.y + viewDistance * 1.5, modelCenter.z)
                topDownOrientation(cameraNode)
            case "front":
                cameraNode.position = SCNVector3(modelCenter.x, modelCenter.y, modelCenter.z + viewDistance)
                cameraNode.look(at: modelCenter)
            case "side":
                cameraNode.position = SCNVector3(modelCenter.x + viewDistance, modelCenter.y, modelCenter.z)
                cameraNode.look(at: modelCenter)
            default: break
            }
            SCNTransaction.commit()
        }

        // MARK: - Camera Projection

        /// Orthographic scale that fits the model's footprint in the view.
        private func fittingOrthoScale(for view: SCNView) -> Double {
            let aspect = max(0.1, Float(view.bounds.width / max(view.bounds.height, 1)))
            let halfHeight = max(modelExtent.z / 2, modelExtent.x / 2 / aspect)
            return Double(max(halfHeight * 1.1, 0.05))
        }

        @objc func handleSetCameraProjection(_ notification: Notification) {
            guard let sceneView = sceneView,
                  let projStr = notification.userInfo?["projection"] as? String,
                  let cameraNode = sceneView.scene?.rootNode.childNode(withName: "camera", recursively: false),
                  let camera = cameraNode.camera else { return }

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.5
            switch projStr {
            case "Ortho":
                camera.usesOrthographicProjection = true
                camera.orthographicScale = Double(viewDistance) * 0.5
            case "FloorPlan":
                camera.usesOrthographicProjection = true
                camera.orthographicScale = fittingOrthoScale(for: sceneView)
                cameraNode.position = SCNVector3(modelCenter.x, modelCenter.y + viewDistance * 2, modelCenter.z)
                topDownOrientation(cameraNode)
            default: // Perspective
                camera.usesOrthographicProjection = false
                camera.fieldOfView = 60
            }
            SCNTransaction.commit()
        }

        /// Top-down orthographic snapshot, shared as an image.
        @objc func handleCaptureTopDown() {
            guard let sceneView = sceneView,
                  let cameraNode = sceneView.scene?.rootNode.childNode(withName: "camera", recursively: false),
                  let camera = cameraNode.camera else { return }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            camera.usesOrthographicProjection = true
            camera.orthographicScale = fittingOrthoScale(for: sceneView)
            cameraNode.position = SCNVector3(modelCenter.x, modelCenter.y + viewDistance * 2, modelCenter.z)
            topDownOrientation(cameraNode)
            SCNTransaction.commit()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak sceneView] in
                guard let view = sceneView else { return }
                ShareSheetPresenter.present([view.snapshot()])
            }
        }

        // MARK: - Visualization Mode

        @objc func handleSetVisualizationMode(_ notification: Notification) {
            guard let modeStr = notification.userInfo?["mode"] as? String,
                  let model = parent.modelNode else { return }

            func apply(to node: SCNNode) {
                for material in node.geometry?.materials ?? [] {
                    let id = ObjectIdentifier(material)
                    if originalMaterials[id] == nil {
                        originalMaterials[id] = (material.diffuse.contents, material.emission.contents,
                                                 material.lightingModel, material.fillMode)
                    }
                    switch modeStr {
                    case "Flat":
                        material.diffuse.contents = UIColor(white: 0.85, alpha: 1.0)
                        material.emission.contents = UIColor.black
                        material.fillMode = .fill
                        material.lightingModel = .physicallyBased
                    case "Wireframe":
                        material.fillMode = .lines
                        material.diffuse.contents = UIColor.cyan
                        material.lightingModel = .constant
                    default: // Textured: restore exactly what the file had
                        if let original = originalMaterials[id] {
                            material.diffuse.contents = original.diffuse
                            material.emission.contents = original.emission
                            material.lightingModel = original.lighting
                            material.fillMode = original.fill
                        }
                    }
                    material.isDoubleSided = true
                }
            }
            apply(to: model)
            model.enumerateChildNodes { child, _ in apply(to: child) }
        }

        // MARK: - Tap / Measure

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard activeTool == .measure, let sceneView = sceneView, let scene = sceneView.scene else { return }
            let location = gesture.location(in: sceneView)

            guard var point = surfacePoint(at: location, in: sceneView) else { return }

            let pointCount = parent.measurementPoints.count
            var snap: SnapKind = .none
            if pointCount % 2 == 1 {
                let first = parent.measurementPoints[pointCount - 1]
                (point, snap) = snapped(point, to: first, in: sceneView)
            }

            parent.measurementPoints.append(point)
            addMeasurementMarker(at: point, in: scene)

            if parent.measurementPoints.count % 2 == 1 {
                showVerticalGuide(at: point, in: scene)
                return
            }

            removeAxisGuides(from: scene)
            let p1 = parent.measurementPoints[parent.measurementPoints.count - 2]
            let p2 = point
            let text = measurementText(from: p1, to: p2, snap: snap)
            addMeasurementLine(from: p1, to: p2, label: text, in: scene)
            parent.measurementLabels.append(MeasurementLabel(text: text, position: SCNVector3(0, 0, 0)))
        }

        /// The model surface under a screen location (mesh hit, or nearest point
        /// for point clouds). Ignores helper geometry like markers and the grid.
        private func surfacePoint(at location: CGPoint, in view: SCNView) -> SCNVector3? {
            let hits = view.hitTest(location, options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .ignoreHiddenNodes: true
            ])
            let excluded: Set<String> = ["measurementNode", "axisGuide", "grid", "boundingBox", "camera"]
            let hit = hits.first { result in
                var node: SCNNode? = result.node
                while let n = node {
                    if let name = n.name, excluded.contains(name) { return false }
                    node = n.parent
                }
                return true
            }
            if let hit = hit { return hit.worldCoordinates }
            return pickPoint(at: location, in: view)
        }

        enum SnapKind { case none, vertical, level }

        /// Snap the second point so the measurement is exactly vertical (straight
        /// above/below the first point) or exactly level (same height), when the
        /// tap is within a finger's width of that on screen. Screen-based, so it
        /// behaves the same for a small object and a whole building.
        private func snapped(_ p: SCNVector3, to ref: SCNVector3, in view: SCNView) -> (SCNVector3, SnapKind) {
            let tap = view.projectPoint(p)
            func screenDistance(_ q: SCNVector3) -> CGFloat {
                let s = view.projectPoint(q)
                return CGFloat(hypotf(s.x - tap.x, s.y - tap.y))
            }
            let vertical = SCNVector3(ref.x, p.y, ref.z)
            let level = SCNVector3(p.x, ref.y, p.z)
            let dv = screenDistance(vertical)
            let dl = screenDistance(level)
            // Don't call a nearly-flat measurement "vertical" or vice versa.
            let dy = abs(p.y - ref.y)
            let dh = hypotf(p.x - ref.x, p.z - ref.z)
            if dv <= snapDistance && dv <= dl && dy > dh { return (vertical, .vertical) }
            if dl <= snapDistance && dh >= dy { return (level, .level) }
            return (p, .none)
        }

        private func measurementText(from p1: SCNVector3, to p2: SCNVector3, snap: SnapKind) -> String {
            let dx = p2.x - p1.x, dy = p2.y - p1.y, dz = p2.z - p1.z
            let total = sqrtf(dx * dx + dy * dy + dz * dz)
            let unit = measurementUnit
            switch snap {
            case .vertical:
                return "↕ \(unit.format(meters: abs(dy)))"
            case .level:
                return "↔ \(unit.format(meters: total))"
            case .none:
                // Show the height difference too — useful on slopes and terrain.
                if abs(dy) >= 0.01 {
                    return "\(unit.format(meters: total))  ↕ \(unit.format(meters: abs(dy)))"
                }
                return unit.format(meters: total)
            }
        }

        /// Dashed-style vertical guide through the first point (true vertical).
        private func showVerticalGuide(at point: SCNVector3, in scene: SCNScene) {
            removeAxisGuides(from: scene)
            let length = max(viewDistance, modelExtent.y * 2)
            let top = SCNVector3(point.x, point.y + length, point.z)
            let bottom = SCNVector3(point.x, point.y - length, point.z)
            let node = cylinder(from: bottom, to: top, radius: markerRadius * 0.25,
                                color: UIColor.systemGreen.withAlphaComponent(0.6))
            node.name = "axisGuide"
            scene.rootNode.addChildNode(node)
        }

        private func removeAxisGuides(from scene: SCNScene) {
            scene.rootNode.childNodes.filter { $0.name == "axisGuide" }.forEach { $0.removeFromParentNode() }
        }

        @objc func handleClearMeasurements() {
            guard let sceneView = sceneView, let scene = sceneView.scene else { return }
            clearAllMeasurements(in: scene)
        }

        @objc func resetCamera() {
            guard let sceneView = sceneView,
                  let cameraNode = sceneView.scene?.rootNode.childNode(withName: "camera", recursively: false) else { return }

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.5
            cameraNode.camera?.usesOrthographicProjection = false
            cameraNode.camera?.fieldOfView = 60
            cameraNode.position = SCNVector3(modelCenter.x, modelCenter.y + viewDistance * 0.3, modelCenter.z + viewDistance)
            cameraNode.look(at: modelCenter)
            SCNTransaction.commit()
        }

        // MARK: - Joystick Handlers

        @objc func handleJoystickMove(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let dx = userInfo["dx"] as? CGFloat,
                  let dy = userInfo["dy"] as? CGFloat else { return }
            currentMoveDX = dx; currentMoveDY = dy
            if dx == 0 && dy == 0 {
                joystickMoveTimer?.invalidate(); joystickMoveTimer = nil
            } else if joystickMoveTimer == nil {
                joystickMoveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.applyMoveInput() }
            }
        }

        @objc func handleJoystickLook(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let dx = userInfo["dx"] as? CGFloat,
                  let dy = userInfo["dy"] as? CGFloat else { return }
            currentLookDX = dx; currentLookDY = dy
            if dx == 0 && dy == 0 {
                joystickLookTimer?.invalidate(); joystickLookTimer = nil
            } else if joystickLookTimer == nil {
                joystickLookTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.applyLookInput() }
            }
        }

        private func applyMoveInput() {
            guard let cameraNode = sceneView?.pointOfView else { return }
            let speed: Float = viewDistance * 0.02
            let right = SCNVector3(cameraNode.transform.m11, cameraNode.transform.m12, cameraNode.transform.m13)
            let forward = SCNVector3(-cameraNode.transform.m31, -cameraNode.transform.m32, -cameraNode.transform.m33)
            let dx = Float(currentMoveDX) * speed
            let dz = Float(-currentMoveDY) * speed

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            cameraNode.position = SCNVector3(
                cameraNode.position.x + right.x * dx + forward.x * dz,
                cameraNode.position.y + right.y * dx + forward.y * dz,
                cameraNode.position.z + right.z * dx + forward.z * dz
            )
            SCNTransaction.commit()
        }

        private func applyLookInput() {
            guard let cameraNode = sceneView?.pointOfView else { return }
            let rotSpeed: Float = 0.02

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            cameraNode.eulerAngles.y -= Float(currentLookDX) * rotSpeed
            let newPitch = cameraNode.eulerAngles.x - Float(currentLookDY) * rotSpeed
            cameraNode.eulerAngles.x = max(-.pi / 2.5, min(.pi / 2.5, newPitch))
            SCNTransaction.commit()
        }

        // MARK: - Measurement Helpers

        private func addMeasurementMarker(at position: SCNVector3, in scene: SCNScene) {
            let sphere = SCNSphere(radius: markerRadius)
            sphere.firstMaterial?.diffuse.contents = UIColor.systemYellow
            sphere.firstMaterial?.emission.contents = UIColor.systemYellow
            sphere.firstMaterial?.readsFromDepthBuffer = false   // always visible
            let node = SCNNode(geometry: sphere)
            node.position = position
            node.name = "measurementNode"
            node.renderingOrder = 100
            scene.rootNode.addChildNode(node)
        }

        /// A cylinder between two points (thicker and easier to see than a 1px line).
        private func cylinder(from a: SCNVector3, to b: SCNVector3, radius: CGFloat, color: UIColor) -> SCNNode {
            let pa = SIMD3<Float>(a.x, a.y, a.z), pb = SIMD3<Float>(b.x, b.y, b.z)
            let vector = pb - pa
            let length = simd_length(vector)
            let geometry = SCNCylinder(radius: radius, height: CGFloat(max(length, 0.0001)))
            geometry.firstMaterial?.diffuse.contents = color
            geometry.firstMaterial?.emission.contents = color
            geometry.firstMaterial?.lightingModel = .constant
            let node = SCNNode(geometry: geometry)
            node.simdPosition = (pa + pb) / 2
            if length > 1e-6 {
                let dir = vector / length
                let up = SIMD3<Float>(0, 1, 0)
                if simd_dot(dir, up) < -0.9999 {
                    node.simdOrientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
                } else {
                    node.simdOrientation = simd_quatf(from: up, to: dir)
                }
            }
            return node
        }

        private func addMeasurementLine(from: SCNVector3, to: SCNVector3, label: String, in scene: SCNScene) {
            let line = cylinder(from: from, to: to, radius: markerRadius * 0.35, color: UIColor.systemYellow)
            line.name = "measurementNode"
            line.renderingOrder = 99
            line.geometry?.firstMaterial?.readsFromDepthBuffer = false
            scene.rootNode.addChildNode(line)

            // Billboard label above the midpoint
            let text = SCNText(string: label, extrusionDepth: 0)
            text.font = UIFont.systemFont(ofSize: labelSize, weight: .bold)
            text.flatness = 0.05
            text.firstMaterial?.diffuse.contents = UIColor.white
            text.firstMaterial?.emission.contents = UIColor.white
            text.firstMaterial?.isDoubleSided = true
            text.firstMaterial?.readsFromDepthBuffer = false

            let textNode = SCNNode(geometry: text)
            textNode.name = "measurementNode"
            textNode.renderingOrder = 101
            let (textMin, textMax) = textNode.boundingBox
            textNode.pivot = SCNMatrix4MakeTranslation((textMax.x + textMin.x) / 2, textMin.y, 0)
            textNode.position = SCNVector3((from.x + to.x) / 2,
                                           (from.y + to.y) / 2 + Float(markerRadius) * 2,
                                           (from.z + to.z) / 2)
            let billboard = SCNBillboardConstraint()
            billboard.freeAxes = .all
            textNode.constraints = [billboard]
            scene.rootNode.addChildNode(textNode)
        }

        func clearAllMeasurements(in scene: SCNScene) {
            scene.rootNode.childNodes
                .filter { $0.name == "measurementNode" || $0.name == "axisGuide" }
                .forEach { $0.removeFromParentNode() }
        }
    }
}
