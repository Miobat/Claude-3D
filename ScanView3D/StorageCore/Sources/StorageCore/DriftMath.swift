import Foundation
import simd

/// Rigid transform (world ← local) in double precision. Drift corrections are
/// small differences of large numbers, so Float is not enough for the solver.
struct RigidPose: Equatable {
    var r: simd_double3x3
    var t: SIMD3<Double>

    static let identity = RigidPose(r: matrix_identity_double3x3, t: SIMD3<Double>(0, 0, 0))

    init(r: simd_double3x3, t: SIMD3<Double>) { self.r = r; self.t = t }

    init(_ m: simd_float4x4) {
        r = simd_double3x3(columns: (
            SIMD3<Double>(Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z)),
            SIMD3<Double>(Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z)),
            SIMD3<Double>(Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z))))
        t = SIMD3<Double>(Double(m.columns.3.x), Double(m.columns.3.y), Double(m.columns.3.z))
    }

    /// Column-major 4×4, the convention used by every stored transform in the app.
    init?(array m: [Double]) {
        guard m.count == 16, m.allSatisfy({ $0.isFinite }),
              abs(m[3]) < 1e-9, abs(m[7]) < 1e-9, abs(m[11]) < 1e-9, abs(m[15] - 1) < 1e-9 else { return nil }
        r = simd_double3x3(columns: (SIMD3<Double>(m[0], m[1], m[2]), SIMD3<Double>(m[4], m[5], m[6]),
                                     SIMD3<Double>(m[8], m[9], m[10])))
        t = SIMD3<Double>(m[12], m[13], m[14])
        // Only rigid motions are meaningful here (no scale, shear or mirror).
        let should = r.transpose * r
        let identity = matrix_identity_double3x3
        for c in 0..<3 {
            let d = should[c] - identity[c]
            guard abs(d.x) < 1e-4, abs(d.y) < 1e-4, abs(d.z) < 1e-4 else { return nil }
        }
        guard simd_determinant(r) > 0 else { return nil }
    }

    var array: [Double] {
        [r[0].x, r[0].y, r[0].z, 0, r[1].x, r[1].y, r[1].z, 0, r[2].x, r[2].y, r[2].z, 0, t.x, t.y, t.z, 1]
    }

    var float4x4: simd_float4x4 {
        simd_float4x4(SIMD4<Float>(Float(r[0].x), Float(r[0].y), Float(r[0].z), 0),
                      SIMD4<Float>(Float(r[1].x), Float(r[1].y), Float(r[1].z), 0),
                      SIMD4<Float>(Float(r[2].x), Float(r[2].y), Float(r[2].z), 0),
                      SIMD4<Float>(Float(t.x), Float(t.y), Float(t.z), 1))
    }

    func apply(_ p: SIMD3<Double>) -> SIMD3<Double> { r * p + t }
    func applyInverse(_ p: SIMD3<Double>) -> SIMD3<Double> { r.transpose * (p - t) }
    func apply(_ p: SIMD3<Float>) -> SIMD3<Double> { r * SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)) + t }
    func rotate(_ v: SIMD3<Double>) -> SIMD3<Double> { r * v }
    func rotateInverse(_ v: SIMD3<Double>) -> SIMD3<Double> { r.transpose * v }

    var inverse: RigidPose { RigidPose(r: r.transpose, t: -(r.transpose * t)) }

    /// `self` applied after `other`: (self ∘ other)(p) = self(other(p)).
    func composed(with other: RigidPose) -> RigidPose {
        RigidPose(r: r * other.r, t: r * other.t + t)
    }

    /// Local (right-hand) update used by the solver: rotation first, then shift.
    func boxplus(_ d: [Double], offset: Int = 0) -> RigidPose {
        let w = SIMD3<Double>(d[offset], d[offset + 1], d[offset + 2])
        let v = SIMD3<Double>(d[offset + 3], d[offset + 4], d[offset + 5])
        return RigidPose(r: r * DriftMath.expSO3(w), t: t + r * v)
    }

    /// Rotation angle in radians and shift in metres of this transform.
    var magnitude: (angle: Double, shift: Double) {
        (simd_length(DriftMath.logSO3(r)), simd_length(t))
    }

    /// Removes accumulated rounding so a long chain of products stays a rotation.
    var orthonormalised: RigidPose {
        var x = r[0], y = r[1]
        x = simd_normalize(x)
        y = simd_normalize(y - x * simd_dot(x, y))
        return RigidPose(r: simd_double3x3(columns: (x, y, simd_cross(x, y))), t: t)
    }
}

enum DriftMath {
    static func skew(_ w: SIMD3<Double>) -> simd_double3x3 {
        simd_double3x3(columns: (SIMD3<Double>(0, w.z, -w.y), SIMD3<Double>(-w.z, 0, w.x), SIMD3<Double>(w.y, -w.x, 0)))
    }

    /// Rotation vector → rotation matrix (Rodrigues).
    static func expSO3(_ w: SIMD3<Double>) -> simd_double3x3 {
        let theta = simd_length(w)
        let k = skew(w)
        let identity = matrix_identity_double3x3
        if theta < 1e-9 { return identity + k }
        let a = sin(theta) / theta
        let b = (1 - cos(theta)) / (theta * theta)
        return identity + a * k + b * (k * k)
    }

