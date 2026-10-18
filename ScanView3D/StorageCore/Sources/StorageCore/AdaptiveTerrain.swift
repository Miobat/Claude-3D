import Foundation
import simd

/// Geometry-driven retention, not ground classification or an accuracy estimate.
/// Used unchanged by the camera worker and the synthetic/native regressions.
final class AdaptiveTerrainSampler {
    struct Observation {
        let position: SIMD3<Float>
        var color: SIMD3<Float> = SIMD3(repeating: 0.7)
        var reliable = true
    }

    struct Sample {
        let position: SIMD3<Float>
        var color: SIMD3<Float>
        var colorCount: Int
        var observations: Int
        var lastFrame: Int
        var averagedColor: SIMD3<Float> { color / Float(colorCount) }
    }

    enum Level: Float {
        case uncertain = -1, detail = 0.05, transition = 0.1, coarse = 0.2
    }

    private struct Plane {
        let center: SIMD3<Float>
        let normal: SIMD3<Float>
        let residual: Float
    }

    private final class Cell {
        var samples: [SIMD3<Int32>: Sample] = [:]
        var level: Level = .uncertain
        var plane: Plane?
        var detailVotes = 0
        var flatVotes = 0
        var lastSeen: Double = 0
        var compacted = false
        var needsRevisit = false
        var retainedCount = 0
    }

    // Eight 128-byte units per parent conservatively cover dictionary/class,
    // plane, history and indexing overhead. Fine samples consume another unit.
    // This budget is separate from (and added to) the existing coverage budget.
    static let parentUnits = 8
    let capacity: Int
    let activeCellLimit: Int
    private var cells: [SIMD3<Int32>: Cell] = [:]
    private var active: Set<SIMD3<Int32>> = []
    private var frameID = 0
    private var frameTime: Double = -.infinity
    private var analysisTime: Double = -.infinity
    private(set) var storageUnits = 0
    private(set) var pointCount = 0
    private(set) var isFull = false
    private(set) var analysisCount = 0
    var budgetFraction: Double { Double(storageUnits) / Double(max(1, capacity)) }
    var activeCellCount: Int { active.count }

    init(capacity: Int, activeCellLimit: Int = 2_000) {
        self.capacity = max(0, capacity)
        self.activeCellLimit = max(1, activeCellLimit)
    }

    /// Batch-first analysis preserves narrow features that a coarse-first grid
    /// would already have discarded. No image/ARFrame is retained here.
    /// Returned flags refer to the input order and gate live coverage at capacity.
    @discardableResult
    func integrate(_ observations: [Observation], camera: SIMD3<Float>, range: Float,
                   timestamp: Double) -> [Bool] {
        var accepted = [Bool](repeating: false, count: observations.count)
        guard timestamp.isFinite, timestamp >= frameTime,
              camera.x.isFinite, camera.y.isFinite, camera.z.isFinite,
              range.isFinite, range >= 0.3, range <= 5 else { return accepted }
        if timestamp - frameTime >= 0.12 { frameID += 1; frameTime = timestamp }
        // Release only surplus cached detail in already classified smooth cells.
        // Uncertain and confirmed detailed geometry is never evicted for memory.
        compactInactive(before: timestamp - 2)
        var touched: Set<SIMD3<Int32>> = []
        for (index, observation) in observations.enumerated() {
            let p = observation.position, color = observation.color
            guard observation.reliable, color.x.isFinite, color.y.isFinite, color.z.isFinite,
                  simd_distance_squared(p, camera) <= range * range,
                  let key = TerrainCapture.key(p, spacing: 0.2),
                  let fineKey = TerrainCapture.key(p, spacing: 0.05) else { continue }
            let cell: Cell
            if let old = cells[key] { cell = old }
            else {
                guard !isFull, storageUnits + Self.parentUnits + 1 <= capacity else {
                    isFull = true; continue
                }
                cell = Cell(); cells[key] = cell; storageUnits += Self.parentUnits
            }
            if var sample = cell.samples[fineKey] {
                if sample.colorCount < 1_000 { sample.color += color; sample.colorCount += 1 }
                if sample.lastFrame != frameID {
                    sample.observations = min(100, sample.observations + 1); sample.lastFrame = frameID
                }
                cell.samples[fineKey] = sample
            } else {
                guard !isFull, storageUnits < capacity else { isFull = true; continue }
                if cell.level == .coarse, let plane = cell.plane,
                   abs(simd_dot(p - plane.center, plane.normal)) > 0.03 {
                    // Newly exposed geometry invalidates a previous smooth claim
                    // immediately. Keep the local detail while collecting evidence.
                    cell.level = .uncertain; cell.flatVotes = 0
                    cell.needsRevisit = cell.compacted; cell.plane = nil
                }
                cell.samples[fineKey] = Sample(position: p, color: color, colorCount: 1,
                                               observations: 1, lastFrame: frameID)
                storageUnits += 1
            }
            cell.lastSeen = timestamp
            active.insert(key); touched.insert(key); accepted[index] = true
        }
        if timestamp - analysisTime >= 0.25 {
            analyse(touched: touched)
            analysisTime = timestamp; analysisCount += 1
        }
        for key in touched { if let cell = cells[key] { updateCount(cell) } }
        trimActiveCache()
        return accepted
    }

