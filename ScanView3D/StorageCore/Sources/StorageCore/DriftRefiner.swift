import Foundation
import simd

// Lining up overlapping passes of one long capture.
//
// A long point-cloud scan is stored as SEGMENTS: short stretches of the walk
// (about 1.5 m) whose points were all placed with nearly the same position
// error. When the phone's own position estimate drifts, a later pass over the
// same place lands a few centimetres to decimetres away from the earlier one.
//
// The refiner walks the segments in capture order. Each one is fitted onto
// everything captured clearly earlier (point-to-plane), and its correction is
// carried forward, because drift accumulates. A small least-squares problem then
// spreads the corrections along the walk: neighbouring segments keep their
// measured relative pose (odometry), gravity stays gravity, and overlapping
// surfaces must coincide.
//
// What this cannot do: it sees no error where nothing overlaps, and no error
// along a direction the shape does not constrain (sliding along a plain wall).
// It moves whole segments rigidly and never invents, deletes or averages points.

/// Subsampled surface samples of one segment, in the segment's own coordinates.
struct DriftSegmentModel {
    var local: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var pose0: RigidPose
    var pointCount = 0
    var boundsMin = SIMD3<Float>(repeating: 0)
    var boundsMax = SIMD3<Float>(repeating: 0)
    var centroid = SIMD3<Double>(0, 0, 0)

    var isEmpty: Bool { local.isEmpty }
}

/// Uniform grid over a fixed point set for radius searches.
struct DriftSpatialHash {
    private let cell: Double
    private let points: [SIMD3<Double>]
    private var order: [Int32] = []
    private var ranges: [Int64: (start: Int32, count: Int32)] = [:]

    static func key(_ x: Int, _ y: Int, _ z: Int) -> Int64 {
        // 21 bits per axis around a 2^20 offset: ±1,000,000 cells.
        let mask: Int64 = 0x1F_FFFF
        return ((Int64(x) + 1_048_576) & mask) << 42 | ((Int64(y) + 1_048_576) & mask) << 21 | ((Int64(z) + 1_048_576) & mask)
    }

    static func cellIndex(_ value: Double, _ cell: Double) -> Int {
        let q = (value / cell).rounded(.down)
        return q.isFinite && abs(q) < 1_000_000 ? Int(q) : 0
    }

    init(points: [SIMD3<Double>], cell: Double) {
        self.cell = max(cell, 1e-4)
        self.points = points
        guard !points.isEmpty else { return }
        var keys = [Int64](repeating: 0, count: points.count)
        for i in 0..<points.count {
            let p = points[i]
            keys[i] = DriftSpatialHash.key(DriftSpatialHash.cellIndex(p.x, self.cell),
                                           DriftSpatialHash.cellIndex(p.y, self.cell),
                                           DriftSpatialHash.cellIndex(p.z, self.cell))
        }
        order = (0..<Int32(points.count)).sorted { keys[Int($0)] < keys[Int($1)] }
        ranges.reserveCapacity(points.count / 4 + 1)
        var start = 0
        while start < order.count {
            let k = keys[Int(order[start])]
            var end = start + 1
            while end < order.count, keys[Int(order[end])] == k { end += 1 }
            ranges[k] = (Int32(start), Int32(end - start))
            start = end
        }
    }

    /// Nearest stored point within `radius` of `p`, or nil.
    func nearest(to p: SIMD3<Double>, radius: Double) -> Int? {
        guard !points.isEmpty else { return nil }
        let reach = max(1, Int((radius / cell).rounded(.up)))
        let cx = DriftSpatialHash.cellIndex(p.x, cell), cy = DriftSpatialHash.cellIndex(p.y, cell)
        let cz = DriftSpatialHash.cellIndex(p.z, cell)
        var best = -1
        var bestDistance = radius * radius
        for dx in -reach...reach {
            for dy in -reach...reach {
                for dz in -reach...reach {
                    guard let range = ranges[DriftSpatialHash.key(cx + dx, cy + dy, cz + dz)] else { continue }
                    let first = Int(range.start)
                    for slot in first..<(first + Int(range.count)) {
                        let index = Int(order[slot])
                        let d = simd_distance_squared(points[index], p)
                        if d <= bestDistance { bestDistance = d; best = index }
                    }
                }
            }
        }
        return best >= 0 ? best : nil
    }

