import Foundation
import SceneKit
import simd

// MARK: - Geometry maths (pure, no SceneKit)

struct FittedPlane {
    var normal: SIMD3<Float>     // unit length
    var point: SIMD3<Float>      // a point on the plane (the fit's centroid)
    var rms: Float               // fit residual (m)
    var inliers: Int

    var d: Float { simd_dot(normal, point) }
    func signedDistance(_ p: SIMD3<Float>) -> Float { simd_dot(normal, p) - d }
}

enum GeometryMath {

    /// Least-squares plane through the points (PCA: normal = smallest eigenvector).
    static func fitPlane(_ pts: [SIMD3<Float>]) -> FittedPlane? {
        guard pts.count >= 3 else { return nil }
        var c = SIMD3<Double>(0, 0, 0)
        for p in pts { c += SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)) }
        c /= Double(pts.count)
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        for p in pts {
            let d = SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)) - c
            m[0][0] += d.x * d.x; m[0][1] += d.x * d.y; m[0][2] += d.x * d.z
            m[1][1] += d.y * d.y; m[1][2] += d.y * d.z; m[2][2] += d.z * d.z
        }
        m[1][0] = m[0][1]; m[2][0] = m[0][2]; m[2][1] = m[1][2]
        let (values, vectors) = symmetricEigen(m)
        var smallest = 0
        for i in 1..<3 where values[i] < values[smallest] { smallest = i }
        var n = SIMD3<Float>(Float(vectors[0][smallest]), Float(vectors[1][smallest]), Float(vectors[2][smallest]))
        let len = simd_length(n)
        guard len > 1e-9, len.isFinite else { return nil }
        n /= len
        let rms = Float((max(values[smallest], 0) / Double(pts.count)).squareRoot())
        return FittedPlane(normal: n, point: SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z)), rms: rms, inliers: pts.count)
    }

    /// Cyclic Jacobi eigen-decomposition of a symmetric 3×3 matrix.
    /// Returns eigenvalues and the eigenvectors as COLUMNS of `vectors`.
    static func symmetricEigen(_ matrix: [[Double]]) -> (values: [Double], vectors: [[Double]]) {
        var a = matrix
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<32 {
            var p = 0, q = 1
            var maxOff = abs(a[0][1])
            if abs(a[0][2]) > maxOff { p = 0; q = 2; maxOff = abs(a[0][2]) }
            if abs(a[1][2]) > maxOff { p = 1; q = 2; maxOff = abs(a[1][2]) }
            if maxOff < 1e-15 { break }
            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot()
            let s = t * c
            for k in 0..<3 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
            }
            for k in 0..<3 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
            for k in 0..<3 {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
        }
        return ([a[0][0], a[1][1], a[2][2]], v)
    }

    /// Cyclic Jacobi for any small symmetric matrix (eigenvectors as COLUMNS).
    static func symmetricEigen(n: Int, _ matrix: [[Double]]) -> (values: [Double], vectors: [[Double]]) {
        var a = matrix
        var v = (0..<n).map { i in (0..<n).map { j in i == j ? 1.0 : 0.0 } }
        for _ in 0..<100 {
            var p = 0, q = 1
            var maxOff = 0.0
            for i in 0..<n {
                for j in (i + 1)..<n where abs(a[i][j]) > maxOff { p = i; q = j; maxOff = abs(a[i][j]) }
            }
            if maxOff < 1e-12 { break }
            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot()
            let s = t * c
            for k in 0..<n {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
            }
            for k in 0..<n {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
            for k in 0..<n {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
        }
        return ((0..<n).map { a[$0][$0] }, v)
    }

    /// Best scale + rotation + translation mapping `source` points onto
    /// `target` points (Horn's quaternion method). Returns the 4×4 transform
    /// (target ≈ M · source), the scale, and the RMS error in target units.
    static func similarity(from source: [SIMD3<Float>], to target: [SIMD3<Float>])
        -> (transform: simd_float4x4, scale: Float, rms: Float)? {
        let n = min(source.count, target.count)
        guard n >= 3 else { return nil }
        var cs = SIMD3<Double>(0, 0, 0), ct = SIMD3<Double>(0, 0, 0)
        for i in 0..<n {
            cs += SIMD3<Double>(source[i]); ct += SIMD3<Double>(target[i])
        }
        cs /= Double(n); ct /= Double(n)
        var S = [[Double]](repeating: [0, 0, 0], count: 3)   // S[a][b] = Σ x_a y_b
        var sourceVar = 0.0
        for i in 0..<n {
            let x = SIMD3<Double>(source[i]) - cs, y = SIMD3<Double>(target[i]) - ct
            let xs = [x.x, x.y, x.z], ys = [y.x, y.y, y.z]
            for a in 0..<3 { for b in 0..<3 { S[a][b] += xs[a] * ys[b] } }
            sourceVar += simd_dot(x, x)
        }
        guard sourceVar > 1e-9 else { return nil }
        let (sxx, sxy, sxz) = (S[0][0], S[0][1], S[0][2])
        let (syx, syy, syz) = (S[1][0], S[1][1], S[1][2])
        let (szx, szy, szz) = (S[2][0], S[2][1], S[2][2])
        let N: [[Double]] = [
            [sxx + syy + szz, syz - szy, szx - sxz, sxy - syx],
            [syz - szy, sxx - syy - szz, sxy + syx, szx + sxz],
            [szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy],
            [sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz]
        ]
        let (values, vectors) = symmetricEigen(n: 4, N)
        var best = 0
        for i in 1..<4 where values[i] > values[best] { best = i }
        var q = SIMD4<Double>(vectors[0][best], vectors[1][best], vectors[2][best], vectors[3][best])  // (w, x, y, z)
        q /= simd_length(q)
        let rotation = simd_matrix3x3(simd_quatd(ix: q.y, iy: q.z, iz: q.w, r: q.x))

        var dotSum = 0.0
        for i in 0..<n {
            let x = SIMD3<Double>(source[i]) - cs, y = SIMD3<Double>(target[i]) - ct
            dotSum += simd_dot(y, rotation * x)
        }
        let scale = dotSum / sourceVar
        guard scale.isFinite, scale > 0 else { return nil }
        let translation = ct - scale * (rotation * cs)

        var err = 0.0
        for i in 0..<n {
            let mapped = scale * (rotation * SIMD3<Double>(source[i])) + translation
            err += simd_distance_squared(mapped, SIMD3<Double>(target[i]))
        }
        let r = rotation * scale
        let m = simd_float4x4(
            SIMD4<Float>(Float(r.columns.0.x), Float(r.columns.0.y), Float(r.columns.0.z), 0),
            SIMD4<Float>(Float(r.columns.1.x), Float(r.columns.1.y), Float(r.columns.1.z), 0),
            SIMD4<Float>(Float(r.columns.2.x), Float(r.columns.2.y), Float(r.columns.2.z), 0),
            SIMD4<Float>(Float(translation.x), Float(translation.y), Float(translation.z), 1))
        return (m, Float(scale), Float((err / Double(n)).squareRoot()))
    }

    /// Up to `maxPlanes` planes found one after another with RANSAC. Deterministic
    /// (fixed seed) so the same tap always gives the same snap.
    static func ransacPlanes(_ points: [SIMD3<Float>], tolerance: Float, maxPlanes: Int,
                             minInliers: Int, iterations: Int = 40) -> [FittedPlane] {
        var remaining = points
        var planes: [FittedPlane] = []
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ n: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(n))
        }

        while planes.count < maxPlanes && remaining.count >= max(minInliers, 3) {
            var bestCount = 0
            var bestNormal = SIMD3<Float>(0, 1, 0)
            var bestPoint = SIMD3<Float>(0, 0, 0)
            for _ in 0..<iterations {
                let a = remaining[next(remaining.count)]
                let b = remaining[next(remaining.count)]
                let c = remaining[next(remaining.count)]
                var n = simd_cross(b - a, c - a)
                let len = simd_length(n)
                if len < 1e-9 { continue }
                n /= len
                var count = 0
                for p in remaining where abs(simd_dot(n, p - a)) <= tolerance { count += 1 }
                if count > bestCount { bestCount = count; bestNormal = n; bestPoint = a }
            }
            guard bestCount >= minInliers else { break }

            var inliers: [SIMD3<Float>] = []
            var outliers: [SIMD3<Float>] = []
            for p in remaining {
                if abs(simd_dot(bestNormal, p - bestPoint)) <= tolerance { inliers.append(p) } else { outliers.append(p) }
            }
            remaining = outliers
            let plane = fitPlane(inliers) ?? FittedPlane(normal: bestNormal, point: bestPoint, rms: tolerance, inliers: inliers.count)
            // A second plane almost parallel to one we have is the same surface.
            if planes.contains(where: { abs(simd_dot($0.normal, plane.normal)) > cos(Float.pi / 7) }) { continue }
            planes.append(FittedPlane(normal: plane.normal, point: plane.point, rms: plane.rms, inliers: inliers.count))
        }
        return planes
    }

    /// Line where two planes meet.
    static func intersect(_ a: FittedPlane, _ b: FittedPlane) -> (point: SIMD3<Float>, direction: SIMD3<Float>)? {
        let u = simd_cross(a.normal, b.normal)
        let uu = simd_dot(u, u)
        guard uu > 1e-6 else { return nil }
        let x0 = (a.d * simd_cross(b.normal, u) + b.d * simd_cross(u, a.normal)) / uu
        return (x0, u / uu.squareRoot())
    }

    /// Point where three planes meet.
    static func intersect(_ a: FittedPlane, _ b: FittedPlane, _ c: FittedPlane) -> SIMD3<Float>? {
        let det = simd_dot(a.normal, simd_cross(b.normal, c.normal))
        guard abs(det) > 1e-3 else { return nil }
        let x = (a.d * simd_cross(b.normal, c.normal)
                 + b.d * simd_cross(c.normal, a.normal)
                 + c.d * simd_cross(a.normal, b.normal)) / det
        return x.x.isFinite && x.y.isFinite && x.z.isFinite ? x : nil
    }

    /// Point on the line (origin a, direction u) closest to the ray (origin o, direction d).
    static func closestPoint(onLine a: SIMD3<Float>, direction u: SIMD3<Float>,
                             toRay o: SIMD3<Float>, direction d: SIMD3<Float>) -> SIMD3<Float>? {
        let w0 = a - o
        let aa = simd_dot(u, u), b = simd_dot(u, d), c = simd_dot(d, d)
        let dd = simd_dot(u, w0), e = simd_dot(d, w0)
        let denom = aa * c - b * b
        guard abs(denom) > 1e-8 else { return nil }
        let s = (b * e - c * dd) / denom
        return a + s * u
    }
}

