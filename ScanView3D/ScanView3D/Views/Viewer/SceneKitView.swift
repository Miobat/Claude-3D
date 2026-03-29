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
    @Binding var showWireframe: Bool
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

        // Reduce default camera control sensitivity
        sceneView.defaultCameraController.interactionMode = .orbitTurntable
        sceneView.defaultCameraController.inertiaEnabled = true
        sceneView.defaultCameraController.inertiaFriction = 0.15
        sceneView.defaultCameraController.maximumVerticalAngle = 80

        setupLighting(sceneView.scene!)
        setupCamera(sceneView)

        if showGrid {
            addGrid(to: sceneView.scene!)
        }

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        sceneView.addGestureRecognizer(tapGesture)

        context.coordinator.sceneView = sceneView

        loadModel(sceneView: sceneView, context: context)

        // Listen for camera reset
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.resetCamera),
            name: .resetCameraView,
            object: nil
        )

        // Listen for joystick input
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleJoystickMove(_:)),
            name: .joystickMove,
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleJoystickLook(_:)),
            name: .joystickLook,
            object: nil
        )

        return sceneView
    }

    func updateUIView(_ sceneView: SCNView, context: Context) {
        let gridNode = sceneView.scene?.rootNode.childNode(withName: "grid", recursively: false)
        if showGrid && gridNode == nil {
            addGrid(to: sceneView.scene!)
        } else if !showGrid {
            gridNode?.removeFromParentNode()
        }

        if let model = modelNode {
            model.enumerateChildNodes { child, _ in
                child.geometry?.firstMaterial?.fillMode = showWireframe ? .lines : .fill
            }
            model.geometry?.firstMaterial?.fillMode = showWireframe ? .lines : .fill
        }

        context.coordinator.activeTool = activeTool
        context.coordinator.measurementUnit = measurementUnit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

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
        keyLightNode.look(at: SCNVector3.init(0, 0, 0))
        scene.rootNode.addChildNode(keyLightNode)

        let fillLightNode = SCNNode()
        fillLightNode.light = SCNLight()
        fillLightNode.light!.type = .directional
        fillLightNode.light!.color = UIColor(white: 0.8, alpha: 1.0)
        fillLightNode.light!.intensity = 400
        fillLightNode.position = SCNVector3(-5, 5, -5)
        fillLightNode.look(at: SCNVector3.init(0, 0, 0))
        scene.rootNode.addChildNode(fillLightNode)

        let bottomLightNode = SCNNode()
        bottomLightNode.light = SCNLight()
        bottomLightNode.light!.type = .directional
        bottomLightNode.light!.intensity = 200
        bottomLightNode.position = SCNVector3(0, -5, 0)
        bottomLightNode.look(at: SCNVector3.init(0, 0, 0))
        scene.rootNode.addChildNode(bottomLightNode)
    }

    private func setupCamera(_ sceneView: SCNView) {
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        cameraNode.camera = SCNCamera()
        cameraNode.camera!.zNear = 0.01
        cameraNode.camera!.zFar = 1000
        cameraNode.camera!.fieldOfView = 60
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

    private func loadModel(sceneView: SCNView, context: Context) {
        let fileURL = storageManager.getScanFileURL(scan: scan, project: project)

        DispatchQueue.global(qos: .userInitiated).async {
            let node = MeshProcessor.createSceneKitNode(fromOBJ: fileURL)

            DispatchQueue.main.async {
                if let node = node {
                    sceneView.scene?.rootNode.addChildNode(node)
                    self.modelNode = node

                    let (minBound, maxBound) = node.boundingBox
                    let center = MeshProcessor.calculateCenter(min: minBound, max: maxBound)
                    let distance = MeshProcessor.calculateViewDistance(min: minBound, max: maxBound)

                    if let cameraNode = sceneView.scene?.rootNode.childNode(withName: "camera", recursively: false) {
                        cameraNode.position = SCNVector3(
                            center.x,
                            center.y + distance * 0.3,
                            center.z + distance
                        )
                        cameraNode.look(at: center)
                    }

                    context.coordinator.modelCenter = center
                    context.coordinator.viewDistance = distance
                    self.isLoading = false
                } else {
                    self.loadError = "Failed to load OBJ file"
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

        // Joystick state
        private var joystickMoveTimer: Timer?
        private var joystickLookTimer: Timer?
        private var currentMoveDX: CGFloat = 0
        private var currentMoveDY: CGFloat = 0
        private var currentLookDX: CGFloat = 0
        private var currentLookDY: CGFloat = 0

        init(parent: SceneKitViewRepresentable) {
            self.parent = parent
        }

        deinit {
            joystickMoveTimer?.invalidate()
            joystickLookTimer?.invalidate()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard activeTool == .measure, let sceneView = sceneView else { return }

            let location = gesture.location(in: sceneView)
            let hitResults = sceneView.hitTest(location, options: [
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
                .ignoreHiddenNodes: true
            ])

            guard let hit = hitResults.first else { return }
            let point = hit.worldCoordinates

            parent.measurementPoints.append(point)

            addMeasurementMarker(at: point, in: sceneView.scene!)

            if parent.measurementPoints.count >= 2 {
                let lastIndex = parent.measurementPoints.count - 1
                let p1 = parent.measurementPoints[lastIndex - 1]
                let p2 = parent.measurementPoints[lastIndex]
                let distance = p1.distance(to: p2)
                let convertedDistance = measurementUnit.convert(fromMeters: distance)
                let text = String(format: "%.3f %@", convertedDistance, measurementUnit.abbreviation)

                addMeasurementLine(from: p1, to: p2, in: sceneView.scene!)

                let midPoint = SCNVector3(
                    (p1.x + p2.x) / 2,
                    (p1.y + p2.y) / 2 + 0.05,
                    (p1.z + p2.z) / 2
                )
                parent.measurementLabels.append(MeasurementLabel(text: text, position: midPoint))
            }
        }

        @objc func resetCamera() {
            guard let sceneView = sceneView,
                  let cameraNode = sceneView.scene?.rootNode.childNode(withName: "camera", recursively: false) else { return }

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.5

            cameraNode.position = SCNVector3(
                modelCenter.x,
                modelCenter.y + viewDistance * 0.3,
                modelCenter.z + viewDistance
            )
            cameraNode.look(at: modelCenter)

            SCNTransaction.commit()
        }

        // MARK: - Joystick Handlers

        @objc func handleJoystickMove(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let dx = userInfo["dx"] as? CGFloat,
                  let dy = userInfo["dy"] as? CGFloat else { return }

            currentMoveDX = dx
            currentMoveDY = dy

            if dx == 0 && dy == 0 {
                joystickMoveTimer?.invalidate()
                joystickMoveTimer = nil
            } else if joystickMoveTimer == nil {
                joystickMoveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    self?.applyMoveInput()
                }
            }
        }

        @objc func handleJoystickLook(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let dx = userInfo["dx"] as? CGFloat,
                  let dy = userInfo["dy"] as? CGFloat else { return }

            currentLookDX = dx
            currentLookDY = dy

            if dx == 0 && dy == 0 {
                joystickLookTimer?.invalidate()
                joystickLookTimer = nil
            } else if joystickLookTimer == nil {
                joystickLookTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    self?.applyLookInput()
                }
            }
        }

        private func applyMoveInput() {
            guard let sceneView = sceneView,
                  let cameraNode = sceneView.pointOfView else { return }

            let speed: Float = viewDistance * 0.02

            // Left/Right: move along camera's local X axis (strafe)
            let right = SCNVector3(
                cameraNode.transform.m11,
                cameraNode.transform.m12,
                cameraNode.transform.m13
            )

            // Forward/Backward (up on joystick = forward into scene):
            // Use camera's local -Z axis (the direction camera looks)
            let forward = SCNVector3(
                -cameraNode.transform.m31,
                -cameraNode.transform.m32,
                -cameraNode.transform.m33
            )

            let dx = Float(currentMoveDX) * speed  // left/right strafe
            let dz = Float(-currentMoveDY) * speed  // up on stick = move forward into scene

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
            guard let sceneView = sceneView,
                  let cameraNode = sceneView.pointOfView else { return }

            let rotSpeed: Float = 0.02

            let dx = Float(currentLookDX) * rotSpeed
            let dy = Float(currentLookDY) * rotSpeed

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0

            // Rotate around Y axis (horizontal look)
            cameraNode.eulerAngles.y -= dx
            // Rotate around X axis (vertical look), clamped
            let newPitch = cameraNode.eulerAngles.x - dy
            cameraNode.eulerAngles.x = max(-.pi / 2.5, min(.pi / 2.5, newPitch))

            SCNTransaction.commit()
        }

        private func addMeasurementMarker(at position: SCNVector3, in scene: SCNScene) {
            let sphere = SCNSphere(radius: 0.01)
            sphere.firstMaterial?.diffuse.contents = UIColor.red
            sphere.firstMaterial?.emission.contents = UIColor.red.withAlphaComponent(0.5)
            let node = SCNNode(geometry: sphere)
            node.position = position
            node.name = "measurementMarker"
            scene.rootNode.addChildNode(node)
        }

        private func addMeasurementLine(from: SCNVector3, to: SCNVector3, in scene: SCNScene) {
            let vertices: [SCNVector3] = [from, to]
            let source = SCNGeometrySource(vertices: vertices)
            let indices: [Int32] = [0, 1]
            let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
            let element = SCNGeometryElement(
                data: indexData,
                primitiveType: .line,
                primitiveCount: 1,
                bytesPerIndex: MemoryLayout<Int32>.size
            )

            let geometry = SCNGeometry(sources: [source], elements: [element])
            geometry.firstMaterial?.diffuse.contents = UIColor.yellow
            geometry.firstMaterial?.emission.contents = UIColor.yellow
            geometry.firstMaterial?.isDoubleSided = true

            let lineNode = SCNNode(geometry: geometry)
            lineNode.name = "measurementLine"
            scene.rootNode.addChildNode(lineNode)
        }
    }
}