    /// No state/geometry changes during a snapshot: failed save/checkpoint retry
    /// gets the same retained observations. Recovery never resumes an old AR frame.
    func snapshot() -> [Sample] {
        var result: [Sample] = []; result.reserveCapacity(pointCount)
        for key in cells.keys.sorted(by: Self.less) {
            if let cell = cells[key] { result.append(contentsOf: retained(cell).map(\.value)) }
        }
        return result
    }

    /// The detail mark requires a nearby retained observation, not merely being
    /// inside a 20 cm parent box. Missing geometry is never painted as detailed.
    func level(at p: SIMD3<Float>) -> Level? {
        guard let key = TerrainCapture.key(p, spacing: 0.2), let cell = cells[key] else { return nil }
        if cell.needsRevisit { return .uncertain }
        guard cell.level == .detail else { return cell.level }
        guard let fine = TerrainCapture.key(p, spacing: 0.05), let sample = cell.samples[fine],
              sample.observations >= 2, simd_distance_squared(sample.position, p) <= 0.04 * 0.04 else {
            return .uncertain
        }
        return .detail
    }

    private static func less(_ a: SIMD3<Int32>, _ b: SIMD3<Int32>) -> Bool {
        if a.x != b.x { return a.x < b.x }
        if a.y != b.y { return a.y < b.y }
        return a.z < b.z
    }

    private func retained(_ cell: Cell) -> [(key: SIMD3<Int32>, value: Sample)] {
        let ordered = cell.samples.sorted { Self.less($0.key, $1.key) }
        if cell.level == .coarse { return Array(ordered.prefix(1)) }
        if cell.level == .transition {
            var seen: Set<SIMD3<Int32>> = []
            return ordered.filter { entry in
                guard let k = TerrainCapture.key(entry.value.position, spacing: 0.1) else { return false }
                return seen.insert(k).inserted
            }
        }
        return ordered // uncertain keeps fine observations, without a detail claim
    }

    private func updateCount(_ cell: Cell) {
        let count = retained(cell).count
        pointCount += count - cell.retainedCount; cell.retainedCount = count
    }

    private func compact(_ key: SIMD3<Int32>) {
        guard let cell = cells[key] else { active.remove(key); return }
        if cell.level == .coarse || cell.level == .transition {
            let keep = retained(cell)
            storageUnits -= cell.samples.count - keep.count
            cell.samples = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            cell.compacted = true
        }
        active.remove(key)
    }

    private func compactInactive(before time: Double) {
        for key in Array(active) where (cells[key]?.lastSeen ?? time) < time { compact(key) }
    }

    private func trimActiveCache() {
        guard active.count > activeCellLimit else { return }
        let oldest = active.sorted {
            let a = cells[$0]?.lastSeen ?? 0, b = cells[$1]?.lastSeen ?? 0
            return a == b ? Self.less($0, $1) : a < b
        }
        for key in oldest.prefix(active.count - activeCellLimit) { compact(key) }
    }

