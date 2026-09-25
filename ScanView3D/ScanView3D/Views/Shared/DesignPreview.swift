#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import simd
import SceneKit
import CoreVideo

/// CI-only visual fixtures. Never compiled into the device/TestFlight app.
/// Uses a new temporary library, never the user's Documents library.
enum DesignPreview {
    static var screen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--design-preview"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    static func store(empty: Bool) -> StorageManager {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("design-\(UUID().uuidString)")
        let store = StorageManager(directory: root)
        guard !empty else { return store }
        if let site = store.createProject(name: "Coastal path · Demo") {
            _ = try? store.saveScan(meshData: terrain(), name: "Rocky shoreline", toProject: site)
            _ = try? store.saveScan(meshData: terrain(), name: "North slope", toProject: site, format: .ply)
        }
        if let room = store.createProject(name: "Studio · Demo") {
            _ = try? store.saveScan(meshData: MockLiDARScanner.generateSampleRoomMesh(), name: "Main room", toProject: room)
        }
        return store
    }

    static func terrain() -> MeshData {
        var points: [SIMD3<Float>] = [], colors: [SIMD4<Float>] = [], faces: [[UInt32]] = []
        let count = 32
        for z in 0...count {
            for x in 0...count {
                let u = Float(x) / Float(count), v = Float(z) / Float(count)
                let y = 0.7 * sin(u * 7) * cos(v * 5) + 0.6 * u + 0.8
                points.append(SIMD3((u - 0.5) * 6, y, (v - 0.5) * 6))
                colors.append(SIMD4(0.35 + y * 0.15, 0.48 + y * 0.12, 0.42 + y * 0.08, 1))
                if z < count && x < count {
                    let a = UInt32(z * (count + 1) + x), b = a + UInt32(count + 1)
                    faces.append([a, b, a + 1]); faces.append([a + 1, b, b + 1])
                }
            }
        }
        let bounds = MeshData.bounds(of: points)
        return MeshData(vertices: points, normals: Array(repeating: SIMD3(0, 1, 0), count: points.count),
                        faces: faces, colors: colors, boundingBoxMin: bounds.0, boundingBoxMax: bounds.1)
    }

    /// Runs against the real SceneKit camera / hit tester, not just the pure
    /// maths helpers. The CI script requires this report and rejects failures.
    static func navigationChecks(view: SCNView, coordinator: SceneKitViewRepresentable.Coordinator) {
        guard screen == "navigation-tests", let rig = coordinator.cameraController,
              let camera = view.pointOfView, let lens = camera.camera else { return }
        var failures: [String] = []
        var count = 0
        func check(_ condition: Bool, _ name: String) { count += 1; if !condition { failures.append(name) } }
        let old = camera.simdTransform
        let extent: Float = 6
        rig.frame(center: .zero, extent: extent)
        for orthographic in [false, true] {
            lens.usesOrthographicProjection = orthographic
            lens.orthographicScale = 4
            let world = SIMD3<Float>(0.7, 0.3, -0.4)
            let screen = view.projectPoint(SCNVector3(world.x, world.y, world.z))
            let matrix = simd_float4x4(lens.projectionTransform(withViewportSize: view.bounds.size)) * camera.simdWorldTransform.inverse
            let picker = PointCloudPicker(points: [world, world + SIMD3(0.7, 0, 2)])
            let picked = picker.pick(at: SIMD2(screen.x, screen.y),
                viewport: SIMD2(Float(view.bounds.width), Float(view.bounds.height)), projection: matrix, radius: 2)
            check(picked == world, "SceneKit projection / pick round-trip \(orthographic ? "ortho" : "perspective")")
        }
        lens.usesOrthographicProjection = false
        let floor = SCNNode(geometry: SCNBox(width: 10, height: 0.02, length: 10, chamferRadius: 0))
        floor.position.y = -0.01
        view.scene?.rootNode.addChildNode(floor)
        check(coordinator.ground(at: .zero) != nil, "Pick horizontal ground")
        check(coordinator.ground(at: SIMD3(20, 0, 0)) == nil, "Do not invent ground outside scan")
        rig.beginWalk(at: .zero)
        rig.move(right: 0.1, forward: 0.1, elevation: 5)
        check(abs(camera.simdPosition.y - WalkGeometry.eyeHeight) < 0.001, "Walk ignores vertical elevation")
        check(simd_length(SIMD2(camera.simdPosition.x, camera.simdPosition.z)) > 0.01, "Walk moves on floor")
        let walkPosition = camera.simdPosition
        rig.look(dx: 0.4, dy: 0.2)
        check(simd_distance(camera.simdPosition, walkPosition) < 0.0001, "Look does not orbit while walking")
        rig.endWalk()
        floor.removeFromParentNode()
        camera.simdTransform = old; rig.syncFromCamera()

        do {
            let mask = PhotoRangeMask(width: 2, height: 2, pixels: Data([255, 0, 0, 255]), rangeMetres: 1)
            let buffer = try RangePhotoInput.maskBuffer(mask, width: 8, height: 8)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let row = CVPixelBufferGetBytesPerRow(buffer)
                func pixel(_ x: Int, _ y: Int) -> UInt8 { base.load(fromByteOffset: y * row + x, as: UInt8.self) }
                check(pixel(0, 0) == 255 && pixel(7, 0) == 0 && pixel(0, 7) == 0 && pixel(7, 7) == 255,
                      "Photo-mask resize preserves image orientation and hard boundary")
            } else { check(false, "Photo-mask buffer readable") }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        } catch { check(false, "Photo-mask resize: \(error)") }

        let report: [String: Any] = ["checks": count, "failures": failures]
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("navigation-checks.json")
        do { try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(to: output, options: .atomic) }
        catch { assertionFailure("Could not write navigation test report: \(error)") }
    }
}

struct DesignPreviewRoot: View {
    let screen: String
    @StateObject private var store: StorageManager
    init(screen: String) {
        self.screen = screen
        _store = StateObject(wrappedValue: DesignPreview.store(empty: screen == "empty"))
    }
    var body: some View {
        Group {
            if ["viewer", "measure", "walk", "joysticks", "navigation-tests"].contains(screen), let project = store.projects.first, let scan = project.scans.first {
                NavigationStack { ModelViewerView(scan: scan, project: project) }
            } else if screen == "project", let project = store.projects.first {
                NavigationStack { ProjectDetailView(project: project) }
            } else {
                ContentView(storageManager: store, initialTab: ["scanner", "capture-settings"].contains(screen) ? 0 : screen == "library" ? 2 : screen == "settings" ? 3 : 1)
            }
        }.environmentObject(store)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                let landscape = ProcessInfo.processInfo.arguments.contains("--landscape")
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait))
            }
        }
    }
}
#endif