// MARK: - Spatial index of a loaded model

/// Points (and surface directions) of the model in world space, with a hash grid
/// for fast "what's near here" queries. Built once per model, off the main thread.
final class ModelGeometryIndex {
    let points: [SIMD3<Float>]
    /// Neighbourhood radius used for surface / edge / corner analysis (m).
    private(set) var radius: Float
    /// Main horizontal wall directions (unit vectors, y = 0). Empty if unclear.
    private(set) var wallAxes: [SIMD3<Float>] = []
    let minY: Float
    let maxY: Float

    private var cellSize: Float
    private var cells: [SIMD3<Int32>: [Int32]] = [:]

    /// - Parameters:
    ///   - faceNormals: triangle normals with area weights (empty for point clouds).
    init(points: [SIMD3<Float>], faceNormals: [(SIMD3<Float>, Float)]) {
        self.points = points
        let (minB, maxB) = MeshData.bounds(of: points)
        minY = minB.y
        maxY = maxB.y
        let diag = simd_length(maxB - minB)
        radius = min(max(diag * 0.015, 0.012), 0.25)
        cellSize = radius
        buildCells()

        // Make sure a neighbourhood holds enough points to fit surfaces reliably.
        for _ in 0..<2 where medianNeighbourCount() < 12 {
            radius *= 1.8
            cellSize = radius
            buildCells()
        }

        wallAxes = ModelGeometryIndex.dominantWallAxes(
            faceNormals.isEmpty ? estimatedVerticalNormals() : faceNormals)
    }

