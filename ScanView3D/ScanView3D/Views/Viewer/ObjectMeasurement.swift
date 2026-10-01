import SwiftUI
import SceneKit
import simd

private final class ObjectWorkToken {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func cancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

/// Worker-owned geometry; main-thread observable state. No scene traversal,
/// hashing, growing or file I/O runs in a gesture callback.
final class ObjectMeasurementSession: ObservableObject {
    enum Mode: String, CaseIterable { case select = "Select", add = "Add", remove = "Remove" }
    @Published var active = false { didSet { publish() } }
    @Published var mode: Mode = .select
    @Published var brushRadius: Float = 0.08
    @Published private(set) var draft: AutomaticMeasuredRegion?
    @Published private(set) var saved: [AutomaticMeasuredRegion] = []
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published private(set) var writable = false
    @Published private(set) var message = "Preparing object geometry…"
    @Published private(set) var warning: String?
    @Published private(set) var dirty = false
    @Published private(set) var wallDepth: ObjectSelectionIndex.WallDepthCandidate?
    var unit: ScanSettings.MeasurementUnit = .preferred { didSet { publish() } }
    var render: ((AutomaticMeasuredRegion?, SCNNode?) -> Void)?
    var alignView: ((String, UprightMeasurementBounds) -> Void)?
    private let queue = DispatchQueue(label: "scan.object-measurement", qos: .userInitiated)
    private var index: ObjectSelectionIndex? // accessed only on queue
    private var revision: MeasurementModelRevision?
    private var store: StorageManager?
    private var scan: Scan?
    private var project: Project?
    private var highlight: SCNNode?
    private var generation = UUID()
    private var partial = false
    private var undoStack: [AutomaticMeasuredRegion?] = []
    private var pendingPaint: (SIMD3<Float>, SIMD3<Float>?, SIMD3<Float>)?
    private var work = ObjectWorkToken()

    func prepare(sources: [ModelGeometryIndex.Source], store: StorageManager, scan: Scan, project: Project, labelsVerified: Bool = true) {
        let token = UUID(); generation = token
        work.cancel(); let work = ObjectWorkToken(); self.work = work
        self.store = store; self.scan = scan; self.project = project
        draft = nil; saved = []; highlight = nil; wallDepth = nil; undoStack.removeAll(); dirty = false; warning = nil
        publish()
        ready = false; busy = true; writable = false; pendingPaint = nil; message = "Preparing object geometry…"
        queue.async { [weak self] in
            do {
                let geometry = try ObjectSceneGeometry.read(sources, cancelled: work.cancelled)
                var warning: String?
                var labels: Data?
                do { if labelsVerified { labels = try store.loadSurfaceLabels(for: scan, in: project)?.classifications } }
                catch { warning = "Surface labels could not be verified. Selection uses shape only." }
                if labels?.count != geometry.triangles.count { labels = nil }
                let index = try ObjectSelectionIndex(points: geometry.points, triangles: geometry.triangles, labels: labels, cancelled: work.cancelled)
                let revision = try store.automaticMeasurementRevision(for: scan, in: project)
                var document: AutomaticMeasurementDocument?
                var loadError: String?
                do {
                    document = try store.loadAutomaticMeasurements(for: scan, in: project)
                    for region in document?.regions ?? [] { if let selection = region.selection { try index.validate(selection) } }
                } catch { loadError = error.localizedDescription }
                self?.index = index
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.revision = revision; self.saved = document?.regions ?? []
                    self.ready = true; self.busy = false; self.writable = loadError == nil
                    self.warning = loadError ?? warning
                    self.message = loadError == nil ? "Tap an object. Its boundary and size are detected automatically." : "Review only — existing measurement file has been preserved."
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.busy = false; self.message = error.localizedDescription
                }
            }
        }
    }