    /// Calls `body` with every stored index within `radius` of `p`.
    func forEach(near p: SIMD3<Double>, radius: Double, _ body: (Int) -> Void) {
        guard !points.isEmpty else { return }
        let reach = max(1, Int((radius / cell).rounded(.up)))
        let cx = DriftSpatialHash.cellIndex(p.x, cell), cy = DriftSpatialHash.cellIndex(p.y, cell)
        let cz = DriftSpatialHash.cellIndex(p.z, cell)
        let limit = radius * radius
        for dx in -reach...reach {
            for dy in -reach...reach {
                for dz in -reach...reach {
                    guard let range = ranges[DriftSpatialHash.key(cx + dx, cy + dy, cz + dz)] else { continue }
                    let first = Int(range.start)
                    for slot in first..<(first + Int(range.count)) {
                        let index = Int(order[slot])
                        if simd_distance_squared(points[index], p) <= limit { body(index) }
                    }
                }
            }
        }
    }
}

/// Least-squares problem over segment poses. Node 0 never moves (the start of
/// the scan stays where it was). Jacobians are numerical: the blocks are tiny
/// and this keeps every constraint type to a few readable lines.
final class DriftGraph {
    typealias Residual = ([RigidPose]) -> [Double]
    private(set) var x: [RigidPose]
    private var blocks: [(nodes: [Int], function: Residual)] = []

    init(poses: [RigidPose]) { x = poses }

    func add(nodes: [Int], _ function: @escaping Residual) {
        var unique: [Int] = []
        for node in nodes where !unique.contains(node) { unique.append(node) }
        blocks.append((unique, function))
    }

    func cost(_ poses: [RigidPose]) -> Double {
        var total = 0.0
        for block in blocks { for value in block.function(poses) { total += value * value } }
        return total
    }

    /// Levenberg–Marquardt. Returns the final cost.
    @discardableResult
    func solve(iterations: Int = 12, cancelled: () -> Bool = { false }) -> Double {
        let count = x.count
        let dimension = 6 * max(0, count - 1)
        var current = cost(x)
        guard dimension > 0, current.isFinite else { return current }
        var lambda = 1e-4
        let epsilon = 1e-6
        for _ in 0..<iterations {
            if cancelled() { break }
            var hessian = [Double](repeating: 0, count: dimension * dimension)
            var gradient = [Double](repeating: 0, count: dimension)
            var work = x
            for block in blocks {
                let r0 = block.function(work)
                if r0.isEmpty { continue }
                var columns: [Int] = []
                var jacobians: [[Double]] = []      // each is r0.count × 6, row-major
                for node in block.nodes where node != 0 {
                    var jacobian = [Double](repeating: 0, count: r0.count * 6)
                    let keep = work[node]
                    var delta = [Double](repeating: 0, count: 6)
                    for k in 0..<6 {
                        delta[k] = epsilon
                        work[node] = keep.boxplus(delta)
                        delta[k] = 0
                        let r1 = block.function(work)
                        for row in 0..<r0.count { jacobian[row * 6 + k] = (r1[row] - r0[row]) / epsilon }
                    }
                    work[node] = keep
                    columns.append(node)
                    jacobians.append(jacobian)
                }
                for (ai, a) in columns.enumerated() {
                    let ia = 6 * (a - 1)
                    let ja = jacobians[ai]
                    for k in 0..<6 {
                        var sum = 0.0
                        for row in 0..<r0.count { sum += ja[row * 6 + k] * r0[row] }
                        gradient[ia + k] += sum
                    }
                    for (bi, b) in columns.enumerated() {
                        let ib = 6 * (b - 1)
                        let jb = jacobians[bi]
                        for k in 0..<6 {
                            for m in 0..<6 {
                                var sum = 0.0
                                for row in 0..<r0.count { sum += ja[row * 6 + k] * jb[row * 6 + m] }
                                hessian[(ia + k) * dimension + ib + m] += sum
                            }
                        }
                    }
                }
            }
            var improved = false
            var relative = 0.0
            for _ in 0..<8 {
                var damped = hessian
                for i in 0..<dimension { damped[i * dimension + i] += lambda * hessian[i * dimension + i] + 1e-9 }
                guard let step = DriftMath.choleskySolve(damped, gradient.map { -$0 }, n: dimension) else {
                    lambda *= 10; continue
                }
                var trial = x
                for node in 1..<count { trial[node] = x[node].boxplus(step, offset: 6 * (node - 1)) }
                let trialCost = cost(trial)
                if trialCost.isFinite, trialCost < current {
                    relative = (current - trialCost) / max(current, 1e-12)
                    x = trial; current = trialCost; improved = true
                    lambda = max(lambda / 5, 1e-9)
                    break
                }
                lambda *= 10
            }
            if !improved || relative < 1e-5 { break }
        }
        // Tidy accumulated rounding; node 0 is fixed and stays bit-identical.
        if count > 1 { for node in 1..<count { x[node] = x[node].orthonormalised } }
        return current
    }
}

