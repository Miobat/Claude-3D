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
            let object = screen?.hasPrefix("object") == true
            let mesh = screen == "object-wall" ? wallObjectMesh() : (object ? objectMesh() : terrain())
            _ = try? store.saveScan(meshData: mesh, name: object ? "Cabinet · Demo" : "Rocky shoreline", toProject: site,
                originalMesh: screen == "retention" ? mesh : nil, metadata: {
                if screen == "quality" {
                    $0.textureQuality = TextureQualityReport(sharpArea: 76, softArea: 8, fallbackArea: 16,
                        atlasSize: 4096, atlasScale: 0.68, photoCount: 42)
                }
                if screen == "retention" {
                    $0.meshRetention = MeshRetentionReport(cleanup: "Preserve", captured: mesh.retentionStage,
                        cleaned: mesh.retentionStage, saved: mesh.retentionStage)
                }
            })
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

    static func objectMesh(width: Float = 1.2) -> MeshData {
        let bounds = UprightMeasurementBounds(center: SIMD3(0, 0.65, 0), right: SIMD3(1, 0, 0), front: SIMD3(0, 0, 1), size: SIMD3(width, 1.3, 0.6))
        let points = bounds.corners() + [SIMD3<Float>(-2, 0, -2), SIMD3(2, 0, -2), SIMD3(2, 0, 2), SIMD3(-2, 0, 2)]
        let faces: [[UInt32]] = [[4, 5, 7], [4, 7, 6], [0, 2, 3], [0, 3, 1], [0, 4, 6], [0, 6, 2],
                                [1, 3, 7], [1, 7, 5], [2, 6, 7], [2, 7, 3], [0, 1, 5], [0, 5, 4], [8, 10, 9], [8, 11, 10]]
        let extents = MeshData.bounds(of: points)
        return MeshProcessor.recalculateNormals(MeshData(vertices: points, normals: [], faces: faces,
            colors: (0..<12).map { $0 < 8 ? SIMD4<Float>(0.62, 0.49, 0.34, 1) : SIMD4<Float>(0.25, 0.28, 0.3, 1) },
            boundingBoxMin: extents.0, boundingBoxMax: extents.1, faceClassifications: Data(Array(repeating: UInt8(0), count: 12) + [2, 2])))
    }

    static func wallObjectMesh() -> MeshData {
        var points: [SIMD3<Float>] = [], faces: [[UInt32]] = []
        func quad(_ x0: Float, _ x1: Float, _ y0: Float, _ y1: Float, _ z: Float) {
            let i = UInt32(points.count)
            points += [SIMD3(x0,y0,z), SIMD3(x1,y0,z), SIMD3(x1,y1,z), SIMD3(x0,y1,z)]
            faces += [[i,i+1,i+2], [i,i+2,i+3]]
        }
        quad(-0.6,0.6,1,2,0.6)
        quad(-2,-0.8,0,3,0); quad(0.8,2,0,3,0); quad(-0.8,0.8,0,0.7,0); quad(-0.8,0.8,2.3,3,0)
        let bounds = MeshData.bounds(of: points)
        return MeshProcessor.recalculateNormals(MeshData(vertices: points, normals: [], faces: faces,
            colors: points.indices.map { $0 < 4 ? SIMD4<Float>(0.62,0.49,0.34,1) : SIMD4<Float>(0.25,0.28,0.3,1) },
            boundingBoxMin: bounds.0, boundingBoxMax: bounds.1))
    }

    /// Exercises the production mesh pipeline and files in an isolated library.
    static func automaticMeasurementChecks(check: (Bool, String) -> Void) {
        do {
            let vertices: [SIMD3<Float>] = [SIMD3(0, 1, 0), SIMD3(1, 1, 0), SIMD3(0, 2, 0),
                                          SIMD3(0, 1.001, 0), SIMD3(10, 1, 0)]
            let mesh = MeshData(vertices: vertices, normals: Array(repeating: SIMD3(0, 0, 1), count: 5),
                faces: [[0, 1, 2], [0, 3, 1], [4, 4, 4]], colors: [],
                boundingBoxMin: SIMD3(0, 1, 0), boundingBoxMax: SIMD3(10, 2, 0),
                faceClassifications: Data([4, 1, 3]))
            let cleaned = MeshProcessor.removeDegenerateTriangles(mesh)
            check(cleaned.faceClassifications == Data([4, 1]), "Degenerate-face removal remaps labels")
            let welded = MeshProcessor.weldNearbyVertices(cleaned, threshold: 0.005)
            check(welded.faceClassifications == Data([4]), "Welding drops collapsed triangle's label")
            let connected = MeshProcessor.removeSmallComponents(welded, minVertices: 3)
            check(connected.faceClassifications == Data([4]) && connected.vertexCount == 3,
                  "Component removal preserves kept surface label")
            let clustered = MeshProcessor.clusterVertices(mesh, cellSize: 0.01, preservePositions: true)
            check(clustered.faceClassifications == Data([4]), "Detail clustering remaps labels")
            let duplicate = MeshData(vertices: Array(vertices.prefix(3)), normals: [],
                faces: [[0, 1, 2], [1, 2, 0]], colors: [], boundingBoxMin: .zero,
                boundingBoxMax: SIMD3(1, 2, 0), faceClassifications: Data([1, 4]))
            check(MeshProcessor.clusterVertices(duplicate, cellSize: 0.01).faceClassifications == Data([0]),
                  "Collapsed duplicate triangles with conflicting labels become unknown")
            check(MeshProcessor.recalculateNormals(connected).faceClassifications == Data([4]), "Normal rebuild retains labels")
            check(MeshProcessor.smoothNormals(MeshProcessor.recalculateNormals(connected)).faceClassifications == Data([4]),
                  "Normal smoothing retains labels")
            check(MeshProcessor.smoothVertexPositions(connected).faceClassifications == Data([4]), "Position smoothing retains labels")
            check(MeshProcessor.makeUniformGrey(connected).faceClassifications == Data([4]), "No-colour mode retains labels")
            check(connected.transformed(by: matrix_identity_float4x4).faceClassifications == Data([4]), "Scene frame retains labels")
            check(MeshProcessor.voxelDownsamplePoints(connected, leafSize: 0.01).faceClassifications == nil,
                  "Point conversion does not misapply triangle labels to points")
            let baked = BakedTexture(atlasImage: UIImage(), cornerUVs: [.zero, SIMD2(1, 0), SIMD2(0, 1)], atlasSize: 1)
            check(MeshProcessor.createTexturedNode(from: connected, baked: baked).geometry?.elements.first?.primitiveCount == 1,
                  "Textured viewer retains source face order / count")
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let restored = try PropertyListDecoder().decode(MeshData.self, from: encoder.encode(mesh))
            check(restored.faceClassifications == mesh.faceClassifications, "Recovery checkpoint retains face labels")
            let invalid = MeshData(vertices: mesh.vertices, normals: mesh.normals, faces: mesh.faces, colors: mesh.colors,
                boundingBoxMin: mesh.boundingBoxMin, boundingBoxMax: mesh.boundingBoxMax, faceClassifications: Data([4]))
            do { _ = try encoder.encode(invalid); check(false, "Reject checkpoint label / face mismatch") }
            catch { check(true, "Reject checkpoint label / face mismatch") }

            let root = FileManager.default.temporaryDirectory.appendingPathComponent("automatic-check-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = StorageManager(directory: root)
            guard let project = store.createProject(name: "Semantic / measurement fixture") else {
                check(false, "Automatic fixture project created"); return
            }
            let scan = try store.saveScan(meshData: connected, name: "Labelled surface", toProject: project,
                metadata: { $0.recordCaptureFrame(matrix_identity_float4x4) })
            let labels = try store.loadSurfaceLabels(for: scan, in: project)
            check(labels?.classifications == Data([4]) && labels?.category(at: 0) == .table,
                  "Saved labels bind to model and native viewer")
            let legacyScan = try store.saveScan(meshData: MeshData(vertices: connected.vertices, normals: [],
                faces: connected.faces, colors: [], boundingBoxMin: connected.boundingBoxMin,
                boundingBoxMax: connected.boundingBoxMax), name: "Shape-only legacy", toProject: project,
                metadata: { $0.modelScale = 2 })
            check(try store.loadSurfaceLabels(for: legacyScan, in: project) == nil, "Absent legacy labels use shape-only fallback")
            do { _ = try store.automaticMeasurementRevision(for: legacyScan, in: project)
                check(false, "Unverified scale cannot produce automatic metric dimensions")
            } catch { check(true, "Unverified scale cannot produce automatic metric dimensions") }
            let manual = ScanMeasurement(kind: .distance, points: [SIMD3(0, 1, 0), SIMD3(1, 1, 0)])
            try store.saveMeasurements([manual], for: scan, in: project)
            let frame = try UprightMeasurementBounds.fit(points: connected.vertices, front: SIMD3(0, 0, 1))
            let document = AutomaticMeasurementDocument(revision: try store.automaticMeasurementRevision(for: scan, in: project),
                regions: [AutomaticMeasuredRegion(name: "Observed face", kind: .object, bounds: frame, dimensions: [
                    AutomaticDimension(axis: .width, metres: 1, evidence: .partial),
                    AutomaticDimension(axis: .height, metres: 1, evidence: .partial),
                    AutomaticDimension(axis: .depth, metres: nil, evidence: .unavailable)
                ])])
            try store.saveAutomaticMeasurements(document, for: scan, in: project)
            check(try store.loadAutomaticMeasurements(for: scan, in: project) == document, "Automatic selections save / reload")
            check(store.loadMeasurements(for: scan, in: project) == [manual], "Automatic data leaves manual measurements readable")
            let directory = store.getScanFileURL(scan: scan, project: project).deletingLastPathComponent()
            let base = (scan.fileName as NSString).deletingPathExtension
            let autoURL = directory.appendingPathComponent(base + AutomaticMeasurementDocument.suffix)
            let original = try Data(contentsOf: autoURL)
            for bytes in [Data(#"{"version":2,"regions":[{"kind":"future"}]}"#.utf8), Data("broken".utf8)] {
                try bytes.write(to: autoURL, options: .atomic)
                do { _ = try store.loadAutomaticMeasurements(for: scan, in: project); check(false, "Unreadable automatic data reported") }
                catch { check(true, "Unreadable automatic data reported") }
                do { try store.saveAutomaticMeasurements(document, for: scan, in: project); check(false, "Unreadable automatic data cannot be overwritten") }
                catch { check(try Data(contentsOf: autoURL) == bytes, "Unreadable automatic data cannot be overwritten") }
            }
            try original.write(to: autoURL, options: .atomic)
            guard let copy = store.duplicateScan(scan, from: project, to: project) else {
                check(false, "Duplicate semantic scan created"); return
            }
            check(try store.loadSurfaceLabels(for: copy, in: project)?.classifications == Data([4]), "Duplicate retains correctly rebound labels")
            let copyDocument = try store.loadAutomaticMeasurements(for: copy, in: project)
            check(copyDocument?.regions == document.regions, "Duplicate retains automatic regions after OBJ reference rename")

            var movedFrame = matrix_identity_float4x4; movedFrame.columns.3.x = 0.1
            try store.updateScan(scan.id, in: project) { $0.modelTransform = StorageManager.array(of: movedFrame) }
            guard let shifted = store.projects.first?.scans.first(where: { $0.id == scan.id }) else {
                check(false, "Shifted fixture exists"); return
            }
            do { _ = try store.loadAutomaticMeasurements(for: shifted, in: project); check(false, "Alignment change invalidates dimensions") }
            catch { check(true, "Alignment change invalidates dimensions") }
            do { try store.saveAutomaticMeasurements(document, for: shifted, in: project); check(false, "Stale results cannot be saved") }
            catch { check(try Data(contentsOf: autoURL) == original, "Stale results cannot be saved") }
            try store.updateScan(scan.id, in: project) { $0.modelTransform = nil }
            guard let destination = store.createProject(name: "Moved semantic fixture") else {
                check(false, "Move fixture project created"); return
            }
            check(store.moveScan(scan, from: project, to: destination), "Move includes automatic / semantic sidecars")
            check(try store.loadSurfaceLabels(for: scan, in: destination)?.classifications == Data([4]) &&
                  store.loadAutomaticMeasurements(for: scan, in: destination)?.regions == document.regions,
                  "Moved semantic / automatic data remain valid")
            let newDirectory = store.getScanFileURL(scan: scan, project: destination).deletingLastPathComponent()
            store.deleteScan(scan, from: destination)
            check(!FileManager.default.fileExists(atPath: newDirectory.appendingPathComponent(base + SurfaceLabelDocument.suffix).path) &&
                  !FileManager.default.fileExists(atPath: newDirectory.appendingPathComponent(base + AutomaticMeasurementDocument.suffix).path),
                  "Delete removes both registered measurement companions")
        } catch { check(false, "Automatic measurement foundation fixtures: \(error)") }
    }

    /// Runs against the real SceneKit camera / hit tester, not just the pure
    /// maths helpers. The CI script requires this report and rejects failures.
    static func navigationChecks(view: SCNView, coordinator: SceneKitViewRepresentable.Coordinator) {
        guard screen == "navigation-tests", let rig = coordinator.cameraController,
              let camera = view.pointOfView, let lens = camera.camera else { return }
        var failures: [String] = []
        var count = 0
        func check(_ condition: Bool, _ name: String) { count += 1; if !condition { failures.append(name) } }
        check(ObjectPanelLayout.height(expanded: false, landscape: false, accessibility: false) == 190,
              "Object panel defaults to compact portrait height")
        check(ObjectPanelLayout.height(expanded: false, landscape: true, accessibility: false) < 230,
              "Compact object panel frees landscape viewport")
        check(ObjectPanelLayout.height(expanded: false, landscape: false, accessibility: true) < 320,
              "Large-text compact panel remains bounded and scrollable")
        check(ObjectPanelLayout.height(expanded: true, landscape: false, accessibility: false) == 320 &&
              ObjectPanelLayout.height(expanded: true, landscape: true, accessibility: true) == 230,
              "Expanded object tools retain full review viewport")
        automaticMeasurementChecks(check: check)
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
        checkMeshRetention(check)
        checkTextureQuality(check)
        checkObjects(view: view, coordinator: coordinator, check: check) {
            let report: [String: Any] = ["checks": count, "failures": failures]
            let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("navigation-checks.json")
            do { try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(to: output, options: .atomic) }
            catch { assertionFailure("Could not write navigation test report: \(error)") }
        }
    }

    private static func checkObjects(view: SCNView, coordinator: SceneKitViewRepresentable.Coordinator,
                                     check: @escaping (Bool, String) -> Void, done: @escaping () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("object-ui-check-\(UUID().uuidString)")
        let store = StorageManager(directory: root), session = ObjectMeasurementSession()
        var renderedRegion: AutomaticMeasuredRegion?, renderedHighlight: SCNNode?
        session.render = { renderedRegion = $0; renderedHighlight = $1 }
        func finish() { session.detach(); try? FileManager.default.removeItem(at: root); done() }
        func idle(_ attempt: Int = 0, then: @escaping () -> Void) {
            if !session.busy { then(); return }
            guard attempt < 100 else { check(false, "Object worker completes without blocking main thread"); finish(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { idle(attempt + 1, then: then) }
        }
        do {
            guard let project = store.createProject(name: "Object UI fixture") else { check(false, "Object fixture project"); finish(); return }
            let mesh = objectMesh(width: 3.8)
            let scan = try store.saveScan(meshData: mesh, name: "Cabinet", toProject: project, metadata: { $0.recordCaptureFrame(matrix_identity_float4x4) })
            let node = MeshProcessor.createSceneKitNode(from: mesh)
            let sources = ModelGeometryIndex.sources(in: node)
            let geometry = try ObjectSceneGeometry.read(sources)
            check(geometry.points.count == mesh.vertices.count && geometry.triangles.count == mesh.faces.count,
                  "Native Object extraction retains exact metric vertex and face order")
            let index = try ObjectSelectionIndex(points: geometry.points, triangles: geometry.triangles, labels: mesh.faceClassifications)
            let selection = try index.grow(from: 0).selection
            let highlight = try ObjectSceneGeometry.highlight(index: index, selection: selection)
            check(highlight.name == "objectSelection" && highlight.geometry?.elements.first?.primitiveCount == selection.ids.count &&
                  !selection.ids.contains(12) && !selection.ids.contains(13),
                  "Object highlight contains only selected triangles, not the floor")
            coordinator.parent.objects.active = true; coordinator.parent.objects.mode = .add; coordinator.updateObjectGestures()
            check(coordinator.objectPaint?.isEnabled == true && coordinator.cameraController?.selectionEditing == true,
                  "Object paint mode replaces only one-finger orbit")
            check(view.gestureRecognizers?.contains { ($0 as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2 && $0.isEnabled } ?? false,
                  "Object paint keeps two-finger navigation available")
            coordinator.parent.objects.mode = .part; coordinator.updateObjectGestures()
            check(coordinator.objectPaint?.isEnabled == false && coordinator.cameraController?.selectionEditing == false,
                  "Add part uses taps and keeps one-finger orbit available")
            coordinator.parent.objects.active = false; coordinator.parent.objects.mode = .select; coordinator.updateObjectGestures()
            // Actual hit under the overlay must resolve to model geometry.
            let old = view.pointOfView?.simdTransform
            node.simdPosition = SIMD3(20, 0, 0); highlight.simdPosition = SIMD3(20, 0, 0)
            view.scene?.rootNode.addChildNode(node); view.scene?.rootNode.addChildNode(highlight)
            coordinator.cameraController?.set(yaw: 0, pitch: 0, target: SIMD3(20, 0.65, 0), distance: 3, animated: false)
            SCNTransaction.flush(); _ = view.snapshot()
            let target = SIMD3<Float>(20, 0.65, 0.3), pixel = view.projectPoint(SCNVector3(target.x, target.y, target.z))
            let hit = coordinator.surfacePointForFocus(at: CGPoint(x: CGFloat(pixel.x), y: CGFloat(pixel.y)))
            check(hit.map { simd_distance($0, target) < 0.005 } ?? false, "Object overlay does not intercept surface picking")
            node.removeFromParentNode(); highlight.removeFromParentNode(); node.simdPosition = .zero
            if let old { view.pointOfView?.simdTransform = old; coordinator.cameraController?.syncFromCamera() }
            session.prepare(sources: ModelGeometryIndex.sources(in: node), store: store, scan: scan, project: project)
            idle {
                check(session.ready && session.writable, "Object session prepares verified model and writable storage")
                guard session.ready else { finish(); return }
                session.active = true
                session.pick(point: SIMD3(0, 0.65, 0.3), normal: SIMD3(1, 0, 0), cameraFront: SIMD3(0, 0, 1))
                idle {
                    guard let draft = session.draft else { check(false, "Object tap produces a draft"); finish(); return }
                    check(abs(draft.bounds.size.x - 3.8) < 0.0001 && abs(draft.bounds.size.y - 1.3) < 0.0001 && abs(draft.bounds.size.z - 0.6) < 0.0001,
                          "Object tap finds the entire 3.8 m cabinet and ignores a misleading local face normal")
                    session.save()
                    idle {
                        do {
                            let document = try store.loadAutomaticMeasurements(for: scan, in: project)
                            check(document?.regions.first?.selection == draft.selection && !session.dirty,
                                  "Save persists exact selected surfaces and clears unsaved state")
                            session.newObject(); session.open(draft)
                            idle {
                                check(session.draft == draft && !session.dirty, "Reopening restores reviewed bounds and exact object selection")
                                session.rotateFront()
                                idle {
                                    check(session.draft.map { abs($0.bounds.size.x - 0.6) < 0.0001 && abs($0.bounds.size.z - 3.8) < 0.0001 } ?? false,
                                          "Turning object front swaps width and depth in the local frame")
                                    session.undo()
                                    idle {
                                        check(session.draft?.bounds == draft.bounds, "Object undo restores prior orientation and extents")
                                        session.mode = .remove
                                        session.pick(point: SIMD3(0, 0.65, 0.3), normal: SIMD3(0, 0, 1), cameraFront: SIMD3(0, 0, 1))
                                        session.pick(point: SIMD3(0, 0.65, -0.3), normal: SIMD3(0, 0, -1), cameraFront: SIMD3(0, 0, 1))
                                        idle {
                                            check(session.draft?.selection?.ids.count == (draft.selection?.ids.count ?? 0) - 4,
                                                  "Coalesced paint removes front and final rear stroke without unbounded work")
                                            session.undo()
                                            idle {
                                                session.undo()
                                                idle {
                                                    check(session.draft?.selection == draft.selection, "Undo restores exact surfaces after both paint samples")
                                                    session.mode = .select
                                                    session.pick(point: SIMD3(1.5,0,1.5), normal: SIMD3(0,1,0), cameraFront: SIMD3(0,0,1))
                                                    idle {
                                                        check(session.draft == nil && session.wallDepth == nil && !session.dirty && session.canUndo,
                                                              "Rejected object tap clears stale box and Save state but keeps Undo")
                                                        check(renderedRegion == nil && renderedHighlight == nil, "Rejected tap clears the actual renderer overlay")
                                                        session.undo()
                                                        idle {
                                                            check(session.draft?.selection == draft.selection, "Undo recovers the prior selection after a rejected tap")
                                                            session.mode = .part
                                                            session.pick(point: SIMD3(0,0.65,0.3), normal: SIMD3(0,0,1), cameraFront: SIMD3(0,0,1))
                                                            idle {
                                                                check(session.draft?.selection == draft.selection && session.draft?.dimensions.first?.evidence == .partial,
                                                                      "Add part session unions exact IDs and marks review as Partial")
                                                                session.undo()
                                                                idle {
                                                                    session.mode = .select; session.missedPick()
                                                                    idle {
                                                                        check(session.draft == nil && renderedHighlight == nil, "Tap on missing geometry clears stale measurement")
                                                                        session.undo()
                                                                        idle {
                                                                            check(session.draft?.selection == draft.selection, "Missed-tap Undo preserves source IDs")
                                                                            finishEdits()
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        func finishEdits() {
                                            session.adjust(name: "Reviewed cabinet", size: SIMD3(1.25, 1.3, 0.6))
                                            check(session.draft?.dimensions.first { $0.axis == .width }?.evidence == .adjusted && session.dirty,
                                                  "Edited object bounds are explicitly adjusted, never measured")
                                            for aligned in ["front", "side", "top"] {
                                                coordinator.alignObject(view: aligned, bounds: draft.bounds)
                                                let direction = aligned == "side" ? draft.bounds.right : draft.bounds.front
                                                let camera = view.pointOfView?.simdTransform
                                                let axis = aligned == "top" ? SIMD3<Float>(0, 1, 0) : direction
                                                check(camera.map { simd_dot(SIMD3($0.columns.2.x, $0.columns.2.y, $0.columns.2.z), axis) > 0.999 } ?? false,
                                                      "Object \(aligned) view aligns orthographically to selection axes")
                                            }
                                            session.deleteDraft()
                                            idle {
                                                check(session.saved.isEmpty && session.draft == nil, "Delete removes only the saved object result")
                                                finish()
                                            }
                                        }
                                    }
                                }
                            }
                        } catch { check(false, "Object native persistence: \(error)"); finish() }
                    }
                }
            }
        } catch { check(false, "Object native fixture: \(error)"); finish() }
    }

    private static func checkTextureQuality(_ check: (Bool, String) -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("texture-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            func photo(_ name: String, pixels: [UInt8]) throws -> URL {
                let data = Data(pixels)
                guard let provider = CGDataProvider(data: data as CFData),
                      let image = CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                      let png = UIImage(cgImage: image).pngData() else { throw CocoaError(.fileReadCorruptFile) }
                let url = root.appendingPathComponent(name + ".png")
                try png.write(to: url); return url
            }
            let red = try photo("red", pixels: (0..<64).flatMap { _ -> [UInt8] in [255, 0, 0, 255] })
            let blue = try photo("blue", pixels: (0..<64).flatMap { _ -> [UInt8] in [0, 0, 255, 255] })
            let quads = try photo("quadrants", pixels: (0..<64).flatMap { i -> [UInt8] in
                i < 32 ? (i % 8 < 4 ? [255, 0, 0, 255] : [0, 255, 0, 255])
                    : (i % 8 < 4 ? [0, 0, 255, 255] : [255, 255, 255, 255])
            })
            guard let image = DecodedImage(url: quads) else { check(false, "Decode texture fixture"); return }
            check(image.sample(SIMD2(0.2, 0.2), gain: 1).x > 0.99 && image.sample(SIMD2(0.2, 0.8), gain: 1).z > 0.99 &&
                  image.sample(SIMD2(0.8, 0.2), gain: 1).y > 0.99, "Decoded photos retain sensor quadrant orientation")
            check(image.sample(SIMD2(-10, -10), gain: 1) == image.sample(.zero, gain: 1) &&
                  image.sample(SIMD2(10, 10), gain: 1) == image.sample(SIMD2(1, 1), gain: 1), "Texture padding clamps bilinear samples")
            let intrinsics = simd_float3x3(SIMD3(4, 0, 0), SIMD3(0, 4, 0), SIMD3(4, 4, 1))
            let depth = [Float](repeating: 1, count: 64)
            func frame(_ id: Int, _ url: URL, sharp: Bool = true, depth values: [Float]? = nil) -> CapturedFrame {
                CapturedFrame(id: id, imageURL: url, transform: matrix_identity_float4x4, intrinsics: intrinsics,
                    imageWidth: 8, imageHeight: 8, timestamp: Double(id), depth: values ?? depth, depthWidth: 8, depthHeight: 8,
                    gain: 1, sharp: sharp)
            }
            let pose = FramePose(view: matrix_identity_float4x4, intrinsics: intrinsics, sensorW: 8, sensorH: 8,
                position: .zero, forward: SIMD3(0, 0, -1), depth: depth, depthW: 8, depthH: 8)
            check(pose.isVisible(.init(uv: SIMD2(0.5, 0.5), depth: 1)), "Texture accepts matching depth")
            check(!pose.isVisible(.init(uv: SIMD2(0.5, 0.5), depth: 0.5)) &&
                  !pose.isVisible(.init(uv: SIMD2(0.5, 0.5), depth: 2)), "Texture rejects both foreground and background mismatch")
            check(!pose.isVisible(.init(uv: SIMD2(.nan, 0.5), depth: 1)), "Texture safely rejects invalid projection")
            let vertices: [SIMD3<Float>] = [SIMD3(-0.4, 0.4, -1), SIMD3(-0.4, -0.4, -1), SIMD3(0.4, -0.4, -1)]
            let bounds = MeshData.bounds(of: vertices)
            let mesh = MeshData(vertices: vertices, normals: Array(repeating: SIMD3(0, 0, 1), count: 3), faces: [[0, 1, 2]],
                colors: Array(repeating: SIMD4(0, 1, 1, 1), count: 3), boundingBoxMin: bounds.0, boundingBoxMax: bounds.1)
            var cornerBlocked = depth; cornerBlocked[2 * 8 + 2] = 0.5
            let cases: [(String, [CapturedFrame], Float, Float, Float)] = [
                ("Sharp beats soft", [frame(1, red, sharp: false), frame(2, blue)], 1, 0, 0),
                ("Soft fallback remains available", [frame(1, red, sharp: false)], 0, 1, 0),
                ("Occluded corner rejects entire photo patch", [frame(1, red, depth: cornerBlocked)], 0, 0, 1),
                ("Unknown depth cannot authorize a photo", [frame(1, red, depth: [])], 0, 0, 1),
                ("Missing JPEG retains sampled colour", [frame(1, root.appendingPathComponent("missing.jpg"))], 0, 0, 1)
            ]
            for (name, frames, sharp, soft, fallback) in cases {
                try autoreleasepool {
                    let mapper = TextureMapper(); mapper.useFixtureFrames(frames)
                    guard let baked = mapper.bakeTexture(meshData: mesh, atlasSize: 2048), let report = baked.quality else {
                        check(false, name + " bakes"); return
                    }
                    check(abs(report.sharpFraction - Double(sharp)) < 0.001 && abs(report.softFraction - Double(soft)) < 0.001 &&
                          abs(report.fallbackFraction - Double(fallback)) < 0.001, name + " — area report")
                    let url = root.appendingPathComponent("atlas.png")
                    try baked.atlasImage.pngData()!.write(to: url)
                    guard let atlas = DecodedImage(url: url) else { check(false, "Decode baked atlas"); return }
                    let uv = baked.cornerUVs.reduce(SIMD2<Float>.zero, +) / 3
                    let c = atlas.sample(SIMD2(uv.x, 1 - uv.y), gain: 1)
                    check(fallback > 0 ? c.x < 0.01 && c.y > 0.99 && c.z > 0.99
                          : sharp > 0 ? c.x < 0.01 && c.z > 0.99 : c.x > 0.99 && c.z < 0.01, name + " — real atlas colour")
                    if sharp > 0 {
                        let store = StorageManager(directory: root.appendingPathComponent("library"))
                        guard let project = store.createProject(name: "Texture metadata") else { check(false, "Texture project fixture"); return }
                        let scan = try store.saveScan(meshData: mesh, name: name, toProject: project, baked: baked)
                        let restored = StorageManager(directory: root.appendingPathComponent("library")).projects.first?.scans.first
                        check(restored?.textureQuality == report && restored?.hasTexture == true, "Texture report persists with baked model")
                        let duplicate = store.duplicateScan(scan, from: project, to: project)
                        check(duplicate?.textureQuality == report, "Duplicate retains texture report")
                        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scan)) as! [String: Any]
                        json.removeValue(forKey: "textureQuality")
                        let legacy = try JSONDecoder().decode(Scan.self, from: JSONSerialization.data(withJSONObject: json))
                        check(legacy.textureQuality == nil, "Legacy scans without quality report still decode")
                    }
                }
            }
        } catch { check(false, "Native texture fixtures: \(error)") }
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
        check(result[8 * 16 + 1].z > result[8 * 16 + 1].y && result[8 * 16 + 1].y > reference[8 * 16 + 1].y + 0.05,
              "Committed in-range surface gets visible blue shape coverage")
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
        for mode: Float in [2, 3] { for hasPhoto in [false, true] {
            guard let photo = texture(.r32Float), let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeComputeCommandEncoder() else { check(false, "Photo coverage command"); return }
            let photoDepths = hasPhoto ? committed : [Float](repeating: 0, count: 256)
            photoDepths.withUnsafeBytes { photo.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64) }
            uniforms.parameters = SIMD4(1.5, mode, 16, 16)
            enc.setComputePipelineState(pipeline)
            enc.setTexture(source, index: 0); enc.setTexture(output, index: 1)
            enc.setTexture(depth, index: 2); enc.setTexture(accepted, index: 3); enc.setTexture(photo, index: 4)
            enc.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.dispatchThreads(MTLSize(width: 16, height: 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
            var pixels = [SIMD4<Float>](repeating: .zero, count: 256)
            pixels.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 256, from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0) }
            let p = pixels[8 * 16 + 1]
            check(cmd.status == .completed && (hasPhoto ? p.y > result[8 * 16 + 1].y + 0.05 : p.y < result[8 * 16 + 1].y + 0.04),
                  "Photo coverage mode \(mode), \(hasPhoto ? "green candidate" : "needs photo"): \(p)")
            check(simd_distance(pixels[8 * 16 + 13], reference[8 * 16 + 13]) < 0.00001,
                  "Photo mode \(mode) cannot mark uncaptured geometry")
        } }
    }

    private static func checkMeshRetention(_ check: (Bool, String) -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retention-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            var mesh = wallObjectMesh()
            // A TV front only 18 mm off the wall, mislabelled as wall by ARKit.
            let points = mesh.vertices.enumerated().map { i, p in i < 4 ? SIMD3(p.x, p.y, Float(0.018)) : p }
            let bounds = MeshData.bounds(of: points)
            mesh = MeshData(vertices: points, normals: mesh.normals, faces: mesh.faces, colors: mesh.colors,
                boundingBoxMin: bounds.0, boundingBoxMax: bounds.1,
                faceClassifications: Data(repeating: SurfaceCategory.wall.rawValue, count: mesh.faceCount))
            let coloured = mesh.replacingColors(Array(repeating: SIMD4<Float>(0.3,0.4,0.5,1), count: points.count))
            check(coloured.faceClassifications == mesh.faceClassifications, "Camera recolouring retains floor/wall labels")
            let preserved = MeshProcessor.postProcess(coloured, level: .quick, preservePositions: true)
            check(preserved.vertices == mesh.vertices && preserved.faces == mesh.faces,
                  "Preserve cleanup keeps sparse wall triangles and thin object geometry exactly")
            let balanced = MeshProcessor.postProcess(coloured, level: .standard, preservePositions: true)
            check(balanced.faceCount == mesh.faceCount, "Balanced cleanup no longer deletes large sparse wall components")
            let index = try ObjectSelectionIndex(points: preserved.vertices, triangles: preserved.faces.map { SIMD3($0[0],$0[1],$0[2]) }, labels: preserved.faceClassifications)
            check(try index.grow(from: 0).selection.ids == [0,1], "Recolour → cleanup → Object keeps thin TV separate from wall")
            let store = StorageManager(directory: root)
            guard let project = store.createProject(name: "Original recovery"), let destination = store.createProject(name: "Move target") else {
                check(false, "Original fixture project creation"); return
            }
            let report = MeshRetentionReport(cleanup: "Preserve", captured: mesh.retentionStage, cleaned: preserved.retentionStage, saved: preserved.retentionStage)
            let scan = try store.saveScan(meshData: preserved, name: "Thin TV", toProject: project, originalMesh: mesh) {
                $0.meshRetention = report; $0.recordCaptureFrame(matrix_identity_float4x4); $0.latitude = 59.9
            }
            let reloaded = StorageManager(directory: root).projects.first { $0.id == project.id }?.scans.first
            check(reloaded?.originalMeshSHA256 == scan.originalMeshSHA256 && reloaded?.meshRetention == report,
                  "Original hash and retention report survive library reload")
            let copy = try store.saveOriginalCopy(of: scan, in: project)
            check(copy.id != scan.id && copy.faceCount == mesh.faceCount && copy.latitude == scan.latitude && copy.sceneFrame == scan.sceneFrame,
                  "Restore creates a separate metric copy with capture reference intact")
            check(copy.textureQuality == nil && copy.originalMeshSHA256 == nil, "Original copy does not claim a baked photo atlas or inherited measurements")
            check(try store.loadSurfaceLabels(for: copy, in: project)?.classifications == mesh.faceClassifications,
                  "Restored original retains semantic labels")
            guard let duplicate = store.duplicateScan(scan, from: project, to: project) else { check(false, "Duplicate original fixture"); return }
            check(duplicate.originalMeshSHA256 == scan.originalMeshSHA256 && duplicate.meshRetention == report,
                  "Duplicate retains original and cleanup report")
            check(store.moveScan(duplicate, from: project, to: destination), "Move carries original mesh to destination")
            let movedCopy = try store.saveOriginalCopy(of: duplicate, in: destination)
            check(movedCopy.faceCount == mesh.faceCount, "Moved original remains restorable")
            let originalURL = store.getScanFileURL(scan: duplicate, project: destination).deletingLastPathComponent()
                .appendingPathComponent((duplicate.fileName as NSString).deletingPathExtension + "_original.mesh")
            try Data("corrupt".utf8).write(to: originalURL, options: .atomic)
            let count = store.projects.reduce(0) { $0 + $1.scans.count }
            do { _ = try store.saveOriginalCopy(of: duplicate, in: destination); check(false, "Reject corrupt original") }
            catch { check(store.projects.reduce(0) { $0 + $1.scans.count } == count, "Corrupt original creates no misleading copy") }
            store.deleteScan(duplicate, from: destination)
            check(!FileManager.default.fileExists(atPath: originalURL.path), "Deleting a scan removes its original companion")
        } catch { check(false, "Mesh retention fixtures: \(error)") }
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
            if ["viewer", "measure", "object", "object-wall", "object-rejected", "object-expanded", "walk", "joysticks", "quality", "retention", "navigation-tests"].contains(screen), let project = store.projects.first, let scan = project.scans.first {
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
