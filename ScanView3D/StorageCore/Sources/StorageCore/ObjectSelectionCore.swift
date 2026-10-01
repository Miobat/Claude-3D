import Foundation
import simd
import CryptoKit

/// Exact source IDs, tied to the enclosing document's model revision. Packing
/// avoids huge JSON arrays and lets reopening highlight only reviewed surfaces.
struct AutomaticRegionSelection: Codable, Equatable {
    enum Kind: String, Codable { case triangles, points }
    var kind: Kind
    var packedIDs: Data
    var geometrySHA256: String? = nil

    init(kind: Kind, ids: [Int]) throws {
        guard ids.count <= ObjectSelectionIndex.maximumSelection,
              ids.allSatisfy({ $0 >= 0 && $0 <= Int(UInt32.max) }) else { throw ObjectSelectionError.tooLarge }
        self.kind = kind
        packedIDs = Data()
        for id in Set(ids).sorted() {
            var value = UInt32(id).littleEndian
            withUnsafeBytes(of: &value) { packedIDs.append(contentsOf: $0) }
        }
        try validate()
    }

    func validate() throws {
        guard !packedIDs.isEmpty, packedIDs.count % 4 == 0,
              packedIDs.count / 4 <= ObjectSelectionIndex.maximumSelection else {
            throw AutomaticMeasurementError.invalidDocument
        }
        let values = ids
        guard geometrySHA256.map(MeasurementModelRevision.validHash) ?? true else { throw AutomaticMeasurementError.invalidDocument }
        guard zip(values, values.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw AutomaticMeasurementError.invalidDocument
        }
    }

    var ids: [Int] {
        guard packedIDs.count % 4 == 0, packedIDs.count / 4 <= ObjectSelectionIndex.maximumSelection else { return [] }
        return packedIDs.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map {
                Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
            }
        }
    }
}

enum ObjectSelectionError: LocalizedError {
    case tooLarge, noSurface, structuralSurface, emptySelection, cancelled
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "This geometry exceeds the Object tool's safe working limit. Use a smaller scan or manual measurement; no geometry was silently discarded."
        case .noSurface: return "Tap a scanned surface on the object."
        case .structuralSurface: return "The scan does not separate this surface from the wall or floor. Try a captured side or edge, or paint with Add. Missing object geometry cannot be measured automatically."
        case .emptySelection: return "The selection is empty. Tap an object to start again."
        case .cancelled: return "Selection cancelled."
        }
    }
}

/// Bounded geometry-only region growing. Semantic labels are hints corroborated
/// by normals/plane extent, never individual-object identities. Work off-main.
final class ObjectSelectionIndex {
    static let maximumPoints = 500_000
    static let maximumTriangles = 300_000
    static let maximumSelection = 100_000
    let points: [SIMD3<Float>]
    let triangles: [SIMD3<UInt32>]
    let normals: [SIMD3<Float>]
    let structural: Set<Int>
    let supportPlanes: [ObjectSupportPlane]
    let geometrySHA256: String
    private let meshComponents: [Int]
    private let componentGaps: [Bool]
    private let cells: [SIMD3<Int32>: [Int]]
    private let connectionDistance: Float
    private let proximity: ObjectTriangleProximity
    var kind: AutomaticRegionSelection.Kind { triangles.isEmpty ? .points : .triangles }

