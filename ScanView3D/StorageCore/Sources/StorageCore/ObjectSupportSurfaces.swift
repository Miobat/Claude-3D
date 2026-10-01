import Foundation
import simd

/// A plane supported by a broad patch of the scan. Extents limit its influence:
/// a wall in another room must not exclude every point on its infinite plane.
struct ObjectSupportPlane {
    enum Kind { case floor, wall, ceiling }
    let kind: Kind
    let normal: SIMD3<Float>
    let offset: Float
    let tolerance: Float
    let u: SIMD3<Float>
    let v: SIMD3<Float>
    let low: SIMD2<Float>
    let high: SIMD2<Float>

    func distance(_ p: SIMD3<Float>) -> Float { simd_dot(p, normal) - offset }
    func containsProjection(_ p: SIMD3<Float>, margin: Float = 0.08) -> Bool {
        let q = SIMD2(simd_dot(p, u), simd_dot(p, v))
        return q.x >= low.x - margin && q.x <= high.x + margin &&
            q.y >= low.y - margin && q.y <= high.y + margin
    }
}

/// Robust support fitting shared by mesh and point-cloud selection. Sampling is
/// only for finding planes; segmentation and dimensions retain full source IDs.
enum ObjectSupportSurfaces {
    private struct Sample {
        let a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>
        let normal: SIMD3<Float>
        let weight: Float
        var floorHint: Bool = false
        var center: SIMD3<Float> { (a + b + c) / 3 }
    }
    private struct Fit {
        let normal: SIMD3<Float>, offset: Float, tolerance: Float
        let u: SIMD3<Float>, v: SIMD3<Float>
        let low: SIMD2<Float>, high: SIMD2<Float>
        let area: Float
        let floorFraction: Float
        var horizontal: Bool { abs(normal.y) > 0.94 }
        var height: Float { offset / normal.y }
    }

