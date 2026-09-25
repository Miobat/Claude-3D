#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import simd
import SceneKit
import CoreVideo
import Metal
import ImageIO

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
            SCNTransaction.flush()
            _ = view.snapshot()
            let world = SIMD3<Float>(0.7, 0.3, -0.4)
            let screen = view.projectPoint(SCNVector3(world.x, world.y, world.z))
            guard let matrix = coordinator.pickingProjection(in: view) else { check(false, "Picking projection exists"); continue }
            let picker = PointCloudPicker(points: [world, world + SIMD3(0.7, 0, 2)])
            let picked = picker.pick(at: SIMD2(screen.x, screen.y),
                viewport: SIMD2(Float(view.bounds.width), Float(view.bounds.height)), projection: matrix, radius: 2)
            check(picked == world, "SceneKit projection / pick round-trip \(orthographic ? "ortho" : "perspective")")
        }
        lens.usesOrthographicProjection = false
        // Isolate the walking floor from the terrain fixture. A floor UNDER the
        // terrain rightly fails the walker's head-clearance / obstacle checks.
        let start = SIMD3<Float>(20, 0, 0)
        let floor = SCNNode(geometry: SCNBox(width: 10, height: 0.02, length: 10, chamferRadius: 0))
        floor.simdPosition = start + SIMD3(0, -0.01, 0)
        view.scene?.rootNode.addChildNode(floor)
        SCNTransaction.flush()
        _ = view.snapshot()
        check(coordinator.ground(at: start) != nil, "Pick horizontal ground")
        check(coordinator.ground(at: SIMD3(40, 0, 0)) == nil, "Do not invent ground outside scan")
        rig.beginWalk(at: start)
        rig.move(right: 0.1, forward: 0.1, elevation: 5)
        check(abs(camera.simdPosition.y - WalkGeometry.eyeHeight) < 0.001, "Walk ignores vertical elevation")
        check(simd_length(SIMD2(camera.simdPosition.x - start.x, camera.simdPosition.z - start.z)) > 0.01, "Walk moves on floor")
        let wall = SCNNode(geometry: SCNBox(width: 0.3, height: 2, length: 0.3, chamferRadius: 0))
        wall.simdPosition = start + SIMD3(0, 1, -0.6)
        view.scene?.rootNode.addChildNode(wall)
        SCNTransaction.flush()
        _ = view.snapshot()
        let beforeWall = camera.simdPosition
        rig.move(right: 0, forward: 1, elevation: 0)
        check(camera.simdPosition.z > -0.46 && camera.simdPosition.z < beforeWall.z, "Walk advances then stops before a scanned wall")
        wall.removeFromParentNode()
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
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pose-check-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let maskURL = directory.appendingPathComponent("mask.png")
            try RangePhotoInput.writeMask(mask, width: 8, height: 8, to: maskURL)
            if let source = CGImageSourceCreateWithURL(maskURL as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
               let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
                check(image.width == 8 && image.height == 8 && image.bitsPerPixel == 8 &&
                      image.colorSpace?.model == .monochrome, "Exported range PNG is full-resolution single-channel grayscale")
                let stride = image.bytesPerRow
                check(bytes[0] == 255 && bytes[7] == 0 && bytes[7 * stride] == 0 && bytes[7 * stride + 7] == 255 &&
                      (0..<8).allSatisfy { y in (0..<8).allSatisfy { x in bytes[y * stride + x] == 0 || bytes[y * stride + x] == 255 } },
                      "Exported range PNG preserves binary values and orientation")
            } else { check(false, "Exported range PNG can be decoded") }
            let folder = directory.appendingPathComponent("photos")
            try PoseFile.write([], forPhotoFolder: folder, requireRangeMasks: true)
            check(try PoseFile.requiresRangeMasks(forPhotoFolder: folder), "Empty capture still requires masks")
            let pose = CapturedPose(index: 7, transform: matrix_identity_float4x4,
                intrinsics: matrix_identity_float3x3, width: 8, height: 8, rangeMask: mask)
            try PoseFile.write([pose], forPhotoFolder: folder)
            let restored = try PoseFile.read(forPhotoFolder: folder)
            check(restored.count == 1 && restored[0].rangeMask == mask, "Pose / range mask recovery round-trip")
            check(PoseFile.cameraPositions(forPhotoFolder: folder)[7] == .zero, "Masked pose alignment retains photo IDs")
            do {
                let unmasked = CapturedPose(index: 8, transform: matrix_identity_float4x4,
                    intrinsics: matrix_identity_float3x3, width: 8, height: 8)
                try PoseFile.write([unmasked], forPhotoFolder: folder)
                check(false, "Cannot downgrade masked capture after a missing mask")
            } catch { check(true, "Cannot downgrade masked capture after a missing mask") }
            try FileManager.default.removeItem(at: directory)
        } catch { check(false, "Photo-mask resize: \(error)") }

        checkFeedbackShader(check)
        let report: [String: Any] = ["checks": count, "failures": failures]
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("navigation-checks.json")
        do { try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(to: output, options: .atomic) }
        catch { assertionFailure("Could not write navigation test report: \(error)") }
    }

    private static func checkFeedbackShader(_ check: (Bool, String) -> Void) {
        guard let device = MTLCreateSystemDefaultDevice(), let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "captureFeedback"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer() else {
            check(false, "Capture feedback shader available"); return
        }
        struct Uniforms {
            var cameraToWorld = matrix_identity_float4x4
            var worldToAcceptedCamera = matrix_identity_float4x4
            var displayToImage = matrix_identity_float3x3
            var intrinsics = SIMD4<Float>(100, 100, 8, 8)
            var acceptedIntrinsics = SIMD4<Float>(6.25, 6.25, 0.5, 0.5)
            var parameters = SIMD4<Float>(1.5, 1, 16, 16)
        }
        func texture(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 16, height: 16, mipmapped: false)
            d.storageMode = .shared; d.usage = [.shaderRead, .shaderWrite]
            return device.makeTexture(descriptor: d)
        }
        // Float32 colour filtering isn't supported on every Metal GPU. Use a
        // universally filterable input, as the real AR camera compositor does.
        guard let source = texture(.rgba8Unorm), let output = texture(.rgba32Float),
              let depth = texture(.r32Float), let accepted = texture(.r32Float) else {
            check(false, "Capture feedback test textures"); return
        }
        let colors = [SIMD4<Float>](repeating: SIMD4(26.0 / 255, 0.2, 0.8, 1), count: 256)
        let colorBytes = (0..<256).flatMap { _ in [UInt8(26), 51, 204, 255] }
        let depths: [Float] = (0..<256).map { i in i % 16 < 4 ? 1 : i % 16 < 8 ? 2 : i % 16 < 12 ? 0 : 1 }
        let committed: [Float] = (0..<256).map { $0 % 16 < 8 ? 1 : 0 }
        colorBytes.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64) }
        depths.withUnsafeBytes { depth.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64) }
        committed.withUnsafeBytes { accepted.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64) }
        guard let encoder = command.makeComputeCommandEncoder() else { check(false, "Capture feedback command"); return }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0); encoder.setTexture(output, index: 1)
        encoder.setTexture(depth, index: 2); encoder.setTexture(accepted, index: 3)
        var uniforms = Uniforms()
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: 16, height: 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        check(command.status == .completed, "Capture feedback GPU command")
        var result = [SIMD4<Float>](repeating: .zero, count: 256)
        result.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 256, from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0) }
        // Compare against the SAME GPU sampler's no-effect output. UNorm texture
        // filtering precision differs from a CPU float conversion across GPUs.
        guard let baseline = texture(.rgba32Float), let referenceCommand = queue.makeCommandBuffer(),
              let referenceEncoder = referenceCommand.makeComputeCommandEncoder() else {
            check(false, "Capture feedback reference command"); return
        }
        uniforms.parameters.x = -1
        referenceEncoder.setComputePipelineState(pipeline)
        referenceEncoder.setTexture(source, index: 0); referenceEncoder.setTexture(baseline, index: 1)
        referenceEncoder.setTexture(depth, index: 2); referenceEncoder.setTexture(accepted, index: 3)
        referenceEncoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        referenceEncoder.dispatchThreads(MTLSize(width: 16, height: 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        referenceEncoder.endEncoding(); referenceCommand.commit(); referenceCommand.waitUntilCompleted()
        check(referenceCommand.status == .completed, "Capture feedback reference GPU command")
        var reference = [SIMD4<Float>](repeating: .zero, count: 256)
        reference.withUnsafeMutableBytes { baseline.getBytes($0.baseAddress!, bytesPerRow: 256, from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0) }
        func unchanged(_ i: Int) -> Bool {
            simd_distance(SIMD3(result[i].x, result[i].y, result[i].z), SIMD3(reference[i].x, reference[i].y, reference[i].z)) < 0.00001
        }
        check(result[8 * 16 + 1].y > 0.45, "Committed in-range surface gets visible mint coverage")
        check(result[8 * 16 + 5].y < 0.4 && result[8 * 16 + 5].z < 0.7, "Out-of-range surface is muted without mint coverage")
        check(unchanged(8 * 16 + 9), "Unknown depth does not invent coverage: actual \(result[8 * 16 + 9]), baseline \(reference[8 * 16 + 9])")
        check(unchanged(8 * 16 + 13), "Uncommitted depth does not invent coverage: actual \(result[8 * 16 + 13]), baseline \(reference[8 * 16 + 13])")
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
