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
        checkRecoveryAndSave(check)
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
        // Explicit element type is essential: unconstrained flatMap selected
        // the optional overload and uploaded array storage, not RGBA bytes.
        let colorBytes: [UInt8] = (0..<256).flatMap { _ -> [UInt8] in [26, 51, 204, 255] }
        let depths: [Float] = (0..<256).map { i in i % 16 < 4 ? 1 : i % 16 < 8 ? 2 : i % 16 < 12 ? 0 : 1 }
        let committed: [Float] = (0..<256).map { $0 % 16 < 8 ? 1 : 0 }
        colorBytes.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64) }
        depths.withUnsafeBytes { depth.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64) }
        committed.withUnsafeBytes { accepted.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64) }
        guard let encoder = command.makeComputeCommandEncoder() else { check(false, "Capture feedback command"); return }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0); encoder.setTexture(output, index: 1)
        encoder.setTexture(depth, index: 2); encoder.setTexture(accepted, index: 3)
        encoder.setTexture(accepted, index: 4)
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
        referenceEncoder.setTexture(accepted, index: 4)
        referenceEncoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        referenceEncoder.dispatchThreads(MTLSize(width: 16, height: 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        referenceEncoder.endEncoding(); referenceCommand.commit(); referenceCommand.waitUntilCompleted()
        check(referenceCommand.status == .completed, "Capture feedback reference GPU command")
        var reference = [SIMD4<Float>](repeating: .zero, count: 256)
        reference.withUnsafeMutableBytes { baseline.getBytes($0.baseAddress!, bytesPerRow: 256, from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0) }
        let sourceColour = SIMD4<Float>(26.0 / 255, 51.0 / 255, 204.0 / 255, 1)
        check(reference.allSatisfy { simd_distance($0, sourceColour) < 0.002 },
              "GPU fixture uploads uniform RGBA8 bytes: \(reference[8 * 16 + 5]), expected \(sourceColour)")
        func unchanged(_ i: Int) -> Bool {
            simd_distance(SIMD3(result[i].x, result[i].y, result[i].z), SIMD3(reference[i].x, reference[i].y, reference[i].z)) < 0.00001
        }
        check(result[8 * 16 + 1].y > 0.45, "Committed in-range surface gets visible mint coverage")
        let outside = 8 * 16 + 5
        let original = SIMD3(reference[outside].x, reference[outside].y, reference[outside].z)
        let grey = simd_dot(original, SIMD3<Float>(0.2126, 0.7152, 0.0722))
        // A uniform input is unchanged by blur. Check the actual desaturation /
        // dimming formula, not a GPU-dependent fixed colour threshold.
        let expected = (original * 0.55 + SIMD3<Float>(repeating: grey) * 0.45) * 0.78
        check(simd_distance(SIMD3(result[outside].x, result[outside].y, result[outside].z), expected) < 0.002,
              "Out-of-range colour: actual \(result[outside]), expected \(expected), GPU \(device.name), OS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        check(unchanged(8 * 16 + 9), "Unknown depth does not invent coverage: actual \(result[8 * 16 + 9]), baseline \(reference[8 * 16 + 9])")
        check(unchanged(8 * 16 + 13), "Uncommitted depth does not invent coverage: actual \(result[8 * 16 + 13]), baseline \(reference[8 * 16 + 13])")

        // Fast colour mode: geometry alone is blue; only a retained, saved
        // sharp photo is allowed to turn it mint. Test the production kernel.
        for hasPhoto in [false, true] {
            guard let photo = texture(.r32Float), let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeComputeCommandEncoder() else { check(false, "Photo coverage command"); return }
            let photoDepths = hasPhoto ? committed : [Float](repeating: 0, count: 256)
            photoDepths.withUnsafeBytes { photo.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64) }
            uniforms.parameters = SIMD4(1.5, 2, 16, 16)
            enc.setComputePipelineState(pipeline)
            enc.setTexture(source, index: 0); enc.setTexture(output, index: 1)
            enc.setTexture(depth, index: 2); enc.setTexture(accepted, index: 3); enc.setTexture(photo, index: 4)
            enc.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.dispatchThreads(MTLSize(width: 16, height: 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
            var pixels = [SIMD4<Float>](repeating: .zero, count: 256)
            pixels.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 256, from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0) }
            let p = pixels[8 * 16 + 1]
            check(cmd.status == .completed && (hasPhoto ? simd_distance(p, result[8 * 16 + 1]) < 0.0001 : p.z > p.y && p.y < result[8 * 16 + 1].y - 0.08),
                  "Fast coverage \(hasPhoto ? "mint with photo" : "blue without photo"): \(p)")
        }
    }

    private static func checkRecoveryAndSave(_ check: (Bool, String) -> Void) {
        do {
            let mesh = terrain()
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let data = try encoder.encode(mesh)
            let restored = try PropertyListDecoder().decode(MeshData.self, from: data)
            check(restored.vertices == mesh.vertices && restored.normals == mesh.normals && restored.faces == mesh.faces,
                  "Packed checkpoint geometry round-trip")
            check(zip(restored.colors, mesh.colors).allSatisfy { simd_distance($0, $1) <= 0.004 },
                  "Packed checkpoint retains sampled camera colour")
            var properties = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
            for key in ["packedVertices", "packedNormals", "packedFaces", "packedColors"] {
                var corrupt = properties
                var bytes = corrupt[key] as! Data; bytes.append(0)
                corrupt[key] = bytes
                let invalid = try PropertyListSerialization.data(fromPropertyList: corrupt, format: .binary, options: 0)
                do {
                    _ = try PropertyListDecoder().decode(MeshData.self, from: invalid)
                    check(false, "Reject truncated \(key)")
                } catch { check(true, "Reject truncated \(key)") }
            }
            properties["packedFaces"] = Data(repeating: 255, count: 12)
            let invalidFaces = try PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0)
            do {
                _ = try PropertyListDecoder().decode(MeshData.self, from: invalidFaces)
                check(false, "Reject out-of-bounds checkpoint indices")
            } catch { check(true, "Reject out-of-bounds checkpoint indices") }
            // Preserve compatibility with the original synthesized Codable shape.
            struct LegacyMesh: Encodable {
                let vertices: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [[UInt32]], colors: [SIMD4<Float>]
                let boundingBoxMin: SIMD3<Float>, boundingBoxMax: SIMD3<Float>
            }
            let legacy = LegacyMesh(vertices: mesh.vertices, normals: mesh.normals, faces: mesh.faces,
                                    colors: mesh.colors, boundingBoxMin: mesh.boundingBoxMin, boundingBoxMax: mesh.boundingBoxMax)
            let old = try PropertyListDecoder().decode(MeshData.self, from: encoder.encode(legacy))
            check(old.vertices == mesh.vertices && old.colors == mesh.colors, "Legacy checkpoint remains readable")
            let bare = LegacyMesh(vertices: mesh.vertices, normals: [], faces: mesh.faces, colors: [],
                                  boundingBoxMin: mesh.boundingBoxMin, boundingBoxMax: mesh.boundingBoxMax)
            let bareMesh = try PropertyListDecoder().decode(MeshData.self, from: encoder.encode(bare))
            check(bareMesh.vertices == mesh.vertices && bareMesh.normals.isEmpty && bareMesh.colors.isEmpty,
                  "Legacy geometry without optional colour / normals remains readable")
            var invalidVertices = mesh.vertices; invalidVertices[0].x = .nan
            let nonFinite = MeshData(vertices: invalidVertices, normals: mesh.normals, faces: mesh.faces, colors: mesh.colors,
                                     boundingBoxMin: mesh.boundingBoxMin, boundingBoxMax: mesh.boundingBoxMax)
            do { _ = try encoder.encode(nonFinite); check(false, "Reject nonfinite checkpoint") }
            catch { check(true, "Reject nonfinite checkpoint") }
            var invalidTriangles = mesh.faces; invalidTriangles[0] = [0, 1]
            let brokenFace = MeshData(vertices: mesh.vertices, normals: mesh.normals, faces: invalidTriangles, colors: mesh.colors,
                                      boundingBoxMin: mesh.boundingBoxMin, boundingBoxMax: mesh.boundingBoxMax)
            do { _ = try encoder.encode(brokenFace); check(false, "Never silently discard malformed faces") }
            catch { check(true, "Never silently discard malformed faces") }

            let root = FileManager.default.temporaryDirectory.appendingPathComponent("save-check-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = StorageManager(directory: root)
            guard let project = store.createProject(name: "Atomic metadata fixture") else { check(false, "Fixture project creation"); return }
            let scan = try store.saveScan(meshData: mesh, name: "Atomic save", toProject: project, metadata: {
                $0.latitude = 59.91; $0.longitude = 10.75
            })
            let reloaded = StorageManager(directory: root).projects.first?.scans.first
            check(reloaded?.id == scan.id && reloaded?.latitude == 59.91 && reloaded?.longitude == 10.75,
                  "Mesh and capture metadata survive first index commit")
            let indexURL = root.appendingPathComponent("projects.json")
            let externalIndex = Data("[]".utf8)
            try externalIndex.write(to: indexURL, options: .atomic)
            do {
                _ = try store.saveScan(meshData: mesh, name: "Must fail", toProject: project, metadata: { $0.latitude = 60 })
                check(false, "Reject a save when the library index changes externally")
            } catch { check(true, "Reject a save when the library index changes externally") }
            let diskAfterFailure = try Data(contentsOf: indexURL)
            check(store.projects.first?.scans.count == 1 && store.projects.first?.scans.first?.id == scan.id &&
                  diskAfterFailure == externalIndex,
                  "Failed metadata/model transaction leaves published library and external index unchanged")
        } catch { check(false, "Recovery / atomic save fixtures: \(error)") }
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
                ContentView(storageManager: store, initialTab: ["scanner", "capture-active", "capture-settings"].contains(screen) ? 0 : screen == "library" ? 2 : screen == "settings" ? 3 : 1)
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
