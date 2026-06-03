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

        return sceneView
    }

    func updateUIView(_ sceneView: SCNView, context: Context) {
        // Grid
        let gridNode = sceneView.scene?.rootNode.childNode(withName: "grid", recursively: false)
        if showGrid && gridNode == nil { addGrid(to: sceneView.scene!) }
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

    private func addGrid(to scene: SCNScene) {
        let gridNode = SCNNode()
        gridNode.name = "grid"
        let gridSize: Float = 20
        let gridSpacing: Float = 0.5
        let lineCount = Int(gridSize / gridSpacing)

        for i in -lineCount...lineCount {
            let pos = Float(i) * gridSpacing
            let xGeometry = SCNCylinder(radius: 0.002, height: CGFloat(gridSize))
            xGeometry.firstMaterial?.diffuse.contents = UIColor(white: 0.3, alpha: 0.3)
            let xNode = SCNNode(geometry: xGeometry)
            xNode.position = SCNVector3(pos, 0, 0)
            xNode.eulerAngles = SCNVector3(0, 0, Float.pi / 2)
            gridNode.addChildNode(xNode)

            let zGeometry = SCNCylinder(radius: 0.002, height: CGFloat(gridSize))
            zGeometry.firstMaterial?.diffuse.contents = UIColor(white: 0.3, alpha: 0.3)
            let zNode = SCNNode(geometry: zGeometry)
            zNode.position = SCNVector3(0, 0, pos)
            zNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            gridNode.addChildNode(zNode)
        }
        scene.rootNode.addChildNode(gridNode)
    }

    private func addBoundingBox(to scene: SCNScene, for model: SCNNode) {
        let (minB, maxB) = model.boundingBox
        let size = SCNVector3(maxB.x - minB.x, maxB.y - minB.y, maxB.z - minB.z)
        let center = SCNVector3((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, (minB.z + maxB.z) / 2)

        let box = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0)
        box.firstMaterial?.diffuse.contents = UIColor.clear
        box.firstMaterial?.fillMode = .lines
        box.firstMaterial?.emission.contents = UIColor.cyan.withAlphaComponent(0.5)
        box.firstMaterial?.isDoubleSided = true

        let boxNode = SCNNode(geometry: box)
        boxNode.name = "boundingBox"
        boxNode.position = center
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
                    sceneView.scene?.rootNode.addChildNode(node)
                    self.modelNode = node

                    let (minBound, maxBound) = node.boundingBox
                    let center = MeshProcessor.calculateCenter(min: minBound, max: maxBound)
                    let distance = MeshProcessor.calculateViewDistance(min: minBound, max: maxBound)

                    if let cameraNode = sceneView.scene?.rootNode.childNode(withName: "camera", recursively: false) {
                        cameraNode.position = SCNVector3(center.x, center.y + distance * 0.3, center.z + distance)
                        cameraNode.look(at: center)
                    }

                    context.coordinator.modelCenter = center
                    context.coordinator.viewDistance = distance
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
        var viewDistance: Float = 5.0

        private var joystickMoveTimer: Timer?
        private var joystickLookTimer: Timer?
        private var currentMoveDX: CGFloat = 0
        private var currentMoveDY: CGFloat = 0
        private var currentLookDX: CGFloat = 0
        private var currentLookDY: CGFloat = 0

        init(parent: SceneKitViewRepresentable) { self.parent = parent }

        deinit {
            joystickMoveTimer?.invalidate()
            joystickLookTimer?.invalidate()
        }

        // MARK: - Camera View Presets

        @objc func handleSetCameraView(_ notification: Notification) {
            guard let sceneView = sceneView,
                  let viewStr = notification.userInfo?["view"] as? String,
                  let cameraNode = sceneView.scene?.rootNode.childNode(withName: "camera", recursively: false) else { return }

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.5

            switch viewStr {
            case "top":
                cameraNode.position = SCNVector3(modelCenter.x, modelCenter.y + viewDistance * 1.5, modelCenter.z)
                cameraNode.look(at: modelCenter)
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
                camera.orthographicScale = Double(viewDistance)
            case "FloorPlan":
                camera.usesOrthographicProjection = true
                camera.orthographicScale = Double(viewDistance * 1.2)
                cameraNode.position = SCNVector3(modelCenter.x, modelCenter.y + viewDistance * 2, modelCenter.z)
                cameraNode.look(at: modelCenter)
            default: // Perspective
                camera.usesOrthographicProjection = false
                camera.fieldOfView = 60
            }

            SCNTransaction.commit()
        }

        // MARK: - Visualization Mode

        @objc func handleSetVisualizationMode(_ notification: Notification) {
            guard let modeStr = notification.userInfo?["mode"] as? String,
                  let model = parent.modelNode else { return }

            func applyToNode(_ node: SCNNode) {
                guard let geometry = node.geometry else { return }
                for material in geometry.materials {
                    switch modeStr {
                    case "Flat":
                        material.diffuse.contents = UIColor(white: 0.85, alpha: 1.0)
                        material.fillMode = .fill
                        material.lightingModel = .physicallyBased
                    case "Normals":
                        material.diffuse.contents = UIColor.white
                        material.fillMode = .fill
                        material.lightingModel = .constant
                        // Normal visualization - use the normal data for coloring
                        material.emission.contents = UIColor(red: 0.5, green: 0.5, blue: 1.0, alpha: 1.0)
                    case "Wireframe":
                        material.fillMode = .lines
                        material.diffuse.contents = UIColor.cyan
                        material.lightingModel = .constant
                    default: // Textured
                        material.fillMode = .fill
                        material.lightingModel = .physicallyBased
                        material.emission.contents = UIColor.black
                        // Restore original colors if available
                        if material.diffuse.contents is UIColor {
                            material.diffuse.contents = UIColor.white
                        }
                    }
                    material.isDoubleSided = true
                }
            }

            applyToNode(model)
            model.enumerateChildNodes { child, _ in applyToNode(child) }
        }

        // MARK: - Tap / Measure with Snapping

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard activeTool == .measure, let sceneView = sceneView else { return }

            let location = gesture.location(in: sceneView)
            let hitResults = sceneView.hitTest(location, options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .ignoreHiddenNodes: true,
                .boundingBoxOnly: false
            ])

            // Filter: only hit the actual model geometry, not guides/markers/grid/bounding box
            let excludedNames: Set<String> = ["measurementNode", "axisGuide", "grid", "boundingBox", "camera"]
            guard let hit = hitResults.first(where: { result in
                var node: SCNNode? = result.node
                while let n = node {
                    if let name = n.name, excludedNames.contains(name) { return false }
                    node = n.parent
                }
                return true
            }) else { return }

            var point = hit.worldCoordinates

            // If we already have an odd number of points (first point placed),
            // try to snap the second point to an axis of the first point
            let pointCount = parent.measurementPoints.count
            if pointCount > 0 && pointCount % 2 == 1 {
                let firstPoint = parent.measurementPoints[pointCount - 1]
                point = snapToAxis(point, relativeTo: firstPoint, threshold: 0.08)
            }

            parent.measurementPoints.append(point)
            addMeasurementMarker(at: point, in: sceneView.scene!)

            // Show axis guides from this point if it's a first point (odd index after adding)
            if parent.measurementPoints.count % 2 == 1 {
                showAxisGuides(at: point, in: sceneView.scene!)
            } else {
                // Second point placed - remove guides and create measurement
                removeAxisGuides(from: sceneView.scene!)
            }

            if parent.measurementPoints.count >= 2 && parent.measurementPoints.count % 2 == 0 {
                let lastIndex = parent.measurementPoints.count - 1
                let p1 = parent.measurementPoints[lastIndex - 1]
                let p2 = parent.measurementPoints[lastIndex]
                let distance = p1.distance(to: p2)
                let convertedDistance = measurementUnit.convert(fromMeters: distance)
                let text = String(format: "%.3f %@", convertedDistance, measurementUnit.abbreviation)
                addMeasurementLine(from: p1, to: p2, label: text, in: sceneView.scene!)
                parent.measurementLabels.append(MeasurementLabel(text: text, position: SCNVector3.init(0, 0, 0)))
            }
        }

        /// Snap a point to the nearest axis of a reference point
        private func snapToAxis(_ point: SCNVector3, relativeTo ref: SCNVector3, threshold: Float) -> SCNVector3 {
            var snapped = point
            let dx = abs(point.x - ref.x)
            let dy = abs(point.y - ref.y)
            let dz = abs(point.z - ref.z)

            // Find which axis the point is most aligned with
            // If close to vertical (small dx and dz), snap to pure Y
            if dx < threshold && dz < threshold {
                snapped.x = ref.x
                snapped.z = ref.z
            }
            // If close to horizontal-X (small dy), snap Y
            else if dy < threshold {
                snapped.y = ref.y
            }
            // Snap individual axes if very close
            else {
                if dx < threshold * 0.5 { snapped.x = ref.x }
                if dy < threshold * 0.5 { snapped.y = ref.y }
                if dz < threshold * 0.5 { snapped.z = ref.z }
            }

            return snapped
        }

        /// Show dashed axis guide lines from a measurement point
        private func showAxisGuides(at point: SCNVector3, in scene: SCNScene) {
            let guideLength: Float = viewDistance * 1.5

            // Vertical guide (Y axis) - green dashed line
            addGuide(from: SCNVector3(point.x, point.y - guideLength, point.z),
                     to: SCNVector3(point.x, point.y + guideLength, point.z),
                     color: UIColor.green, name: "axisGuide", in: scene)

            // Horizontal X guide - red
            addGuide(from: SCNVector3(point.x - guideLength, point.y, point.z),
                     to: SCNVector3(point.x + guideLength, point.y, point.z),
                     color: UIColor.red.withAlphaComponent(0.4), name: "axisGuide", in: scene)

            // Horizontal Z guide - blue
            addGuide(from: SCNVector3(point.x, point.y, point.z - guideLength),
                     to: SCNVector3(point.x, point.y, point.z + guideLength),
                     color: UIColor.blue.withAlphaComponent(0.4), name: "axisGuide", in: scene)
        }

        private func addGuide(from: SCNVector3, to: SCNVector3, color: UIColor, name: String, in scene: SCNScene) {
            let vertices: [SCNVector3] = [from, to]
            let source = SCNGeometrySource(vertices: vertices)
            let indices: [Int32] = [0, 1]
            let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
            let element = SCNGeometryElement(data: indexData, primitiveType: .line, primitiveCount: 1, bytesPerIndex: MemoryLayout<Int32>.size)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            geometry.firstMaterial?.diffuse.contents = color
            geometry.firstMaterial?.emission.contents = color
            geometry.firstMaterial?.isDoubleSided = true
            let node = SCNNode(geometry: geometry)
            node.name = name
            scene.rootNode.addChildNode(node)
        }

        private func removeAxisGuides(from scene: SCNScene) {
            scene.rootNode.enumerateChildNodes { node, _ in
                if node.name == "axisGuide" {
                    node.removeFromParentNode()
                }
            }
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
            let sphere = SCNSphere(radius: 0.015)
            sphere.firstMaterial?.diffuse.contents = UIColor.systemCyan
            sphere.firstMaterial?.emission.contents = UIColor.systemCyan
            let node = SCNNode(geometry: sphere)
            node.position = position
            node.name = "measurementNode"
            scene.rootNode.addChildNode(node)
        }

        private func addMeasurementLine(from: SCNVector3, to: SCNVector3, label: String, in scene: SCNScene) {
            // Line
            let vertices: [SCNVector3] = [from, to]
            let source = SCNGeometrySource(vertices: vertices)
            let indices: [Int32] = [0, 1]
            let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
            let element = SCNGeometryElement(data: indexData, primitiveType: .line, primitiveCount: 1, bytesPerIndex: MemoryLayout<Int32>.size)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            geometry.firstMaterial?.diffuse.contents = UIColor.systemCyan
            geometry.firstMaterial?.emission.contents = UIColor.systemCyan
            geometry.firstMaterial?.isDoubleSided = true
            let lineNode = SCNNode(geometry: geometry)
            lineNode.name = "measurementNode"
            scene.rootNode.addChildNode(lineNode)

            // 3D text label at midpoint
            let midPoint = SCNVector3(
                (from.x + to.x) / 2,
                (from.y + to.y) / 2 + 0.03,
                (from.z + to.z) / 2
            )

            let text = SCNText(string: label, extrusionDepth: 0.002)
            text.font = UIFont.systemFont(ofSize: 0.04, weight: .bold)
            text.flatness = 0.1
            text.firstMaterial?.diffuse.contents = UIColor.white
            text.firstMaterial?.emission.contents = UIColor.white
            text.firstMaterial?.isDoubleSided = true

            let textNode = SCNNode(geometry: text)
            textNode.name = "measurementNode"

            // Center the text
            let (textMin, textMax) = textNode.boundingBox
            let textWidth = textMax.x - textMin.x
            textNode.pivot = SCNMatrix4MakeTranslation(textWidth / 2, 0, 0)
            textNode.position = midPoint

            // Billboard constraint - text always faces camera
            let billboard = SCNBillboardConstraint()
            billboard.freeAxes = .all
            textNode.constraints = [billboard]

            scene.rootNode.addChildNode(textNode)
        }

        func clearAllMeasurements(in scene: SCNScene) {
            scene.rootNode.enumerateChildNodes { node, _ in
                if node.name == "measurementNode" || node.name == "axisGuide" {
                    node.removeFromParentNode()
                }
            }
        }
    }
}