    init(points: [SIMD3<Float>], triangles: [SIMD3<UInt32>], labels: Data? = nil,
         cancelled: () -> Bool = { false }) throws {
        guard points.count <= Self.maximumPoints, triangles.count <= Self.maximumTriangles else { throw ObjectSelectionError.tooLarge }
        guard !points.isEmpty, points.allSatisfy(Self.finite),
              triangles.allSatisfy({ Int(max($0.x, max($0.y, $0.z))) < points.count }),
              labels == nil || labels?.count == triangles.count else { throw AutomaticMeasurementError.invalidGeometry }
        self.points = points; self.triangles = triangles
        // Bind IDs to the geometry actually opened, including source ordering
        // and world transform. A .scn → OBJ fallback must not reuse a different
        // native topology merely because both files still have the same hashes.
        var digest = SHA256()
        var buffer = Data(capacity: 65_536)
        func word(_ value: UInt32) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { buffer.append(contentsOf: $0) }
            if buffer.count >= 65_536 { digest.update(data: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        word(UInt32(points.count)); word(UInt32(triangles.count))
        for (i, p) in points.enumerated() {
            if i % 4096 == 0, cancelled() { throw ObjectSelectionError.cancelled }
            word(p.x.bitPattern); word(p.y.bitPattern); word(p.z.bitPattern)
        }
        for t in triangles { word(t.x); word(t.y); word(t.z) }
        digest.update(data: buffer)
        geometrySHA256 = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let cellSize: Float = triangles.isEmpty ? 0.08 : 0.02
        var weldMap: [SIMD3<Int32>: [Int]] = [:], representatives: [SIMD3<Float>] = [], remap: [Int] = []
        var buckets: [SIMD3<Int32>: [Int]] = [:]
        for (i, p) in points.enumerated() {
            if i % 4096 == 0, cancelled() { throw ObjectSelectionError.cancelled }
            if triangles.isEmpty {
                buckets[Self.cell(p, size: cellSize), default: []].append(i)
                continue
            }
            // Neighbor buckets avoid seams caused by a quantization boundary.
            let key = Self.cell(p, size: 0.006)
            var match: Int?
            for z in -1...1 { for y in -1...1 { for x in -1...1 where match == nil {
                for id in weldMap[key &+ SIMD3(Int32(x), Int32(y), Int32(z))] ?? [] {
                    if simd_distance_squared(representatives[id], p) <= 0.006 * 0.006 { match = id; break }
                }
            } } }
            if let match { remap.append(match) }
            else {
                remap.append(representatives.count); weldMap[key, default: []].append(representatives.count); representatives.append(p)
            }
        }
        cells = buckets
        if triangles.isEmpty {
            var spacings: [Float] = []
            for i in stride(from: 0, to: points.count, by: max(1, points.count / 768)) {
                if cancelled() { throw ObjectSelectionError.cancelled }
                let p = points[i], key = Self.cell(p, size: cellSize)
                var nearest: Float = cellSize * cellSize
                for z in -1...1 { for y in -1...1 { for x in -1...1 {
                    for j in buckets[key &+ SIMD3(Int32(x), Int32(y), Int32(z))] ?? [] where j != i {
                        let d = simd_distance_squared(p, points[j])
                        if d > 0.000001 { nearest = min(nearest, d) }
                    }
                } } }
                if nearest < cellSize * cellSize { spacings.append(sqrt(nearest)) }
            }
            spacings.sort()
            connectionDistance = spacings.isEmpty ? 0.045 : min(0.075, max(0.012, spacings[spacings.count / 2] * 1.8))
        } else { connectionDistance = cellSize }
        var incident = [[Int]](repeating: [], count: representatives.count)
        var faceNormals: [SIMD3<Float>] = []
        var rejected = Set<Int>()
        for (i, t) in triangles.enumerated() {
            if i % 4096 == 0, cancelled() { throw ObjectSelectionError.cancelled }
            let a = points[Int(t.x)], b = points[Int(t.y)], c = points[Int(t.z)]
            let cross = simd_cross(b - a, c - a), length = simd_length(cross)
            let n = length > 1e-9 ? cross / length : .zero
            faceNormals.append(n)
            for v in Set([remap[Int(t.x)], remap[Int(t.y)], remap[Int(t.z)]]) { incident[v].append(i) }
            if length <= 1e-9 { rejected.insert(i) }
        }
        let supports = try ObjectSupportSurfaces.detect(points: points, triangles: triangles, normals: faceNormals, labels: labels, cancelled: cancelled)
        supportPlanes = supports
        if triangles.isEmpty {
            for (id, p) in points.enumerated() {
                if id % 4096 == 0, cancelled() { throw ObjectSelectionError.cancelled }
                if supports.contains(where: { abs($0.distance(p)) <= $0.tolerance && $0.containsProjection(p) }) { rejected.insert(id) }
            }
        } else {
            for (id, t) in triangles.enumerated() {
                if id % 4096 == 0, cancelled() { throw ObjectSelectionError.cancelled }
                let a = points[Int(t.x)], b = points[Int(t.y)], c = points[Int(t.z)], center = (a + b + c) / 3
                for plane in supports where plane.containsProjection(center) {
                    // Keep upright sides down to their contact edge. Only the
                    // coplanar background face stops growing at that edge.
                    let distances = [abs(plane.distance(a)), abs(plane.distance(b)), abs(plane.distance(c))]
                    if abs(plane.distance(center)) <= plane.tolerance &&
                        distances.max()! <= plane.tolerance * 1.5 && abs(simd_dot(plane.normal, faceNormals[id])) > 0.5 {
                        rejected.insert(id); break
                    }
                }
            }
        }
        normals = faceNormals; structural = rejected
        var parents = Array(triangles.indices), sizes = Array(repeating: 1, count: triangles.count)
        var gaps = Array(repeating: false, count: triangles.count)
        func root(_ id: Int) -> Int {
            var node = id
            while parents[node] != node { parents[node] = parents[parents[node]]; node = parents[node] }
            return node
        }
        func join(_ a: Int, _ b: Int, gap: Bool = false) {
            var a = root(a), b = root(b)
            guard a != b else { return }
            if sizes[a] < sizes[b] { swap(&a, &b) }
            parents[b] = a; sizes[a] += sizes[b]; gaps[a] = gaps[a] || gaps[b] || gap
        }
        for (i, faces) in incident.enumerated() {
            if i % 4096 == 0, cancelled() { throw ObjectSelectionError.cancelled }
            let kept = faces.filter { !rejected.contains($0) }
            if let first = kept.first { for other in kept.dropFirst() { join(first, other) } }
        }
        let topology = triangles.indices.map { rejected.contains($0) ? -1 : root($0) }
        let tree = try ObjectTriangleProximity(points: points, triangles: triangles, components: topology, cancelled: cancelled)
        // A longer bridge is allowed only off the END of a thin, elongated
        // component (e.g. a broken lamp stem). It never joins through a wall,
        // or laterally across the gap between two bulky neighboring objects.
        var lows: [Int: SIMD3<Float>] = [:], highs: [Int: SIMD3<Float>] = [:]
        for (id, t) in triangles.enumerated() where topology[id] >= 0 {
            let component = topology[id]
            for v in [t.x, t.y, t.z] {
                let p = points[Int(v)]
                lows[component] = simd_min(lows[component] ?? p, p)
                highs[component] = simd_max(highs[component] ?? p, p)
            }
        }
        func continuesThinPart(_ component: Int, toward q: SIMD3<Float>) -> Bool {
            guard let lo = lows[component], let hi = highs[component] else { return false }
            let size = hi - lo, axis = (0..<3).max { size[$0] < size[$1] }!
            let u = (axis + 1) % 3, v = (axis + 2) % 3
            guard size[axis] >= 0.12, max(size[u], size[v]) <= 0.065,
                  size[axis] > 3 * max(size[u], size[v]) else { return false }
            let centre = (hi + lo) * 0.5
            return (q[axis] < lo[axis] || q[axis] > hi[axis]) &&
                abs(q[u] - centre[u]) <= max(0.015, size[u] * 0.75) &&
                abs(q[v] - centre[v]) <= max(0.015, size[v] * 0.75)
        }
        var checked = Set<Int>()
        if !triangles.isEmpty {
            for vertex in points.indices where checked.insert(remap[vertex]).inserted {
                if vertex % 1024 == 0, cancelled() { throw ObjectSelectionError.cancelled }
                guard let face = incident[remap[vertex]].first(where: { !rejected.contains($0) }) else { continue }
                for other in tree.nearby(points[vertex], radius: 0.06, excludingComponent: topology[face])
                    where !rejected.contains(other) {
                    let q = tree.closest(points[vertex], triangle: other)
                    let distance = simd_distance_squared(points[vertex], q)
                    guard distance <= connectionDistance * connectionDistance ||
                        continuesThinPart(topology[face], toward: q) ||
                        continuesThinPart(topology[other], toward: points[vertex]) else { continue }
                    join(face, other, gap: distance > 0.006 * 0.006)
                }
            }
        }
        meshComponents = triangles.indices.map { rejected.contains($0) ? -1 : root($0) }
        componentGaps = triangles.indices.map { gaps[root($0)] }
        proximity = tree
    }

    func nearest(to p: SIMD3<Float>, maximumDistance: Float = 0.12) -> Int? {
        // The caller supplies an actual rendered hit; this is not a ray picker.
        if triangles.isEmpty {
            return points.indices.min(by: { simd_distance_squared(points[$0], p) < simd_distance_squared(points[$1], p) })
                .flatMap { simd_distance(points[$0], p) <= maximumDistance ? $0 : nil }
        }
        var best: Int?, distance = maximumDistance * maximumDistance
        for i in proximity.nearby(p, radius: maximumDistance) {
            let d = simd_distance_squared(p, closestPoint(p, triangle: i))
            if d < distance { distance = d; best = i }
        }
        return best
    }

    struct Result { let selection: AutomaticRegionSelection; let touchesLimit: Bool; var bridgedGap = false }
    func grow(from seed: Int, radius: Float? = nil, cancelled: () -> Bool = { false }) throws -> Result {
        guard radius.map({ $0.isFinite && $0 >= 0.1 && $0 <= 5 }) ?? true,
              seed >= 0, seed < (triangles.isEmpty ? points.count : triangles.count) else { throw ObjectSelectionError.noSurface }
        guard !structural.contains(seed) else { throw ObjectSelectionError.structuralSurface }
        let origin = position(seed), r2 = radius.map { $0 * $0 }
        if !triangles.isEmpty {
            var ids: [Int] = [], clipped = false
            for id in triangles.indices {
                if id % 1024 == 0, cancelled() { throw ObjectSelectionError.cancelled }
                guard meshComponents[id] == meshComponents[seed] else { continue }
                if let r2, !vertexIDs(id).allSatisfy({ simd_distance_squared(points[$0], origin) <= r2 }) { clipped = true; continue }
                ids.append(id)
                guard ids.count <= Self.maximumSelection else { throw ObjectSelectionError.tooLarge }
            }
            guard !ids.isEmpty else { throw ObjectSelectionError.emptySelection }
            return Result(selection: try identifiedSelection(ids), touchesLimit: clipped, bridgedGap: componentGaps[seed])
        }
        let cellSize: Float = 0.08
        var visited = Set([seed]), queue = [seed], head = 0, selected: [Int] = [], clipped = false
        // Remove discovered cloud points from search buckets. Dense repeated
        // observations must not cause quadratic neighbor scans.
        var remainingCells = cells
        while head < queue.count {
            if head % 1024 == 0, cancelled() { throw ObjectSelectionError.cancelled }
            let id = queue[head]; head += 1
            guard !structural.contains(id) else { continue }
            let vertices = vertexIDs(id)
            if let r2, !vertices.allSatisfy({ simd_distance_squared(points[$0], origin) <= r2 }) { clipped = true; continue }
            selected.append(id)
            guard selected.count <= Self.maximumSelection else { throw ObjectSelectionError.tooLarge }
            let key = Self.cell(points[id], size: cellSize)
            for z in -1...1 { for y in -1...1 { for x in -1...1 {
                    let neighborKey = key &+ SIMD3(Int32(x), Int32(y), Int32(z))
                    guard let pending = remainingCells.removeValue(forKey: neighborKey) else { continue }
                    var rest: [Int] = []
                    for next in pending where !visited.contains(next) && !structural.contains(next) {
                        if simd_distance_squared(points[next], points[id]) <= connectionDistance * connectionDistance {
                            visited.insert(next); queue.append(next)
                        } else { rest.append(next) }
                    }
                    if !rest.isEmpty { remainingCells[neighborKey] = rest }
            } } }
        }
        guard !selected.isEmpty else { throw ObjectSelectionError.emptySelection }
        return Result(selection: try identifiedSelection(selected), touchesLimit: clipped)
    }

    /// Paint corrections use real triangle distance, not just triangle centroids.
    /// Add deliberately bypasses structural rejection; the reviewed result is partial.
    func brush(_ selection: AutomaticRegionSelection?, at p: SIMD3<Float>, radius: Float, adding: Bool) throws -> AutomaticRegionSelection? {
        guard Self.finite(p), radius.isFinite, (0.005...0.5).contains(radius) else { throw AutomaticMeasurementError.invalidGeometry }
        if let selection { try validate(selection) }
        var ids = Set(selection?.ids ?? [])
        let candidates = triangles.isEmpty ? Array(points.indices) : proximity.nearby(p, radius: radius)
        for i in candidates {
            let q = triangles.isEmpty ? points[i] : closestPoint(p, triangle: i)
            if simd_distance_squared(q, p) <= radius * radius {
                if adding { ids.insert(i) } else { ids.remove(i) }
            }
        }
        return ids.isEmpty ? nil : try identifiedSelection(Array(ids))
    }

    func addingPart(_ part: AutomaticRegionSelection, to selection: AutomaticRegionSelection?) throws -> AutomaticRegionSelection {
        try validate(part)
        if let selection { try validate(selection) }
        return try identifiedSelection(Array(Set((selection?.ids ?? []) + part.ids)))
    }

    func validate(_ selection: AutomaticRegionSelection) throws {
        try selection.validate()
        guard selection.kind == kind, selection.geometrySHA256 == geometrySHA256,
              selection.ids.allSatisfy({ $0 < (triangles.isEmpty ? points.count : triangles.count) }) else {
            throw AutomaticMeasurementError.staleModel
        }
    }

    private func identifiedSelection(_ ids: [Int]) throws -> AutomaticRegionSelection {
        var result = try AutomaticRegionSelection(kind: kind, ids: ids)
        result.geometrySHA256 = geometrySHA256
        return result
    }

    func region(selection: AutomaticRegionSelection, front: SIMD3<Float>, partial: Bool, name: String = "Object", automaticOrientation: Bool = false) throws -> AutomaticMeasuredRegion {
        try validate(selection)
        let vertices = Set(selection.ids.flatMap(vertexIDs)).sorted().map { points[$0] }
        let direction = automaticOrientation ? ObjectFootprint.front(points: vertices, preferred: front) : front
        let bounds = try UprightMeasurementBounds.fit(points: vertices, front: direction)
        let dimensions = AutomaticDimension.Axis.allCases.enumerated().map { i, axis in
            let span = bounds.size[i]
            // Thin/noisy front-only capture is not a usable physical depth.
            let unavailable = span < (axis == .depth ? 0.02 : 0.001)
            return AutomaticDimension(axis: axis, metres: unavailable ? nil : span,
                evidence: unavailable ? .unavailable : (partial || triangles.isEmpty ? .partial : .observedSpan))
        }
        var result = AutomaticMeasuredRegion(name: name, kind: .object, bounds: bounds,
                                              dimensions: dimensions, selection: selection)
        if let wall = wallDepth(for: result) {
            result.wallProjection = AutomaticMeasuredRegion.WallProjection(metres: wall.metres, wallPoint: wall.wallPoint)
        }
        try result.validate(); return result
    }

    func position(_ id: Int) -> SIMD3<Float> {
        let vertices = vertexIDs(id)
        return vertices.reduce(SIMD3<Float>.zero) { $0 + points[$1] } / Float(vertices.count)
    }

    struct WallDepthCandidate: Equatable { let metres: Float; let wallPoint: SIMD3<Float> }

    /// A real, geometrically supported large wall behind the selected object.
    /// This is ONLY a front-to-wall span; contact cannot be inferred from it.
    func wallDepth(for region: AutomaticMeasuredRegion) -> WallDepthCandidate? {
        let bounds = region.bounds, frontFace = bounds.center + bounds.front * bounds.size.z * 0.5
        var candidate: WallDepthCandidate?
        for plane in supportPlanes where plane.kind == .wall && abs(simd_dot(plane.normal, bounds.front)) > 0.97 {
            let depth = plane.distance(frontFace) / simd_dot(plane.normal, bounds.front)
            guard depth > bounds.size.z + 0.01, depth <= bounds.size.z + 1.5 else { continue }
            let projected = frontFace - bounds.front * depth
            guard plane.containsProjection(projected),
                  plane.containsProjection(projected + bounds.right * bounds.size.x * 0.5),
                  plane.containsProjection(projected - bounds.right * bounds.size.x * 0.5) else { continue }
            if candidate == nil || depth < candidate!.metres { candidate = WallDepthCandidate(metres: depth, wallPoint: projected) }
        }
        return candidate
    }

    func assumingWallContact(_ region: AutomaticMeasuredRegion, confirmed: Bool) throws -> AutomaticMeasuredRegion {
        guard confirmed else { throw AutomaticMeasurementError.unconfirmedWall }
        guard let candidate = wallDepth(for: region) else { throw AutomaticMeasurementError.invalidGeometry }
        var result = region
        result.wallProjection = nil
        let extensionDepth = candidate.metres - result.bounds.size.z
        result.bounds.center -= result.bounds.front * extensionDepth * 0.5
        result.bounds.size.z = candidate.metres
        guard let i = result.dimensions.firstIndex(where: { $0.axis == .depth }) else { throw AutomaticMeasurementError.invalidDocument }
        result.dimensions[i] = AutomaticDimension(axis: .depth, metres: candidate.metres,
                                                  evidence: .assumedFlushToWall, wallContactConfirmed: true)
        try result.validate(); return result
    }
    func vertexIDs(_ id: Int) -> [Int] {
        guard !triangles.isEmpty else { return [id] }
        let t = triangles[id]; return [Int(t.x), Int(t.y), Int(t.z)]
    }
    private static func finite(_ p: SIMD3<Float>) -> Bool {
        p.x.isFinite && p.y.isFinite && p.z.isFinite && max(abs(p.x), max(abs(p.y), abs(p.z))) < 100_000
    }
    private static func cell(_ p: SIMD3<Float>, size: Float) -> SIMD3<Int32> {
        SIMD3(Int32(floor(p.x / size)), Int32(floor(p.y / size)), Int32(floor(p.z / size)))
    }

    // Ericson's closest-point triangle regions; handles zero-area faces too.
    private func closestPoint(_ p: SIMD3<Float>, triangle id: Int) -> SIMD3<Float> {
        proximity.closest(p, triangle: id)
    }
}