    static func detect(points: [SIMD3<Float>], triangles: [SIMD3<UInt32>], normals: [SIMD3<Float>],
                       labels: Data? = nil, cancelled: () -> Bool) throws -> [ObjectSupportPlane] {
        let cloud = triangles.isEmpty
        var samples: [Sample] = []
        if cloud {
            // Spatial occupancy prevents a densely scanned chair face from
            // outweighing an entire sparsely scanned floor.
            var occupied = Set<SIMD3<Int32>>()
            var representatives: [SIMD3<Float>] = []
            for (i, p) in points.enumerated() {
                if i % 4096 == 0, cancelled() { throw ObjectSelectionError.cancelled }
                let key = SIMD3<Int32>(Int32(floor(p.x / 0.05)), Int32(floor(p.y / 0.05)), Int32(floor(p.z / 0.05)))
                if occupied.insert(key).inserted { representatives.append(p) }
            }
            let step = max(1, (representatives.count + 11_999) / 12_000)
            for i in stride(from: 0, to: representatives.count, by: step) {
                let p = representatives[i]
                samples.append(Sample(a: p, b: p, c: p, normal: .zero, weight: 1))
            }
        } else {
            let step = max(1, (triangles.count + 9_999) / 10_000)
            // Always retain the largest faces as well: two large floor triangles
            // can otherwise fall between samples in a finely meshed object.
            var largest: [(Int, Float)] = []
            for (i, t) in triangles.enumerated() {
                if i % 4096 == 0, cancelled() { throw ObjectSelectionError.cancelled }
                let area = simd_length(simd_cross(points[Int(t.y)] - points[Int(t.x)], points[Int(t.z)] - points[Int(t.x)])) * 0.5
                if largest.count < 24 || area > largest.last!.1 {
                    largest.append((i, area)); largest.sort { $0.1 > $1.1 }
                    if largest.count > 24 { largest.removeLast() }
                }
            }
            let forced = Set(largest.map { $0.0 })
            let ids = Set(stride(from: 0, to: triangles.count, by: step)).union(forced).sorted()
            for i in ids where simd_length_squared(normals[i]) > 0.5 {
                let t = triangles[i], a = points[Int(t.x)], b = points[Int(t.y)], c = points[Int(t.z)]
                let area = simd_length(simd_cross(b - a, c - a)) * 0.5
                samples.append(Sample(a: a, b: b, c: c, normal: normals[i], weight: area * Float(forced.contains(i) ? 1 : step),
                                      floorHint: labels.map { $0[$0.startIndex + i] == SurfaceCategory.floor.rawValue } ?? false))
            }
        }
        guard !samples.isEmpty else { return [] }
        var remaining = Array(samples.indices), fits: [Fit] = []
        var random: UInt64 = 0x52C9_713A_6F08_BD25
        func next(_ count: Int) -> Int {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return Int((random >> 32) % UInt64(count))
        }
        for _ in 0..<12 {
            if cancelled() { throw ObjectSelectionError.cancelled }
            guard remaining.count >= (cloud ? 12 : 1) else { break }
            var candidates: [(SIMD3<Float>, Float)] = []
            func propose(_ n: SIMD3<Float>, _ p: SIMD3<Float>) {
                guard simd_length_squared(n) > 0.5 else { return }
                let n = canonical(n)
                guard abs(n.y) > 0.94 || abs(n.y) < 0.18 else { return }
                let d = simd_dot(n, p)
                if !candidates.contains(where: { simd_dot($0.0, n) > 0.999 && abs($0.1 - d) < 0.012 }) {
                    candidates.append((n, d))
                }
            }
            let step = max(1, remaining.count / 96)
            for j in stride(from: 0, to: remaining.count, by: step) {
                let s = samples[remaining[j]]
                if !cloud { propose(s.normal, s.center) }
                propose(SIMD3(0, 1, 0), s.center)
            }
            for _ in 0..<160 {
                let a = samples[remaining[next(remaining.count)]].center
                let b = samples[remaining[next(remaining.count)]].center
                let c = samples[remaining[next(remaining.count)]].center
                let cross = simd_cross(b - a, c - a)
                if simd_length(cross) > 0.02 { propose(simd_normalize(cross), a) }
                let wall = SIMD3<Float>(b.z - a.z, 0, a.x - b.x)
                if simd_length(wall) > 0.2 { propose(simd_normalize(wall), a) }
            }
            func supports(_ s: Sample, _ n: SIMD3<Float>, _ d: Float, _ tolerance: Float) -> Bool {
                abs(simd_dot(s.center, n) - d) <= tolerance &&
                    (cloud || abs(simd_dot(s.normal, n)) > 0.75)
            }
            var best: (SIMD3<Float>, Float)?, bestScore: Float = 0
            for (j, candidate) in candidates.enumerated() {
                if j % 16 == 0, cancelled() { throw ObjectSelectionError.cancelled }
                var score: Float = 0
                for id in remaining where supports(samples[id], candidate.0, candidate.1, 0.025) { score += samples[id].weight }
                if score > bestScore { best = candidate; bestScore = score }
            }
            guard let best else { break }
            var inliers = remaining.filter { supports(samples[$0], best.0, best.1, 0.025) }
            guard inliers.count >= (cloud ? 12 : 1) else { break }
            let refined = fit(samples: samples, ids: inliers, fallback: best.0)
            let n = canonical(refined.0), d = simd_dot(n, refined.1)
            let residuals = inliers.map { abs(simd_dot(samples[$0].center, n) - d) }.sorted()
            let tolerance = min(Float(0.025), max(Float(0.012), residuals[residuals.count * 4 / 5] * 2))
            inliers = remaining.filter { supports(samples[$0], n, d, tolerance) }
            let used = Set(inliers)
            remaining.removeAll { used.contains($0) }
            guard inliers.count >= (cloud ? 12 : 1), abs(n.y) > 0.94 || abs(n.y) < 0.18 else { continue }
            let u = abs(n.y) > 0.94 ? simd_normalize(simd_cross(SIMD3<Float>(0, 0, 1), n)) : simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), n))
            let v = simd_cross(n, u)
            var low = SIMD2<Float>(repeating: .greatestFiniteMagnitude), high = -low, area: Float = 0
            var tiles = Set<SIMD2<Int32>>(), floorWeight: Float = 0
            for id in inliers {
                let s = samples[id]; area += s.weight
                if s.floorHint { floorWeight += s.weight }
                for p in [s.a, s.b, s.c] {
                    let q = SIMD2(simd_dot(p, u), simd_dot(p, v))
                    low = simd_min(low, q); high = simd_max(high, q)
                    if cloud { tiles.insert(SIMD2(Int32(floor(q.x / 0.15)), Int32(floor(q.y / 0.15)))) }
                }
            }
            if cloud { area = Float(tiles.count) * 0.15 * 0.15 }
            fits.append(Fit(normal: n, offset: d, tolerance: tolerance, u: u, v: v, low: low, high: high, area: area,
                            floorFraction: floorWeight / max(area, 0.001)))
        }
        // A broad lower horizontal plane is the floor, not the lowest stray
        // vertex. Furniture tops above it do not become support boundaries.
        let horizontal = fits.filter {
            let size = $0.high - $0.low
            let labelled = $0.floorFraction > 0.6
            return $0.horizontal && $0.area > (labelled ? 0.3 : 1.5) &&
                max(size.x, size.y) > (labelled ? 0.8 : 1.6) && min(size.x, size.y) > (labelled ? 0.4 : 0.7)
        }
        let floor = horizontal.min { $0.height < $1.height }
        var result: [ObjectSupportPlane] = []
        for f in fits {
            let size = f.high - f.low
            let kind: ObjectSupportPlane.Kind
            if let floor, f.horizontal, abs(f.height - floor.height) < 0.06 { kind = .floor }
            else if let floor, f.horizontal, f.height - floor.height > 2.1, f.area > 4 { kind = .ceiling }
            else if abs(f.normal.y) < 0.18, f.area > 4, size.x > 2.5, size.y > 2 { kind = .wall }
            else { continue }
            result.append(ObjectSupportPlane(kind: kind, normal: f.normal, offset: f.offset, tolerance: f.tolerance,
                                             u: f.u, v: f.v, low: f.low, high: f.high))
        }
        return result
    }

    private static func canonical(_ n: SIMD3<Float>) -> SIMD3<Float> {
        let dominant = abs(n.x) > abs(n.y) ? (abs(n.x) > abs(n.z) ? n.x : n.z) : (abs(n.y) > abs(n.z) ? n.y : n.z)
        return dominant < 0 ? -n : n
    }

    /// Weighted covariance and a small symmetric Jacobi eigensolve. Using all
    /// three corners also fits a floor represented by only one or two triangles.
    private static func fit(samples: [Sample], ids: [Int], fallback: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let origin = samples[ids[0]].center
        var mean = SIMD3<Double>.zero, total: Double = 0
        for id in ids {
            let s = samples[id], w = Double(s.weight)
            mean += SIMD3<Double>(s.center - origin) * w; total += w
        }
        guard total > 0 else { return (fallback, origin) }
        mean /= total
        var a = [Double](repeating: 0, count: 9), vectors: [Double] = [1,0,0, 0,1,0, 0,0,1]
        for id in ids {
            let s = samples[id], w = Double(s.weight) / 3
            for point in [s.a, s.b, s.c] {
                let p = SIMD3<Double>(point - origin) - mean
                for row in 0..<3 { for col in 0..<3 { a[row * 3 + col] += w * p[row] * p[col] } }
            }
        }
        for _ in 0..<24 {
            var p = 0, q = 1
            for (i, j) in [(0, 2), (1, 2)] where abs(a[i * 3 + j]) > abs(a[p * 3 + q]) { p = i; q = j }
            if abs(a[p * 3 + q]) < 1e-12 { break }
            let theta = 0.5 * atan2(2 * a[p * 3 + q], a[q * 3 + q] - a[p * 3 + p])
            let c = cos(theta), s = sin(theta)
            for k in 0..<3 {
                let x = a[k * 3 + p], y = a[k * 3 + q]
                a[k * 3 + p] = c * x - s * y; a[k * 3 + q] = s * x + c * y
            }
            for k in 0..<3 {
                let x = a[p * 3 + k], y = a[q * 3 + k]
                a[p * 3 + k] = c * x - s * y; a[q * 3 + k] = s * x + c * y
                let vx = vectors[k * 3 + p], vy = vectors[k * 3 + q]
                vectors[k * 3 + p] = c * vx - s * vy; vectors[k * 3 + q] = s * vx + c * vy
            }
        }
        let axis = (0..<3).min { a[$0 * 3 + $0] < a[$1 * 3 + $1] }!
        let n = SIMD3<Float>(Float(vectors[axis]), Float(vectors[3 + axis]), Float(vectors[6 + axis]))
        return (abs(simd_dot(n, fallback)) > 0.9 ? n : fallback, origin + SIMD3<Float>(mean))
    }
}