enum DriftRefiner {
    struct Options {
        /// Capture grid spacing in metres (the point-cloud Detail setting).
        var spacing: Double = 0.01
        /// A segment is only fitted onto segments at least this many steps older.
        var gap = 3
        /// Below this disagreement between passes nothing is changed at all.
        var noopShift = 0.025
        var minInliers = 120
        var maxSamplesPerSegment = 3000
        var maxSourceSamples = 1500
        /// Gravity direction in the frame of the input points.
        var up = SIMD3<Double>(0, 1, 0)

        var sampleCell: Double { max(0.06, spacing * 1.5) }
        var normalRadius: Double { max(0.07, spacing * 2.5) }
    }

    /// Overlap between two segments: after a correct alignment each `qa` (in
    /// segment `a`) lies on the plane through `qb` with normal `nb` (segment `b`).
    struct Link {
        var a: Int
        var b: Int
        var qa: [SIMD3<Double>]
        var qb: [SIMD3<Double>]
        var nb: [SIMD3<Double>]
    }

    enum Result: String, Codable {
        case applied, passesAgree, noOverlap, noImprovement, cancelled
    }

    struct Outcome {
        var result: Result
        /// Final pose per segment. Equal to the input unless `result == .applied`.
        var poses: [RigidPose]
        var links: [Link] = []
        var matchedSegments = 0
        /// Largest distance any segment had to move to meet an earlier pass.
        var disagreement = 0.0
        /// Mean distance between overlapping surfaces before / after.
        var mismatchBefore: Double?
        var mismatchAfter: Double?
        var maxMove = 0.0
        var maxTurnDegrees = 0.0
    }

    struct Match {
        var correction: RigidPose
        var links: [Link]
        var shift: Double
        var turnDegrees: Double
        var spread: Double
        var inliers: Int
        var rank: Int
    }

    // MARK: Segment models