    func pick(point: SIMD3<Float>, normal: SIMD3<Float>?, cameraFront: SIMD3<Float>) {
        guard ready else { return }
        if busy {
            // Keep just one pending paint hit: bounded work, preserved stroke end.
            if mode != .select { pendingPaint = (point, normal, cameraFront) }
            return
        }
        let mode = mode, token = generation, previous = draft, work = work
        let brush = brushRadius
        var proposed = normal.flatMap { abs($0.y) < 0.5 ? $0 : nil } ?? cameraFront
        if simd_dot(proposed, cameraFront) < 0 { proposed = -proposed }
        let horizontal = SIMD3<Float>(proposed.x, 0, proposed.z)
        let front = simd_length(horizontal) > 0.001 ? simd_normalize(horizontal) : SIMD3(0, 0, 1)
        busy = true
        queue.async { [weak self] in
            guard let self, let index = self.index else { return }
            do {
                var selection: AutomaticRegionSelection?, limited = false
                if mode == .select {
                    guard let seed = index.nearest(to: point) else { throw ObjectSelectionError.noSurface }
                    let result = try index.grow(from: seed, cancelled: work.cancelled)
                    selection = result.selection; limited = result.touchesLimit || result.bridgedGap
                } else {
                    selection = try index.brush(previous?.selection, at: point, radius: brush, adding: mode == .add)
                    limited = true
                }
                var region = try selection.map { try index.region(selection: $0, front: mode == .select ? front : (previous?.bounds.front ?? front), partial: limited, automaticOrientation: mode == .select) }
                if mode != .select, let old = previous { region?.id = old.id; region?.name = old.name; region?.createdAt = old.createdAt }
                let node = try region?.selection.map { try ObjectSceneGeometry.highlight(index: index, selection: $0) }
                let wall = region.flatMap(index.wallDepth)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.undoStack.append(previous); if self.undoStack.count > 12 { self.undoStack.removeFirst() }
                    self.draft = region; self.highlight = node; self.partial = limited
                    self.wallDepth = wall
                    self.dirty = true; self.busy = false
                    self.message = region == nil ? "Selection cleared. Tap an object to start again." :
                        (mode != .select ? "Selection adjusted. Review the highlighted surfaces." :
                            (limited ? "Boundary crosses a small scan gap. Review the highlighted object." : "Boundary detected. Review the highlighted object."))
                    self.publish()
                    self.continuePaint()
                }
            } catch { self.fail(error, token: token) }
        }
    }

    func rotateFront() {
        guard let region = draft, let selection = region.selection, !busy else { return }
        updateSelection(selection, front: region.bounds.right, previous: region)
    }

    /// Fine heading adjustment covers objects that are not parallel to room axes.
    func turnFront(degrees: Float) {
        guard let region = draft, let selection = region.selection, !busy else { return }
        let front = simd_quatf(angle: degrees * .pi / 180, axis: SIMD3<Float>(0, 1, 0)).act(region.bounds.front)
        updateSelection(selection, front: front, previous: region)
    }

    func undo() {
        guard !busy, let previous = undoStack.popLast() else { return }
        if let previous, let selection = previous.selection {
            updateSelection(selection, front: previous.bounds.front, previous: previous, refit: false)
        } else { draft = nil; highlight = nil; wallDepth = nil; dirty = true; publish() }
    }
    var canUndo: Bool { !undoStack.isEmpty && !busy }

    func open(_ region: AutomaticMeasuredRegion) {
        guard !busy else { return }
        if let selection = region.selection { updateSelection(selection, front: region.bounds.front, previous: region, refit: false, opening: true) }
        else {
            draft = region; highlight = nil; wallDepth = nil; undoStack.removeAll(); dirty = false
            message = "Older result: bounds only. Select the object again to restore its surface highlight."
            publish()
        }
    }

    private func updateSelection(_ selection: AutomaticRegionSelection, front: SIMD3<Float>, previous: AutomaticMeasuredRegion,
                                 refit: Bool = true, opening: Bool = false) {
        busy = true; let token = generation, limited = partial
        queue.async { [weak self] in
            guard let self, let index = self.index else { return }
            do {
                try index.validate(selection)
                var result = refit ? try index.region(selection: selection, front: front, partial: limited, name: previous.name) : previous
                result.id = previous.id; result.createdAt = previous.createdAt
                let node = try ObjectSceneGeometry.highlight(index: index, selection: selection)
                let wall = index.wallDepth(for: result)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    if refit { self.undoStack.append(previous); if self.undoStack.count > 12 { self.undoStack.removeFirst() } }
                    if opening { self.undoStack.removeAll() }
                    self.draft = result; self.highlight = node; self.busy = false; self.dirty = !opening
                    self.wallDepth = wall
                    self.partial = result.dimensions.contains { $0.evidence == .partial }
                    self.message = opening ? "Saved result — observed surfaces, not hidden geometry." : "Front direction changed. Review width and depth."
                    self.publish()
                }
            } catch { self.fail(error, token: token) }
        }
    }

    func adjust(name: String, size: SIMD3<Float>) {
        guard var result = draft, !busy, !name.isEmpty, name.count <= 200,
              size.x.isFinite, size.y.isFinite, size.z.isFinite, size.x > 0, size.y > 0, size.z >= 0 else { return }
        let old = result.bounds.size
        result.wallProjection = nil
        result.name = name
        // Keep lower/rear/left datum fixed when changing an overall extent.
        result.bounds.center += result.bounds.right * ((size.x - old.x) * 0.5)
            + SIMD3(0, (size.y - old.y) * 0.5, 0) + result.bounds.front * ((size.z - old.z) * 0.5)
        result.bounds.size = size
        for i in result.dimensions.indices {
            let d = result.dimensions[i]
            let axis = d.axis == .width ? 0 : (d.axis == .height ? 1 : 2)
            if abs(size[axis] - old[axis]) > 0.00001 {
                result.dimensions[i] = AutomaticDimension(axis: d.axis, metres: size[axis] > 0 ? size[axis] : nil,
                    evidence: size[axis] > 0 ? .adjusted : .unavailable)
            }
        }
        guard (try? result.validate()) != nil else { return }
        undoStack.append(draft); if undoStack.count > 12 { undoStack.removeFirst() }
        draft = result; wallDepth = nil; dirty = true; message = "Edited bounds — adjusted dimensions are not scan-derived."; publish()
    }

    func confirmWallContact() {
        guard let previous = draft, wallDepth != nil, !busy else { return }
        let token = generation; busy = true
        queue.async { [weak self] in
            guard let self, let index = self.index else { return }
            do {
                let result = try index.assumingWallContact(previous, confirmed: true)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.undoStack.append(previous); if self.undoStack.count > 12 { self.undoStack.removeFirst() }
                    self.draft = result; self.wallDepth = nil; self.busy = false; self.dirty = true
                    self.message = "Wall-based depth assumes confirmed flush contact. It is not a scanned rear face."
                    self.publish()
                }
            } catch { self.fail(error, token: token) }
        }
    }

    func save() {
        guard let draft, writable, !busy else { return }
        var list = saved.filter { $0.id != draft.id }; list.append(draft)
        persist(list, message: "Object saved. Reopen it from the saved list.")
    }
    func deleteDraft() {
        guard let draft, writable, !busy else { return }
        if saved.contains(where: { $0.id == draft.id }) { persist(saved.filter { $0.id != draft.id }, message: "Saved object deleted.", clear: true) }
        else { self.draft = nil; highlight = nil; wallDepth = nil; undoStack.removeAll(); dirty = false; publish() }
    }
    func newObject() {
        guard !busy else { return }
        draft = nil; highlight = nil; wallDepth = nil; undoStack.removeAll(); dirty = false; mode = .select
        message = "Tap an object. Its boundary and size are detected automatically."; publish()
    }

    private func persist(_ list: [AutomaticMeasuredRegion], message: String, clear: Bool = false) {
        guard let revision, let store, let scan, let project else { return }
        let token = generation; busy = true
        queue.async { [weak self] in
            do {
                try store.saveAutomaticMeasurements(AutomaticMeasurementDocument(revision: revision, regions: list), for: scan, in: project)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.saved = list; self.busy = false; self.dirty = false; self.message = message
                    if clear { self.draft = nil; self.highlight = nil; self.wallDepth = nil; self.undoStack.removeAll() }
                    self.publish()
                }
            } catch { self?.fail(error, token: token) }
        }
    }
    private func fail(_ error: Error, token: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            self.busy = false; self.message = error.localizedDescription
            self.pendingPaint = nil
        }
    }
    private func continuePaint() {
        guard active, mode != .select, let hit = pendingPaint else { pendingPaint = nil; return }
        pendingPaint = nil
        pick(point: hit.0, normal: hit.1, cameraFront: hit.2)
    }
    func detach() { work.cancel(); generation = UUID(); pendingPaint = nil; render = nil; alignView = nil }
    private func publish() { render?(active ? draft : nil, active ? highlight : nil) }
}