    private func key(_ p: SIMD3<Float>) -> SIMD3<Int32>? {
        let s = p / cellSize
        guard s.x.isFinite, s.y.isFinite, s.z.isFinite,
              abs(s.x) < 1e7, abs(s.y) < 1e7, abs(s.z) < 1e7 else { return nil }
        return SIMD3<Int32>(Int32(s.x.rounded(.down)), Int32(s.y.rounded(.down)), Int32(s.z.rounded(.down)))
    }

    private func buildCells() {
        cells.removeAll(keepingCapacity: true)
        for (i, p) in points.enumerated() {
            if let k = key(p) { cells[k, default: []].append(Int32(i)) }
        }
    }

    private func medianNeighbourCount() -> Int {
        guard !points.isEmpty else { return 0 }
        let step = max(1, points.count / 200)
        var counts: [Int] = []
        var i = 0
        while i < points.count {
            counts.append(neighbours(of: points[i], radius: radius, limit: 64).count)
            i += step
        }
        counts.sort()
        return counts[counts.count / 2]
    }

    /// Points within `radius` of `p` (evenly thinned to at most `limit`).
    func neighbours(of p: SIMD3<Float>, radius r: Float, limit: Int = 1500) -> [SIMD3<Float>] {
        guard let k = key(p) else { return [] }
        let reach = Int32(max(1, Int((r / cellSize).rounded(.up))))
        let r2 = r * r
        var found: [SIMD3<Float>] = []
        for dx in -reach...reach {
            for dy in -reach...reach {
                for dz in -reach...reach {
                    guard let bucket = cells[SIMD3<Int32>(k.x + dx, k.y + dy, k.z + dz)] else { continue }
                    for idx in bucket {
                        let q = points[Int(idx)]
                        if simd_distance_squared(q, p) <= r2 { found.append(q) }
                    }
                }
            }
        }
        if found.count > limit {
            let step = Double(found.count) / Double(limit)
            found = (0..<limit).map { found[Int(Double($0) * step)] }
        }
        return found
    }