    /// Rotation matrix → rotation vector. Corrections here are far from 180°.
    static func logSO3(_ r: simd_double3x3) -> SIMD3<Double> {
        let trace = r[0].x + r[1].y + r[2].z
        let c = max(-1, min(1, (trace - 1) / 2))
        let theta = acos(c)
        // (R − Rᵀ) holds the axis; columns are r[col][row].
        let v = SIMD3<Double>(r[1].z - r[2].y, r[2].x - r[0].z, r[0].y - r[1].x)
        if theta < 1e-7 { return v / 2 }
        return v * (theta / (2 * sin(theta)))
    }

    /// Rotation about the vertical (Y) axis.
    static func yaw(_ angle: Double) -> simd_double3x3 {
        let c = cos(angle), s = sin(angle)
        return simd_double3x3(columns: (SIMD3<Double>(c, 0, -s), SIMD3<Double>(0, 1, 0), SIMD3<Double>(s, 0, c)))
    }

    /// Symmetric eigen-decomposition (cyclic Jacobi). `a` is row-major n×n.
    /// Returns ascending eigenvalues and eigenvectors as columns (row-major n×n).
    static func symmetricEigen(_ input: [Double], n: Int) -> (values: [Double], vectors: [Double]) {
        var a = input
        var v = [Double](repeating: 0, count: n * n)
        for i in 0..<n { v[i * n + i] = 1 }
        for _ in 0..<60 {
            var off = 0.0
            for p in 0..<n { for q in (p + 1)..<max(n, p + 1) where q < n { off += a[p * n + q] * a[p * n + q] } }
            if off < 1e-22 { break }
            for p in 0..<(n - 1) {
                for q in (p + 1)..<n {
                    let apq = a[p * n + q]
                    if abs(apq) < 1e-300 { continue }
                    let theta = (a[q * n + q] - a[p * n + p]) / (2 * apq)
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot()
                    let s = t * c
                    for k in 0..<n {
                        let akp = a[k * n + p], akq = a[k * n + q]
                        a[k * n + p] = c * akp - s * akq
                        a[k * n + q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p * n + k], aqk = a[q * n + k]
                        a[p * n + k] = c * apk - s * aqk
                        a[q * n + k] = s * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = v[k * n + p], vkq = v[k * n + q]
                        v[k * n + p] = c * vkp - s * vkq
                        v[k * n + q] = s * vkp + c * vkq
                    }
                }
            }
        }
        let order = (0..<n).sorted { a[$0 * n + $0] < a[$1 * n + $1] }
        var values = [Double](repeating: 0, count: n)
        var vectors = [Double](repeating: 0, count: n * n)
        for (k, source) in order.enumerated() {
            values[k] = a[source * n + source]
            for row in 0..<n { vectors[row * n + k] = v[row * n + source] }
        }
        return (values, vectors)
    }

    /// Solves A·x = b for symmetric positive-definite A (row-major n×n) by
    /// Cholesky factorisation. Returns nil when A is not positive definite.
    static func choleskySolve(_ matrix: [Double], _ rhs: [Double], n: Int) -> [Double]? {
        guard matrix.count == n * n, rhs.count == n else { return nil }
        if n == 0 { return [] }
        var l = matrix
        var failed = false
        l.withUnsafeMutableBufferPointer { a in
            for j in 0..<n {
                var d = a[j * n + j]
                for k in 0..<j { d -= a[j * n + k] * a[j * n + k] }
                if !(d > 1e-300) || !d.isFinite { failed = true; return }
                let root = d.squareRoot()
                a[j * n + j] = root
                if j + 1 < n {
                    for i in (j + 1)..<n {
                        var s = a[i * n + j]
                        let rowI = i * n, rowJ = j * n
                        for k in 0..<j { s -= a[rowI + k] * a[rowJ + k] }
                        a[rowI + j] = s / root
                    }
                }
            }
        }
        if failed { return nil }
        var y = rhs
        for i in 0..<n {
            var s = y[i]
            for k in 0..<i { s -= l[i * n + k] * y[k] }
            y[i] = s / l[i * n + i]
        }
        var x = y
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = x[i]
            if i + 1 < n { for k in (i + 1)..<n { s -= l[k * n + i] * x[k] } }
            x[i] = s / l[i * n + i]
        }
        return x.allSatisfy({ $0.isFinite }) ? x : nil
    }

    /// Gravity is known from the phone, so a fit between two point sets only
    /// needs a turn about the vertical axis and a shift. Takes `a` onto `b`.
    static func yawFit(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>]) -> RigidPose? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        let n = Double(a.count)
        let ca = a.reduce(SIMD3<Double>(0, 0, 0), +) / n
        let cb = b.reduce(SIMD3<Double>(0, 0, 0), +) / n
        var s = 0.0, c = 0.0
        for k in 0..<a.count {
            let p = a[k] - ca, q = b[k] - cb
            s += p.z * q.x - p.x * q.z
            c += p.x * q.x + p.z * q.z
        }
        let r = a.count >= 2 && (abs(s) + abs(c)) > 1e-12 ? yaw(atan2(s, c)) : matrix_identity_double3x3
        return RigidPose(r: r, t: cb - r * ca)
    }
}