enum ObjectSceneGeometry {
    struct Geometry { let points: [SIMD3<Float>]; let triangles: [SIMD3<UInt32>] }
    static func read(_ sources: [ModelGeometryIndex.Source], cancelled: () -> Bool = { false }) throws -> Geometry {
        var points: [SIMD3<Float>] = [], triangles: [SIMD3<UInt32>] = []
        for source in sources {
            guard let vertices = source.geometry.sources(for: .vertex).first,
                  vertices.usesFloatComponents, vertices.bytesPerComponent == 4, vertices.componentsPerVector >= 3,
                  vertices.vectorCount > 0, vertices.vectorCount <= ObjectSelectionIndex.maximumPoints,
                  vertices.dataOffset >= 0, vertices.dataStride >= 12, vertices.data.count >= 12,
                  vertices.dataOffset <= vertices.data.count - 12,
                  vertices.vectorCount == 1 || vertices.dataStride <= (vertices.data.count - vertices.dataOffset - 12) / (vertices.vectorCount - 1) else {
                throw AutomaticMeasurementError.invalidGeometry
            }
            guard points.count + vertices.vectorCount <= ObjectSelectionIndex.maximumPoints else { throw ObjectSelectionError.tooLarge }
            let start = points.count
            try vertices.data.withUnsafeBytes { bytes in
                for i in 0..<vertices.vectorCount {
                    if i % 4096 == 0, cancelled() { throw ObjectSelectionError.cancelled }
                    let offset = vertices.dataOffset + i * vertices.dataStride
                    let p = SIMD4<Float>(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self),
                        bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self), bytes.loadUnaligned(fromByteOffset: offset + 8, as: Float.self), 1)
                    let world = source.transform * p; points.append(SIMD3(world.x, world.y, world.z))
                }
            }
            for element in source.geometry.elements {
                guard element.primitiveType == .triangles || element.primitiveType == .point else { throw AutomaticMeasurementError.invalidGeometry }
                guard element.primitiveType == .triangles else { continue }
                let count = element.primitiveCount, bytesPerIndex = element.bytesPerIndex
                guard count >= 0, count <= ObjectSelectionIndex.maximumTriangles - triangles.count else { throw ObjectSelectionError.tooLarge }
                guard [1, 2, 4].contains(bytesPerIndex), count <= element.data.count / (3 * bytesPerIndex) else { throw AutomaticMeasurementError.invalidGeometry }
                try element.data.withUnsafeBytes { bytes in
                    func index(_ i: Int) -> UInt32 {
                        let offset = i * bytesPerIndex
                        if bytesPerIndex == 1 { return UInt32(bytes.loadUnaligned(fromByteOffset: offset, as: UInt8.self)) }
                        if bytesPerIndex == 2 { return UInt32(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
                        return bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                    }
                    for i in 0..<count {
                        if i % 4096 == 0, cancelled() { throw ObjectSelectionError.cancelled }
                        let t = SIMD3(index(i * 3), index(i * 3 + 1), index(i * 3 + 2))
                        guard max(t.x, max(t.y, t.z)) < UInt32(vertices.vectorCount) else { throw AutomaticMeasurementError.invalidGeometry }
                        triangles.append(t &+ SIMD3<UInt32>(repeating: UInt32(start)))
                    }
                }
            }
        }
        return Geometry(points: points, triangles: triangles)
    }

