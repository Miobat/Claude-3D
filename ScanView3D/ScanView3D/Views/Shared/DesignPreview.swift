#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import simd

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
            if ["viewer", "measure"].contains(screen), let project = store.projects.first, let scan = project.scans.first {
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