/// Minimum-area upright footprint; the camera only chooses which of the four
/// equivalent rectangle directions is called Front. Rotating calipers keep the
/// fit bounded even for a high-resolution round object.
enum ObjectFootprint {
    static func front(points: [SIMD3<Float>], preferred: SIMD3<Float>) -> SIMD3<Float> {
        guard let origin = points.first else { return preferred }
        let projected: [SIMD2<Float>] = points.map { p in SIMD2<Float>(p.x - origin.x, p.z - origin.z) }
        let unique = Set<SIMD2<Float>>(projected)
        let sorted: [SIMD2<Float>] = unique.sorted { a, b in
            a.x == b.x ? a.y < b.y : a.x < b.x
        }
        guard sorted.count > 1 else { return preferred }
        func turn(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
            let x = b - a, y = c - a; return x.x * y.y - x.y * y.x
        }
        var lower: [SIMD2<Float>] = [], upper: [SIMD2<Float>] = []
        for p in sorted {
            while lower.count > 1 && turn(lower[lower.count - 2], lower.last!, p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count > 1 && turn(upper[upper.count - 2], upper.last!, p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        lower.removeLast(); upper.removeLast()
        let hull = lower + upper
        guard hull.count > 1 else { return preferred }
        var supports = [Int](repeating: 0, count: 4)
        var bestArea = Float.greatestFiniteMagnitude, bestFront = preferred, bestAlignment: Float = -1
        for i in hull.indices {
            let edge = hull[(i + 1) % hull.count] - hull[i]
            guard simd_length_squared(edge) > 1e-12 else { continue }
            let r = simd_normalize(edge), f = SIMD2(-r.y, r.x)
            let axes = [r, -r, f, -f]
            for axis in 0..<4 {
                if i == 0 { supports[axis] = hull.indices.max { simd_dot(hull[$0], axes[axis]) < simd_dot(hull[$1], axes[axis]) }! }
                else {
                    for _ in hull.indices {
                        let next = (supports[axis] + 1) % hull.count
                        guard simd_dot(hull[next], axes[axis]) > simd_dot(hull[supports[axis]], axes[axis]) + 1e-7 else { break }
                        supports[axis] = next
                    }
                }
            }
            let width = simd_dot(hull[supports[0]] - hull[supports[1]], r)
            let depth = simd_dot(hull[supports[2]] - hull[supports[3]], f)
            let area = max(0, width) * max(0, depth)
            let directions = axes.map { SIMD3<Float>($0.x, 0, $0.y) }
            let front = directions.max { simd_dot($0, preferred) < simd_dot($1, preferred) }!
            let alignment = simd_dot(front, preferred)
            if area < bestArea - 1e-6 || (abs(area - bestArea) <= 1e-6 && alignment > bestAlignment) {
                bestArea = area; bestFront = front; bestAlignment = alignment
            }
        }
        return bestFront
    }
}

/// Surface-distance neighbors, including a chair leg meeting the interior of a
/// seat triangle. Vertex-only adjacency cannot find these reconstruction joins.
final class ObjectTriangleProximity {
    private struct Node {
        let low: SIMD3<Float>, high: SIMD3<Float>
        var left = -1, right = -1
        let start: Int, count: Int
        let component: Int?
    }
    private let points: [SIMD3<Float>], triangles: [SIMD3<UInt32>]
    private var order: [Int], nodes: [Node] = []

    init(points: [SIMD3<Float>], triangles: [SIMD3<UInt32>], components: [Int]? = nil, cancelled: () -> Bool) throws {
        self.points = points; self.triangles = triangles; order = Array(triangles.indices)
        guard !triangles.isEmpty else { return }
        func center(_ id: Int, axis: Int) -> Float {
            let t = triangles[id]; return (points[Int(t.x)][axis] + points[Int(t.y)][axis] + points[Int(t.z)][axis]) / 3
        }
        func build(_ start: Int, _ end: Int) throws -> Int {
            if cancelled() { throw ObjectSelectionError.cancelled }
            var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
            for i in start..<end {
                let t = triangles[order[i]]
                for id in [t.x, t.y, t.z] { low = simd_min(low, points[Int(id)]); high = simd_max(high, points[Int(id)]) }
            }
            let index = nodes.count
            let component = components.flatMap { ids -> Int? in
                let first = ids[order[start]]
                return (start..<end).allSatisfy { ids[order[$0]] == first } ? first : nil
            }
            nodes.append(Node(low: low, high: high, start: start, count: end - start, component: component))
            guard end - start > 16 else { return index }
            let size = high - low, axis = size.x >= size.y && size.x >= size.z ? 0 : (size.y >= size.z ? 1 : 2)
            let middle = (start + end) / 2
            var first = start, last = end - 1
            while first < last {
                let pivot = center(order[(first + last) / 2], axis: axis)
                var i = first, j = last
                while i <= j {
                    while i <= last && center(order[i], axis: axis) < pivot { i += 1 }
                    while j >= first && center(order[j], axis: axis) > pivot { j -= 1 }
                    if i <= j { order.swapAt(i, j); i += 1; j -= 1 }
                }
                if middle <= j { last = j }
                else if middle >= i { first = i }
                else { break }
            }
            let left = try build(start, middle), right = try build(middle, end)
            nodes[index].left = left; nodes[index].right = right
            return index
        }
        _ = try build(0, triangles.count)
    }

    func nearby(_ p: SIMD3<Float>, radius: Float, excludingComponent: Int? = nil) -> [Int] {
        guard !nodes.isEmpty else { return [] }
        var stack = [0], result: [Int] = []
        let squared = radius * radius
        while let id = stack.popLast() {
            let node = nodes[id], q = simd_min(node.high, simd_max(node.low, p))
            if let excluded = excludingComponent, node.component == excluded { continue }
            guard simd_distance_squared(p, q) <= squared else { continue }
            if node.left >= 0 { stack.append(node.left); stack.append(node.right) }
            else {
                for i in node.start..<(node.start + node.count) {
                    let face = order[i]
                    if simd_distance_squared(p, closest(p, triangle: face)) <= squared { result.append(face) }
                }
            }
        }
        return result
    }

    func closest(_ p: SIMD3<Float>, triangle id: Int) -> SIMD3<Float> {
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