    static func highlight(index: ObjectSelectionIndex, selection: AutomaticRegionSelection) throws -> SCNNode {
        try index.validate(selection)
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [UInt32] = []
        for id in selection.ids {
            for vertex in index.vertexIDs(id) {
                let p = index.points[vertex], n = index.kind == .triangles ? index.normals[id] : SIMD3<Float>(0, 1, 0)
                indices.append(UInt32(vertices.count)); vertices.append(SCNVector3(p.x, p.y, p.z)); normals.append(SCNVector3(n.x, n.y, n.z))
            }
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: selection.kind == .triangles ? .triangles : .point)
        element.pointSize = 7; element.minimumPointScreenSpaceRadius = 3; element.maximumPointScreenSpaceRadius = 5
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemMint.withAlphaComponent(0.42)
        material.emission.contents = UIColor.systemMint.withAlphaComponent(0.12)
        material.lightingModel = .constant; material.isDoubleSided = true
        material.writesToDepthBuffer = false; material.readsFromDepthBuffer = true
        // A tiny clip-space offset avoids coplanar flicker without showing
        // selected back surfaces through an opaque foreground model.
        material.shaderModifiers = [.geometry: "#pragma body\n_geometry.position.xyz += _geometry.normal * 0.001;"]
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry); node.name = "objectSelection"; node.renderingOrder = 20
        return node
    }
}