    private func analyse(touched: Set<SIMD3<Int32>>) {
        // Fit before comparing: dictionary/input order must not decide which
        // neighbour has a plane yet. Only repeated observations inform shape.
        for key in touched {
            guard let cell = cells[key] else { continue }
            let points = cell.samples.values.filter { $0.observations >= 2 }.map(\.position)
            if let plane = Self.fit(points) { cell.plane = plane }
        }
        var features: Set<SIMD3<Int32>> = []
        var smooth: Set<SIMD3<Int32>> = []
        for key in touched {
            guard let cell = cells[key], let plane = cell.plane,
                  cell.samples.values.filter({ $0.observations >= 2 }).count >= 6 else { continue }
            var neighbours = 0, changes = 0, support = 0
            let reference = abs(plane.normal.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1)
            let tangent = simd_normalize(simd_cross(plane.normal, reference))
            let bitangent = simd_cross(plane.normal, tangent)
            // 60 cm vertical reach catches adjacent levels of a kerb/ditch; the
            // distance/plane checks prevent comparing unrelated remote surfaces.
            for dx: Int32 in -1...1 { for dy: Int32 in -3...3 { for dz: Int32 in -1...1 {
                if dx == 0 && dy == 0 && dz == 0 { continue }
                let otherKey = key &+ SIMD3(dx, dy, dz)
                guard let other = cells[otherKey]?.plane, other.residual <= 0.012,
                      simd_distance_squared(other.center, plane.center) < 0.5 * 0.5 else { continue }
                neighbours += 1
                let delta = other.center - plane.center
                let u = simd_dot(delta, tangent), v = simd_dot(delta, bitangent)
                if u > 0.08 { support |= 1 }; if u < -0.08 { support |= 2 }
                if v > 0.08 { support |= 4 }; if v < -0.08 { support |= 8 }
                let angle = abs(simd_dot(plane.normal, other.normal))
                let separation = max(abs(simd_dot(other.center - plane.center, plane.normal)),
                                     abs(simd_dot(plane.center - other.center, other.normal)))
                if angle < 0.95 || separation > max(0.03, 4 * max(plane.residual, other.residual)) {
                    changes += 1
                }
            } } }
            // Isolated roughness/vegetation is uncertain, not a semantic edge.
            if neighbours >= 2 && (changes >= 1 || plane.residual > 0.015) { features.insert(key) }
            else if support == 15 && plane.residual <= 0.008 { smooth.insert(key) }
        }
        for key in touched {
            guard let cell = cells[key] else { continue }
            if features.contains(key) {
                cell.detailVotes = min(3, cell.detailVotes + 1); cell.flatVotes = 0
                if cell.detailVotes >= 2 {
                    if cell.level != .detail && cell.compacted { cell.needsRevisit = true }
                    cell.level = .detail // confirmed features are sticky for this capture
                }
            } else if smooth.contains(key) {
                cell.flatVotes = min(4, cell.flatVotes + 1); cell.detailVotes = max(0, cell.detailVotes - 1)
                if cell.flatVotes >= 3 && cell.level == .uncertain { cell.level = .coarse }
            } else { cell.flatVotes = 0; cell.detailVotes = max(0, cell.detailVotes - 1) }
            if cell.needsRevisit && cell.samples.values.filter({ $0.observations >= 3 }).count >= 8 {
                cell.needsRevisit = false
            }
        }
        // A one-parent margin uses 10 cm. Do not replace real fine geometry at a
        // feature with a coarse parent representative or erase a previous edge.
        for key in features where cells[key]?.level == .detail {
            for dx: Int32 in -1...1 { for dy: Int32 in -1...1 { for dz: Int32 in -1...1 {
                guard let neighbour = cells[key &+ SIMD3(dx, dy, dz)], neighbour.level == .coarse else { continue }
                neighbour.level = .transition
                if neighbour.compacted { neighbour.needsRevisit = true }
                updateCount(neighbour)
            } } }
        }
    }

    /// Bounded 3x3 covariance eigensolve in local coordinates. The 80th-percentile
    /// residual ignores an isolated outlier for classification ONLY; no observed
    /// XYZ is averaged, projected onto a plane or removed as an outlier here.
    private static func fit(_ points: [SIMD3<Float>]) -> Plane? {
        guard points.count >= 6, let origin = points.first else { return nil }
        let mean = points.reduce(SIMD3<Double>.zero) { $0 + SIMD3<Double>($1 - origin) } / Double(points.count)
        var a = [Double](repeating: 0, count: 9), vectors: [Double] = [1,0,0, 0,1,0, 0,0,1]
        for point in points {
            let p = SIMD3<Double>(point - origin) - mean
            for i in 0..<3 { for j in 0..<3 { a[i * 3 + j] += p[i] * p[j] / Double(points.count) } }
        }
        for _ in 0..<18 {
            var p = 0, q = 1
            for (i, j) in [(0, 2), (1, 2)] where abs(a[i * 3 + j]) > abs(a[p * 3 + q]) { p = i; q = j }
            if abs(a[p * 3 + q]) < 1e-12 { break }
            let angle = 0.5 * atan2(2 * a[p * 3 + q], a[q * 3 + q] - a[p * 3 + p])
            let c = cos(angle), s = sin(angle)
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
        let axes = (0..<3).sorted { a[$0 * 3 + $0] < a[$1 * 3 + $1] }
        guard a[axes[1] * 3 + axes[1]] > 0.0003 else { return nil } // reject lines/tiny fragments
        let axis = axes[0]
        let n = SIMD3<Float>(Float(vectors[axis]), Float(vectors[3 + axis]), Float(vectors[6 + axis]))
        let center = origin + SIMD3<Float>(mean)
        let residuals = points.map { abs(simd_dot($0 - center, n)) }.sorted()
        return Plane(center: center, normal: n, residual: residuals[min(residuals.count - 1, residuals.count * 4 / 5)])
    }
}