    /// Nearest surface height directly above and below `p` (for point clouds,
    /// where SceneKit can't ray-cast): looks in a thin vertical column.
    func column(at p: SIMD3<Float>, halfWidth: Float) -> (above: Float?, below: Float?) {
        guard let k = key(p) else { return (nil, nil) }
        let reach = Int32(max(1, Int((halfWidth / cellSize).rounded(.up))))
        let yCells = Int32(((maxY - minY) / cellSize).rounded(.up)) + 2
        guard let low = key(SIMD3<Float>(p.x, minY, p.z))?.y else { return (nil, nil) }
        let hw2 = halfWidth * halfWidth
        let gap: Float = 0.02
        var above: Float?
        var below: Float?
        for dx in -reach...reach {
            for dz in -reach...reach {
                for yi in 0...yCells {
                    guard let bucket = cells[SIMD3<Int32>(k.x + dx, low + yi - 1, k.z + dz)] else { continue }
                    for idx in bucket {
                        let q = points[Int(idx)]
                        let hx = q.x - p.x, hz = q.z - p.z
                        guard hx * hx + hz * hz <= hw2 else { continue }
                        if q.y > p.y + gap { above = min(above ?? q.y, q.y) }
                        if q.y < p.y - gap { below = max(below ?? q.y, q.y) }
                    }
                }
            }
        }
        return (above, below)
    }

    /// Surface directions for point clouds (no triangles): fit small planes around
    /// sampled points and keep the vertical (wall) ones.
    private func estimatedVerticalNormals() -> [(SIMD3<Float>, Float)] {
        guard points.count > 50 else { return [] }
        let step = max(1, points.count / 1500)
        var normals: [(SIMD3<Float>, Float)] = []
        var i = 0
        while i < points.count {
            let nb = neighbours(of: points[i], radius: radius, limit: 80)
            if nb.count >= 10, let plane = GeometryMath.fitPlane(nb), plane.rms < radius * 0.15 {
                normals.append((plane.normal, 1))
            }
            i += step
        }
        return normals
    }

