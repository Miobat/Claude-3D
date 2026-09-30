import Foundation
import simd

/// Exact source IDs, tied to the enclosing document's model revision. Packing
/// avoids huge JSON arrays and lets reopening highlight only reviewed surfaces.
struct AutomaticRegionSelection: Codable, Equatable {
    enum Kind: String, Codable { case triangles, points }
    var kind: Kind
    var packedIDs: Data

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
        guard zip(values, values.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw AutomaticMeasurementError.invalidDocument
        }
    }

    var ids: [Int] {
        packedIDs.withUnsafeBytes { bytes in
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
        case .structuralSurface: return "That surface looks like a floor, ceiling or large wall. Tap the object itself, or use Add to include it deliberately."
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
    private let welded: [Int]
    private let incidents: [[Int]]
    private let cells: [SIMD3<Int32>: [Int]]
    private let pointCell: Float = 0.04
    var kind: AutomaticRegionSelection.Kind { triangles.isEmpty ? .points : .triangles }

    init(points: [SIMD3<Float>], triangles: [SIMD3<UInt32>], labels: Data? = nil,
         cancelled: () -> Bool = { false }) throws {
        guard points.count <= Self.maximumPoints, triangles.count <= Self.maximumTriangles else { throw ObjectSelectionError.tooLarge }
        guard !points.isEmpty, points.allSatisfy(Self.finite),
              triangles.allSatisfy({ Int(max($0.x, max($0.y, $0.z))) < points.count }),
              labels == nil || labels?.count == triangles.count else { throw AutomaticMeasurementError.invalidGeometry }
        self.points = points; self.triangles = triangles
        var weldMap: [SIMD3<Int32>: [Int]] = [:], representatives: [SIMD3<Float>] = [], remap: [Int] = []
        var buckets: [SIMD3<Int32>: [Int]] = [:]
        for (i, p) in points.enumerated() {
            if i % 4096 == 0, cancelled() { throw ObjectSelectionError.cancelled }
            // Neighbor buckets avoid seams caused by a quantization boundary.
            let key = Self.cell(p, size: 0.006)
            var match: Int?
            for z in -1...1 { for y in -1...1 { for x in -1...1 where match == nil {
                for id in weldMap[key &+ SIMD3(Int32(x), Int32(y), Int32(z))] ?? [] {
                    if simd_distance_squared(representatives[id], p) <= 0.006 * 0.006 { match = id; break }
                }
            } } }
            if let match { remap.append(match) }
            else { remap.append(representatives.count); weldMap[key, default: []].append(representatives.count); representatives.append(p) }
            buckets[Self.cell(p, size: 0.04), default: []].append(i)
        }
        welded = remap; cells = buckets
        var incident = [[Int]](repeating: [], count: representatives.count)
        var faceNormals: [SIMD3<Float>] = []
        struct PlaneKey: Hashable { let normal: SIMD3<Int32>; let offset: Int32 }
        struct Plane { var area: Float = 0; var wallArea: Float = 0; var ids: [Int] = []; var low: SIMD3<Float>; var high: SIMD3<Float> }
        var planes: [PlaneKey: Plane] = [:], rejected = Set<Int>()
        for (i, t) in triangles.enumerated() {
            if i % 4096 == 0, cancelled() { throw ObjectSelectionError.cancelled }
            let a = points[Int(t.x)], b = points[Int(t.y)], c = points[Int(t.z)]
            let cross = simd_cross(b - a, c - a), length = simd_length(cross)
            let n = length > 1e-9 ? cross / length : .zero
            faceNormals.append(n)
            for v in Set([remap[Int(t.x)], remap[Int(t.y)], remap[Int(t.z)]]) { incident[v].append(i) }
            let category = labels.flatMap { SurfaceCategory(rawValue: $0[$0.startIndex + i]) } ?? .unknown
            // A mislabeled vertical cabinet front cannot become a floor.
            if abs(n.y) > 0.85 && (category == .floor || category == .ceiling) { rejected.insert(i) }
            guard length > 1e-9 else { rejected.insert(i); continue }
            let dominant = abs(n.x) > abs(n.y) ? (abs(n.x) > abs(n.z) ? n.x : n.z) : (abs(n.y) > abs(n.z) ? n.y : n.z)
            let canonical = dominant < 0 ? -n : n
            let k = PlaneKey(normal: SIMD3(Int32((canonical.x * 12).rounded()), Int32((canonical.y * 12).rounded()), Int32((canonical.z * 12).rounded())),
                             offset: Int32((simd_dot(canonical, a) / 0.04).rounded()))
            // Remove before appending: otherwise the dictionary retains the
            // array buffer and every coplanar triangle causes a full CoW copy.
            var plane = planes.removeValue(forKey: k) ?? Plane(low: a, high: a)
            plane.area += length * 0.5
            if category == .wall { plane.wallArea += length * 0.5 }
            plane.ids.append(i); plane.low = simd_min(plane.low, simd_min(a, simd_min(b, c)))
            plane.high = simd_max(plane.high, simd_max(a, simd_max(b, c)))
            planes[k] = plane
        }
        let minY = points.reduce(Float.greatestFiniteMagnitude) { min($0, $1.y) }
        for plane in planes.values {
            let extent = plane.high - plane.low
            let n = faceNormals[plane.ids[0]]
            let floor = abs(n.y) > 0.95 && plane.area > 1.5 && plane.high.y < minY + 0.04
            let wall = abs(n.y) < 0.2 && plane.area > 4 && max(extent.x, extent.z) > 2.5 &&
                (plane.wallArea / plane.area > 0.5 || extent.y > 2)
            if floor || wall { rejected.formUnion(plane.ids) }
        }
        incidents = incident; normals = faceNormals; structural = rejected
    }

    func nearest(to p: SIMD3<Float>, maximumDistance: Float = 0.12) -> Int? {
        // The caller supplies an actual rendered hit; this is not a ray picker.
        if triangles.isEmpty {
            return points.indices.min(by: { simd_distance_squared(points[$0], p) < simd_distance_squared(points[$1], p) })
                .flatMap { simd_distance(points[$0], p) <= maximumDistance ? $0 : nil }
        }
        var best: Int?, distance = maximumDistance * maximumDistance
        for i in triangles.indices {
            let d = simd_distance_squared(p, closestPoint(p, triangle: i))
            if d < distance { distance = d; best = i }
        }
        return best
    }

    struct Result { let selection: AutomaticRegionSelection; let touchesLimit: Bool }
    func grow(from seed: Int, radius: Float, cancelled: () -> Bool = { false }) throws -> Result {
        guard radius.isFinite, radius >= 0.1, radius <= 5,
              seed >= 0, seed < (triangles.isEmpty ? points.count : triangles.count) else { throw ObjectSelectionError.noSurface }
        guard !structural.contains(seed) else { throw ObjectSelectionError.structuralSurface }
        let origin = position(seed), r2 = radius * radius
        var visited = Set([seed]), queue = [seed], head = 0, selected: [Int] = [], clipped = false
        while head < queue.count {
            if head % 1024 == 0, cancelled() { throw ObjectSelectionError.cancelled }
            let id = queue[head]; head += 1
            guard !structural.contains(id) else { continue }
            let vertices = vertexIDs(id)
            guard vertices.allSatisfy({ simd_distance_squared(points[$0], origin) <= r2 }) else { clipped = true; continue }
            selected.append(id)
            guard selected.count <= Self.maximumSelection else { throw ObjectSelectionError.tooLarge }
            if triangles.isEmpty {
                let key = Self.cell(points[id], size: pointCell)
                for z in -1...1 { for y in -1...1 { for x in -1...1 {
                    for next in cells[key &+ SIMD3(Int32(x), Int32(y), Int32(z))] ?? []
                        where !visited.contains(next) && simd_distance_squared(points[next], points[id]) <= 0.045 * 0.045 {
                        visited.insert(next); queue.append(next)
                    }
                } } }
            } else {
                for vertex in vertices {
                    for next in incidents[welded[vertex]] where !visited.contains(next) {
                        visited.insert(next); queue.append(next)
                    }
                }
            }
        }
        guard !selected.isEmpty else { throw ObjectSelectionError.emptySelection }
        return Result(selection: try AutomaticRegionSelection(kind: kind, ids: selected), touchesLimit: clipped)
    }

    /// Paint corrections use real triangle distance, not just triangle centroids.
    /// Add deliberately bypasses structural rejection; the reviewed result is partial.
    func brush(_ selection: AutomaticRegionSelection?, at p: SIMD3<Float>, radius: Float, adding: Bool) throws -> AutomaticRegionSelection? {
        guard Self.finite(p), radius.isFinite, (0.005...0.5).contains(radius) else { throw AutomaticMeasurementError.invalidGeometry }
        if let selection { try validate(selection) }
        var ids = Set(selection?.ids ?? [])
        for i in 0..<(triangles.isEmpty ? points.count : triangles.count) {
            let q = triangles.isEmpty ? points[i] : closestPoint(p, triangle: i)
            if simd_distance_squared(q, p) <= radius * radius {
                if adding { ids.insert(i) } else { ids.remove(i) }
            }
        }
        return ids.isEmpty ? nil : try AutomaticRegionSelection(kind: kind, ids: Array(ids))
    }

    func validate(_ selection: AutomaticRegionSelection) throws {
        try selection.validate()
        guard selection.kind == kind, selection.ids.allSatisfy({ $0 < (triangles.isEmpty ? points.count : triangles.count) }) else {
            throw AutomaticMeasurementError.staleModel
        }
    }

    func region(selection: AutomaticRegionSelection, front: SIMD3<Float>, partial: Bool, name: String = "Object") throws -> AutomaticMeasuredRegion {
        try validate(selection)
        let vertices = Set(selection.ids.flatMap(vertexIDs)).sorted().map { points[$0] }
        let bounds = try UprightMeasurementBounds.fit(points: vertices, front: front)
        let dimensions = AutomaticDimension.Axis.allCases.enumerated().map { i, axis in
            let span = bounds.size[i]
            // Thin/noisy front-only capture is not a usable physical depth.
            let unavailable = span < (axis == .depth ? 0.02 : 0.001)
            return AutomaticDimension(axis: axis, metres: unavailable ? nil : span,
                evidence: unavailable ? .unavailable : (partial || triangles.isEmpty ? .partial : .observedSpan))
        }
        let result = AutomaticMeasuredRegion(name: name, kind: .object, bounds: bounds,
                                              dimensions: dimensions, selection: selection)
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
        for id in structural where id < normals.count && abs(normals[id].y) < 0.2 && abs(simd_dot(normals[id], bounds.front)) > 0.97 {
            let point = position(id)
            let depth = simd_dot(frontFace - point, bounds.front)
            guard depth > bounds.size.z + 0.01, depth <= bounds.size.z + 1.5 else { continue }
            let projected = frontFace - bounds.front * depth
            let wallPoint = closestPoint(projected, triangle: id)
            guard simd_distance(wallPoint, projected) < 0.15 else { continue }
            if candidate == nil || depth < candidate!.metres { candidate = WallDepthCandidate(metres: depth, wallPoint: projected) }
        }
        return candidate
    }

    func assumingWallContact(_ region: AutomaticMeasuredRegion, confirmed: Bool) throws -> AutomaticMeasuredRegion {
        guard confirmed else { throw AutomaticMeasurementError.unconfirmedWall }
        guard let candidate = wallDepth(for: region) else { throw AutomaticMeasurementError.invalidGeometry }
        var result = region
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
        let t = triangles[id], a = points[Int(t.x)], b = points[Int(t.y)], c = points[Int(t.z)]
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }
        let bp = p - b, d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return a + ab * (d1 / max(d1 - d3, 1e-12)) }
        let cp = p - c, d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return a + ac * (d2 / max(d2 - d6, 1e-12)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0 { return b + (c - b) * ((d4 - d3) / max((d4 - d3) + (d5 - d6), 1e-12)) }
        let sum = va + vb + vc
        guard abs(sum) > 1e-12 else { return a }
        return a + ab * (vb / sum) + ac * (vc / sum)
    }
}