    static func buildModels(points: [SIMD3<Float>], segments: [UInt16], poses: [RigidPose],
                            options: Options) -> [DriftSegmentModel] {
        let count = poses.count
        var models = poses.map { DriftSegmentModel(pose0: $0) }
        guard points.count == segments.count, count > 0 else { return models }
        // Counting sort of point indices by segment.
        var starts = [Int](repeating: 0, count: count + 1)
        for s in segments where Int(s) < count { starts[Int(s) + 1] += 1 }
        for k in 0..<count { starts[k + 1] += starts[k] }
        var cursor = starts
        var order = [Int32](repeating: 0, count: starts[count])
        for i in 0..<points.count {
            let s = Int(segments[i])
            guard s < count else { continue }
            order[cursor[s]] = Int32(i); cursor[s] += 1
        }
        let cell = options.sampleCell, radius = options.normalRadius
        for k in 0..<count {
            let total = starts[k + 1] - starts[k]
            models[k].pointCount = total
            guard total >= 60 else { continue }
            // Support set for normals: at most ~40 000 evenly taken points.
            let step = max(1, total / 40_000)
            var support: [SIMD3<Double>] = []
            support.reserveCapacity(total / step + 1)
            var slot = starts[k]
            while slot < starts[k + 1] {
                let p = points[Int(order[slot])]
                if p.x.isFinite, p.y.isFinite, p.z.isFinite {
                    support.append(SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)))
                }
                slot += step
            }
            guard support.count >= 60 else { continue }
            // One sample per `cell` cube (the first point met), evenly thinned to the cap.
            var seen = Set<Int64>()
            var picks: [Int] = []
            for (i, p) in support.enumerated() {
                let key = DriftSpatialHash.key(DriftSpatialHash.cellIndex(p.x, cell), DriftSpatialHash.cellIndex(p.y, cell),
                                               DriftSpatialHash.cellIndex(p.z, cell))
                if seen.insert(key).inserted { picks.append(i) }
            }
            if picks.count > options.maxSamplesPerSegment {
                let keep = options.maxSamplesPerSegment
                let all = picks
                picks = (0..<keep).map { all[$0 * (all.count - 1) / max(1, keep - 1)] }
            }
            let hash = DriftSpatialHash(points: support, cell: radius)
            let pose = poses[k]
            var local: [SIMD3<Float>] = []
            var normals: [SIMD3<Float>] = []
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            var sum = SIMD3<Double>(0, 0, 0)
            for i in picks {
                let p = support[i]
                var mean = SIMD3<Double>(0, 0, 0)
                var neighbours: [SIMD3<Double>] = []
                hash.forEach(near: p, radius: radius) { index in
                    if neighbours.count < 80 { neighbours.append(support[index]) }
                }
                guard neighbours.count >= 6 else { continue }
                for q in neighbours { mean += q }
                mean /= Double(neighbours.count)
                var c = [Double](repeating: 0, count: 9)
                for q in neighbours {
                    let d = q - mean
                    c[0] += d.x * d.x; c[1] += d.x * d.y; c[2] += d.x * d.z
                    c[4] += d.y * d.y; c[5] += d.y * d.z; c[8] += d.z * d.z
                }
                c[3] = c[1]; c[6] = c[2]; c[7] = c[5]
                let eigen = DriftMath.symmetricEigen(c, n: 3)
                // Keep flat patches only: edges and clutter have no usable normal.
                guard eigen.values[1] > 0, eigen.values[0] <= 0.08 * eigen.values[1] else { continue }
                var normal = SIMD3<Double>(eigen.vectors[0], eigen.vectors[3], eigen.vectors[6])
                let length = simd_length(normal)
                guard length > 1e-9 else { continue }
                normal /= length
                // Face the side the phone saw it from.
                if simd_dot(normal, pose.t - p) < 0 { normal = -normal }
                let q = pose.applyInverse(p)
                let n = pose.rotateInverse(normal)
                let qf = SIMD3<Float>(Float(q.x), Float(q.y), Float(q.z))
                local.append(qf)
                normals.append(SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z)))
                lo = simd_min(lo, qf); hi = simd_max(hi, qf)
                sum += q
            }
            guard local.count >= 60 else { continue }
            models[k].local = local
            models[k].normals = normals
            models[k].boundsMin = lo
            models[k].boundsMax = hi
            models[k].centroid = sum / Double(local.count)
        }
        return models
    }

    private static func double(_ v: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z))
    }

    /// Axis-aligned world box of a model at `pose`.
    private static func worldBounds(_ model: DriftSegmentModel, _ pose: RigidPose) -> (SIMD3<Double>, SIMD3<Double>) {
        var lo = SIMD3<Double>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Double>(repeating: -.greatestFiniteMagnitude)
        let a = double(model.boundsMin), b = double(model.boundsMax)
        for corner in 0..<8 {
            let p = pose.apply(SIMD3<Double>(corner & 1 == 0 ? a.x : b.x, corner & 2 == 0 ? a.y : b.y,
                                             corner & 4 == 0 ? a.z : b.z))
            lo = simd_min(lo, p); hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    // MARK: Point-to-plane fit

    /// One Gauss–Newton step about `centre`. Directions the shape does not
    /// constrain (sliding along a wall or canal, spinning on a flat floor) are
    /// left exactly unchanged. A direction counts as constrained when roughly 30
    /// or more points face it (and at least 0.4 % of them).
    static func planeStep(source: [SIMD3<Double>], target: [SIMD3<Double>], normals: [SIMD3<Double>],
                          centre: SIMD3<Double>) -> (step: [Double], rank: Int) {
        let count = source.count
        var h = [Double](repeating: 0, count: 36)
        var hw = [Double](repeating: 0, count: 36)
        var g = [Double](repeating: 0, count: 6)
        for k in 0..<count {
            let n = normals[k]
            let arm = simd_cross(source[k] - centre, n)
            let row = [arm.x, arm.y, arm.z, n.x, n.y, n.z]
            let b = -simd_dot(n, source[k] - target[k])
            let weight = min(1, 0.02 / max(abs(b), 1e-9))      // far points still pull, gently
            for i in 0..<6 {
                g[i] += weight * row[i] * b
                for j in 0..<6 {
                    let product = row[i] * row[j]
                    h[i * 6 + j] += product
                    hw[i * 6 + j] += weight * product
                }
            }
        }
        let eigen = DriftMath.symmetricEigen(h, n: 6)
        let threshold = max(30.0, 0.004 * Double(count))
        let kept = (0..<6).filter { eigen.values[$0] > threshold }
        guard !kept.isEmpty else { return ([Double](repeating: 0, count: 6), 0) }
        let size = kept.count
        // Reduced system in the constrained directions only: (Vᵀ Hw V) y = Vᵀ g.
        var reduced = [Double](repeating: 0, count: size * size)
        var rhs = [Double](repeating: 0, count: size)
        for (a, ka) in kept.enumerated() {
            for i in 0..<6 { rhs[a] += eigen.vectors[i * 6 + ka] * g[i] }
            for (b, kb) in kept.enumerated() {
                var sum = 0.0
                for i in 0..<6 {
                    var inner = 0.0
                    for j in 0..<6 { inner += hw[i * 6 + j] * eigen.vectors[j * 6 + kb] }
                    sum += eigen.vectors[i * 6 + ka] * inner
                }
                reduced[a * size + b] = sum
            }
        }
        guard let y = DriftMath.choleskySolve(reduced, rhs, n: size) else {
            return ([Double](repeating: 0, count: 6), 0)
        }
        var step = [Double](repeating: 0, count: 6)
        for (a, ka) in kept.enumerated() { for i in 0..<6 { step[i] += eigen.vectors[i * 6 + ka] * y[a] } }
        return (step, size)
    }

    /// Spread the picks over the six axis directions so weakly seen directions
    /// (a kerb end, a window reveal) keep a say next to large walls and floors.
    static func pickCorrespondences(_ normals: [SIMD3<Double>], count: Int) -> [Int] {
        guard normals.count > count else { return Array(normals.indices) }
        var groups = [[Int]](repeating: [], count: 6)
        for (i, n) in normals.enumerated() {
            let a = [abs(n.x), abs(n.y), abs(n.z)]
            let axis = a[0] >= a[1] && a[0] >= a[2] ? 0 : (a[1] >= a[2] ? 1 : 2)
            let value = axis == 0 ? n.x : (axis == 1 ? n.y : n.z)
            groups[axis * 2 + (value > 0 ? 1 : 0)].append(i)
        }
        let used = groups.filter { !$0.isEmpty }
        let each = max(1, count / max(1, used.count))
        var picked = Set<Int>()
        for group in used {
            let take = min(group.count, each)
            for k in 0..<take { picked.insert(group[take == 1 ? 0 : k * (group.count - 1) / (take - 1)]) }
        }
        return picked.sorted()
    }

    /// Fit segment `j` onto the union of `modelIDs` (all at `poses`).
    static func match(_ j: Int, models: [DriftSegmentModel], poses: [RigidPose], modelIDs: [Int],
                      radii: [Double], options: Options) -> Match? {
        let source = models[j]
        guard source.local.count >= options.minInliers, !modelIDs.isEmpty, let firstRadius = radii.first else { return nil }
        let pose = poses[j]
        // Evenly thinned source set.
        let every = max(1, source.local.count / options.maxSourceSamples)
        var sourceIndex: [Int] = []
        var src: [SIMD3<Double>] = []
        var srcNormals: [SIMD3<Double>] = []
        var index = 0
        while index < source.local.count {
            sourceIndex.append(index)
            src.append(pose.apply(source.local[index]))
            srcNormals.append(pose.rotate(double(source.normals[index])))
            index += every
        }
        var (lo, hi) = worldBounds(source, pose)
        lo -= SIMD3<Double>(repeating: firstRadius); hi += SIMD3<Double>(repeating: firstRadius)
        var modelPoints: [SIMD3<Double>] = []
        var modelNormals: [SIMD3<Double>] = []
        var modelSegment: [Int32] = []
        var modelLocal: [Int32] = []
        for i in modelIDs where !models[i].isEmpty {
            let (mlo, mhi) = worldBounds(models[i], poses[i])
            if mlo.x > hi.x || mlo.y > hi.y || mlo.z > hi.z || mhi.x < lo.x || mhi.y < lo.y || mhi.z < lo.z { continue }
            let other = models[i], otherPose = poses[i]
            for k in 0..<other.local.count {
                let w = otherPose.apply(other.local[k])
                guard w.x >= lo.x, w.y >= lo.y, w.z >= lo.z, w.x <= hi.x, w.y <= hi.y, w.z <= hi.z else { continue }
                modelPoints.append(w)
                modelNormals.append(otherPose.rotate(double(other.normals[k])))
                modelSegment.append(Int32(i)); modelLocal.append(Int32(k))
            }
        }
        guard modelPoints.count >= options.minInliers else { return nil }
        let hash = DriftSpatialHash(points: modelPoints, cell: 0.2)

        var rotation = matrix_identity_double3x3
        var shift = SIMD3<Double>(0, 0, 0)
        var last: (source: [Int], model: [Int], rank: Int)?
        for radius in radii {
            for _ in 0..<4 {
                var chosenSource: [Int] = []
                var chosenModel: [Int] = []
                var moved: [SIMD3<Double>] = []
                var targets: [SIMD3<Double>] = []
                var normals: [SIMD3<Double>] = []
                for s in 0..<src.count {
                    let p = rotation * src[s] + shift
                    guard let m = hash.nearest(to: p, radius: radius) else { continue }
                    // Same side of the surface only: the back of a wall is not its front.
                    guard simd_dot(rotation * srcNormals[s], modelNormals[m]) > 0.6 else { continue }
                    chosenSource.append(s); chosenModel.append(m)
                    moved.append(p); targets.append(modelPoints[m]); normals.append(modelNormals[m])
                }
                if chosenSource.count < options.minInliers { break }
                let centre = moved.reduce(SIMD3<Double>(0, 0, 0), +) / Double(moved.count)
                let (step, rank) = planeStep(source: moved, target: targets, normals: normals, centre: centre)
                let w = SIMD3<Double>(step[0], step[1], step[2]), v = SIMD3<Double>(step[3], step[4], step[5])
                let dr = DriftMath.expSO3(w)
                let dt = v + centre - dr * centre
                rotation = dr * rotation
                shift = dr * shift + dt
                last = (chosenSource, chosenModel, rank)
                if simd_length(w) < 2e-5 && simd_length(v) < 2e-4 { break }
            }
        }
        guard let result = last, result.source.count >= options.minInliers else { return nil }
        var residuals: [Double] = []
        residuals.reserveCapacity(result.source.count)
        var centre = SIMD3<Double>(0, 0, 0)
        for (s, m) in zip(result.source, result.model) {
            residuals.append(abs(simd_dot(modelNormals[m], rotation * src[s] + shift - modelPoints[m])))
            centre += src[s]
        }
        centre /= Double(result.source.count)
        residuals.sort()
        let spread = residuals[residuals.count / 2] * 1.4826
        let turn = simd_length(DriftMath.logSO3(rotation)) * 180 / .pi
        let move = simd_length(rotation * centre + shift - centre)
        // A believable drift correction is small; anything else is a false match.
        guard spread <= 0.03, turn <= 6, move <= 1.2, turn.isFinite, move.isFinite else { return nil }

        let picks = pickCorrespondences(result.model.map { modelNormals[$0] }, count: 96)
        var grouped: [Int: [Int]] = [:]
        for pick in picks { grouped[Int(modelSegment[result.model[pick]]), default: []].append(pick) }
        var links: [Link] = []
        for i in grouped.keys.sorted() {
            guard let members = grouped[i], members.count >= 4 else { continue }
            var link = Link(a: j, b: i, qa: [], qb: [], nb: [])
            for pick in members {
                let m = result.model[pick]
                link.qa.append(double(source.local[sourceIndex[result.source[pick]]]))
                link.qb.append(double(models[i].local[Int(modelLocal[m])]))
                link.nb.append(double(models[i].normals[Int(modelLocal[m])]))
            }
            links.append(link)
        }
        return Match(correction: RigidPose(r: rotation, t: shift), links: links, shift: move, turnDegrees: turn,
                     spread: spread, inliers: result.source.count, rank: result.rank)
    }

    // MARK: Graph

    private static func huber(_ value: Double, _ delta: Double) -> Double {
        let a = abs(value)
        return a <= delta ? value : value * (delta / a).squareRoot()
    }

    /// Odometry between neighbours, gravity, and overlap links.
    /// `captured` are the poses as captured (after the phone's own corrections).
    static func addCaptureConstraints(to graph: DriftGraph, captured: [RigidPose], links: [Link],
                                      up: SIMD3<Double> = SIMD3<Double>(0, 1, 0)) {
        let count = captured.count
        if count >= 2 {
            for i in 0..<(count - 1) {
                let a0 = captured[i], b0 = captured[i + 1]
                let rz = a0.r.transpose * b0.r
                let tz = a0.r.transpose * (b0.t - a0.t)
                let angle = simd_length(DriftMath.logSO3(rz))
                let distance = simd_length(tz)
                // Phone tracking keeps the step between two nearby poses very well
                // SIDEWAYS. What drifts is heading (most while turning), length
                // along the walk, and a little height. So a bend is explained by
                // heading, never by sliding a stretch sideways.
                let degree = Double.pi / 180
                let sigmaTurn = 0.08 * degree + 0.015 * angle + 0.04 * degree * distance
                // Turning gives the phone little to triangulate from, so its
                // position loosens too (about 2 cm per radian turned).
                let loose = 0.02 * angle
                let still = 1 / (0.003 + loose)
                var rows = [SIMD3<Double>(still, 0, 0), SIMD3<Double>(0, still, 0), SIMD3<Double>(0, 0, still)]
                if distance > 0.05 {
                    let along = tz / distance
                    let upLocal = a0.r.transpose * up
                    var vertical = upLocal - along * simd_dot(upLocal, along)
                    if simd_length(vertical) < 0.2 {
                        vertical = abs(along.x) < 0.9 ? simd_cross(along, SIMD3<Double>(1, 0, 0))
                                                      : simd_cross(along, SIMD3<Double>(0, 0, 1))
                    }
                    vertical = simd_normalize(vertical)
                    let sideways = simd_cross(along, vertical)
                    rows = [along / (0.003 + 0.008 * distance + loose), vertical / (0.002 + 0.003 * distance + loose),
                            sideways / (0.001 + 0.001 * distance + loose)]
                }
                let weights = rows
                graph.add(nodes: [i, i + 1]) { x in
                    let a = x[i], b = x[i + 1]
                    let er = DriftMath.logSO3(rz.transpose * (a.r.transpose * b.r)) / sigmaTurn
                    let e = a.r.transpose * (b.t - a.t) - tz
                    return [er.x, er.y, er.z, simd_dot(weights[0], e), simd_dot(weights[1], e), simd_dot(weights[2], e)]
                }
            }
        }
        // The phone knows which way is down far better than where it is.
        let sigmaGravity = 0.002
        // Two directions perpendicular to `up`: a correction may not tilt a segment.
        let side = abs(up.y) > 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let e1 = simd_normalize(simd_cross(up, side)), e2 = simd_cross(up, e1)
        for i in 1..<max(1, count) {
            let r0 = captured[i].r
            graph.add(nodes: [i]) { x in
                let d = x[i].r * (r0.transpose * up) - up
                return [simd_dot(d, e1) / sigmaGravity, simd_dot(d, e2) / sigmaGravity]
            }
        }
        let sigmaPoint = 0.01
        for link in links where link.a < count && link.b < count && !link.qa.isEmpty {
            let weight = 1 / sigmaPoint * min(1, (40.0 / Double(link.qa.count)).squareRoot())
            graph.add(nodes: [link.a, link.b]) { x in
                let a = x[link.a], b = x[link.b]
                var out = [Double](repeating: 0, count: link.qa.count)
                for k in 0..<link.qa.count {
                    let p = b.applyInverse(a.apply(link.qa[k]))
                    out[k] = huber(simd_dot(link.nb[k], p - link.qb[k]) * weight, 2.5)
                }
                return out
            }
        }
    }

    /// Mean distance between linked surfaces at the given poses.
    static func mismatch(_ poses: [RigidPose], _ links: [Link]) -> Double {
        var total = 0.0
        var count = 0
        for link in links where link.a < poses.count && link.b < poses.count {
            for k in 0..<link.qa.count {
                let p = poses[link.b].applyInverse(poses[link.a].apply(link.qa[k]))
                total += abs(simd_dot(link.nb[k], p - link.qb[k])); count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    /// Largest distance any segment's own samples move between two pose sets.
    static func largestMove(_ models: [DriftSegmentModel], _ a: [RigidPose], _ b: [RigidPose]) -> Double {
        var out = 0.0
        for (k, model) in models.enumerated() where !model.isEmpty {
            out = max(out, simd_distance(a[k].apply(model.centroid), b[k].apply(model.centroid)))
        }
        return out
    }

    // MARK: Driver

    /// - points: as captured, any order. - segments: segment index per point.
    /// - poses: pose of each segment as captured (world ← segment).
    static func refine(points: [SIMD3<Float>], segments: [UInt16], poses: [RigidPose],
                       options: Options = Options(), cancelled: () -> Bool = { false },
                       progress: (Double) -> Void = { _ in }) -> Outcome {
        let count = poses.count
        var outcome = Outcome(result: .noOverlap, poses: poses)
        guard count >= options.gap + 1, points.count == segments.count else { return outcome }
        let models = buildModels(points: points, segments: segments, poses: poses, options: options)
        progress(0.25)
        if cancelled() { outcome.result = .cancelled; return outcome }

        // 1. In capture order, carrying each correction forward.
        var current = poses
        var carried = RigidPose.identity
        var links: [Link] = []
        var matched = 0
        for j in 0..<count {
            if cancelled() { outcome.result = .cancelled; return outcome }
            current[j] = carried.composed(with: poses[j])
            let older = j - options.gap
            if older >= 0, let found = match(j, models: models, poses: current, modelIDs: Array(0...older),
                                             radii: [0.35, 0.25, 0.15, 0.10], options: options) {
                current[j] = found.correction.composed(with: current[j])
                carried = found.correction.composed(with: carried)
                links.append(contentsOf: found.links)
                matched += 1
            }
            progress(0.25 + 0.45 * Double(j + 1) / Double(count))
        }
        outcome.matchedSegments = matched
        outcome.disagreement = largestMove(models, poses, current)
        guard !links.isEmpty else { return outcome }
        guard outcome.disagreement >= options.noopShift else { outcome.result = .passesAgree; return outcome }
        let before = mismatch(poses, links)
        outcome.mismatchBefore = before
        let firstLinks = links

        // 2. Spread the corrections along the walk; refresh the links once.
        for round in 0..<2 {
            if cancelled() { outcome.result = .cancelled; outcome.poses = poses; return outcome }
            let graph = DriftGraph(poses: current)
            addCaptureConstraints(to: graph, captured: poses, links: links, up: options.up)
            graph.solve(cancelled: cancelled)
            current = graph.x
            progress(0.8 + 0.1 * Double(round))
            if round == 0 {
                var refreshed: [Link] = []
                for j in options.gap..<count {
                    if cancelled() { outcome.result = .cancelled; outcome.poses = poses; return outcome }
                    if let found = match(j, models: models, poses: current, modelIDs: Array(0...(j - options.gap)),
                                         radii: [0.15, 0.10], options: options) {
                        refreshed.append(contentsOf: found.links)
                    }
                }
                if refreshed.isEmpty { break }
                links = refreshed
            }
        }
        // 3. Accept only a clear improvement, judged on the first matches.
        let after = mismatch(current, firstLinks)
        outcome.mismatchAfter = after
        outcome.maxMove = largestMove(models, poses, current)
        for k in 0..<count {
            let turn = simd_length(DriftMath.logSO3(current[k].r * poses[k].r.transpose)) * 180 / .pi
            outcome.maxTurnDegrees = max(outcome.maxTurnDegrees, turn)
        }
        guard after.isFinite, after <= 0.6 * before, outcome.maxMove.isFinite,
              current.allSatisfy({ $0.t.x.isFinite && $0.t.y.isFinite && $0.t.z.isFinite }) else {
            outcome.result = .noImprovement
            return outcome
        }
        outcome.result = .applied
        outcome.poses = current
        outcome.links = links
        progress(1)
        return outcome
    }

    /// Moves every point with its segment from `from` poses to `to` poses.
    static func move(points: [SIMD3<Float>], segments: [UInt16], from: [RigidPose], to: [RigidPose]) -> [SIMD3<Float>] {
        guard from.count == to.count, points.count == segments.count else { return points }
        // One rigid transform per segment: to ∘ from⁻¹.
        var transforms: [RigidPose?] = []
        transforms.reserveCapacity(from.count)
        for k in 0..<from.count {
            let delta = to[k].composed(with: from[k].inverse)
            let size = delta.magnitude
            // Bit-exact when nothing changed.
            transforms.append(size.angle < 1e-9 && size.shift < 1e-7 ? nil : delta)
        }
        var out = points
        for i in 0..<points.count {
            let s = Int(segments[i])
            guard s < transforms.count, let transform = transforms[s] else { continue }
            let p = transform.apply(points[i])
            out[i] = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
        }
        return out
    }
}