    /// Find the room's main wall direction: histogram of wall-normal angles folded
    /// into 0–90° (walls are usually at right angles), weighted by area.
    static func dominantWallAxes(_ normals: [(SIMD3<Float>, Float)]) -> [SIMD3<Float>] {
        let binCount = 90
        var bins = [Float](repeating: 0, count: binCount)
        var total: Float = 0
        let quarter = Float.pi / 2
        for (n, w) in normals where abs(n.y) < 0.35 && w > 0 {
            var angle = atan2(n.z, n.x).truncatingRemainder(dividingBy: quarter)
            if angle < 0 { angle += quarter }
            let b = min(binCount - 1, Int(angle / quarter * Float(binCount)))
            bins[b] += w
            total += w
        }
        guard total > 0 else { return [] }

        // Best 5° window (circular) → weighted mean angle inside it.
        var bestCenter = 0
        var bestWeight: Float = 0
        for c in 0..<binCount {
            var w: Float = 0
            for o in -2...2 { w += bins[(c + o + binCount) % binCount] }
            if w > bestWeight { bestWeight = w; bestCenter = c }
        }
        guard bestWeight / total > 0.25 else { return [] }   // no clear wall direction
        var sx: Float = 0, sy: Float = 0
        for o in -2...2 {
            let b = (bestCenter + o + binCount) % binCount
            // Map the 0–90° fold onto a full circle so averaging wraps correctly.
            let a = (Float(b) + 0.5) / Float(binCount) * 2 * Float.pi
            sx += cos(a) * bins[b]
            sy += sin(a) * bins[b]
        }
        var mean = atan2(sy, sx)
        if mean < 0 { mean += 2 * Float.pi }
        let theta = mean / 4   // back to 0–90°
        let a1 = SIMD3<Float>(cos(theta), 0, sin(theta))
        let a2 = SIMD3<Float>(-sin(theta), 0, cos(theta))
        return [a1, a2]
    }

    // MARK: - Extraction from SceneKit

    /// Geometry to index, captured on the main thread (node transforms).
    struct Source {
        let geometry: SCNGeometry
        let transform: simd_float4x4
    }

    static func sources(in root: SCNNode) -> [Source] {
        var result: [Source] = []
        func visit(_ node: SCNNode) {
            if let g = node.geometry { result.append(Source(geometry: g, transform: node.simdWorldTransform)) }
            node.childNodes.forEach(visit)
        }
        visit(root)
        return result
    }

    /// Build the index from captured geometry (safe to call off the main thread).
    static func build(from sources: [Source]) -> ModelGeometryIndex {
        var points: [SIMD3<Float>] = []
        var faceNormals: [(SIMD3<Float>, Float)] = []

        for src in sources {
            guard let vsrc = src.geometry.sources(for: .vertex).first,
                  vsrc.usesFloatComponents, vsrc.bytesPerComponent == 4, vsrc.componentsPerVector >= 3 else { continue }
            let m = src.transform
            let count = vsrc.vectorCount
            var local = [SIMD3<Float>](repeating: .zero, count: count)
            vsrc.data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                for i in 0..<count {
                    let f = base.advanced(by: vsrc.dataOffset + vsrc.dataStride * i).assumingMemoryBound(to: Float.self)
                    let w = m * SIMD4<Float>(f[0], f[1], f[2], 1)
                    local[i] = SIMD3<Float>(w.x, w.y, w.z)
                }
            }
            points.append(contentsOf: local)

            // Triangle normals for finding wall directions.
            for element in src.geometry.elements where element.primitiveType == .triangles {
                let bpi = element.bytesPerIndex
                let triCount = element.primitiveCount
                let step = max(1, triCount / 300_000)
                element.data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    func index(_ i: Int) -> Int {
                        let p = base.advanced(by: i * bpi)
                        switch bpi {
                        case 1: return Int(p.assumingMemoryBound(to: UInt8.self).pointee)
                        case 2: return Int(p.assumingMemoryBound(to: UInt16.self).pointee)
                        default: return Int(p.assumingMemoryBound(to: UInt32.self).pointee)
                        }
                    }
                    var t = 0
                    while t < triCount {
                        let i0 = index(t * 3), i1 = index(t * 3 + 1), i2 = index(t * 3 + 2)
                        if i0 < count, i1 < count, i2 < count {
                            let c = simd_cross(local[i1] - local[i0], local[i2] - local[i0])
                            let len = simd_length(c)
                            if len > 1e-10 { faceNormals.append((c / len, len * 0.5 * Float(step))) }
                        }
                        t += step
                    }
                }
            }
        }

        // Keep memory bounded on very large scans.
        if points.count > 1_500_000 {
            let step = Double(points.count) / 1_500_000
            points = (0..<1_500_000).map { points[Int(Double($0) * step)] }
        }
        return ModelGeometryIndex(points: points, faceNormals: faceNormals)
    }
}
