import Foundation
import simd

/// Distance means a sphere around the camera, not the depth sensor's optical Z.
enum CaptureRange {
    static func accepts(_ cameraPoint: SIMD3<Float>, metres: Float) -> Bool {
        metres.isFinite && metres > 0 && cameraPoint.x.isFinite && cameraPoint.y.isFinite &&
        cameraPoint.z.isFinite && cameraPoint.z < -0.1 && simd_length_squared(cameraPoint) <= metres * metres
    }
}

/// A conservative, image-aligned mask. Kept in the existing pose sidecar so
/// recovery, duplication, moving and deletion retain the exact capture boundary.
struct PhotoRangeMask: Codable, Equatable {
    let width: Int
    let height: Int
    let pixels: Data
    let rangeMetres: Float

    init(width: Int, height: Int, pixels: Data, rangeMetres: Float) {
        self.width = width; self.height = height; self.pixels = pixels; self.rangeMetres = rangeMetres
    }

    private enum CodingKeys: String, CodingKey { case width, height, pixels, runs, rangeMetres }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        rangeMetres = try c.decode(Float.self, forKey: .rangeMetres)
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              rangeMetres.isFinite, rangeMetres > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .width, in: c, debugDescription: "Invalid range mask dimensions")
        }
        if let runs = try c.decodeIfPresent(Data.self, forKey: .runs) {
            let bytes = [UInt8](runs)
            guard bytes.count % 3 == 0 else {
                throw DecodingError.dataCorruptedError(forKey: .runs, in: c, debugDescription: "Truncated mask run")
            }
            var decoded = Data()
            decoded.reserveCapacity(width * height)
            for i in stride(from: 0, to: bytes.count, by: 3) {
                let count = Int(bytes[i + 1]) | (Int(bytes[i + 2]) << 8)
                guard count > 0, decoded.count + count <= width * height else {
                    throw DecodingError.dataCorruptedError(forKey: .runs, in: c, debugDescription: "Mask run exceeds image")
                }
                decoded.append(Data(repeating: bytes[i], count: count))
            }
            pixels = decoded
        } else { pixels = try c.decode(Data.self, forKey: .pixels) }
        guard pixels.count == width * height else {
            throw DecodingError.dataCorruptedError(forKey: .pixels, in: c, debugDescription: "Mask size mismatch")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width); try c.encode(height, forKey: .height)
        try c.encode(rangeMetres, forKey: .rangeMetres)
        // Binary masks have long runs. Compact sidecars avoid repeatedly writing
        // tens of megabytes while capturing photos; decoded size is bounded above.
        let bytes = [UInt8](pixels)
        var runs = Data(), i = 0
        while i < bytes.count {
            var end = i + 1
            while end < bytes.count && end - i < 65535 && bytes[end] == bytes[i] { end += 1 }
            let length = end - i
            runs.append(contentsOf: [bytes[i], UInt8(length & 255), UInt8(length >> 8)])
            i = end
        }
        if runs.count < pixels.count { try c.encode(runs, forKey: .runs) }
        else { try c.encode(pixels, forKey: .pixels) }
    }

    var isValid: Bool {
        width > 0 && height > 0 && width <= 4096 && height <= 4096 &&
        pixels.count == width * height && rangeMetres.isFinite && rangeMetres > 0
    }

    /// Erode one sensor pixel: interpolation must not leak background into an
    /// accepted foreground edge. Unknown / low-confidence depth stays excluded.
    func eroded() -> PhotoRangeMask {
        guard isValid else { return self }
        let source = [UInt8](pixels)
        var result = [UInt8](repeating: 0, count: source.count)
        if width > 2 && height > 2 {
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    var valid = true
                    for dy in -1...1 {
                        for dx in -1...1 where source[(y + dy) * width + x + dx] == 0 { valid = false }
                    }
                    if valid { result[y * width + x] = 255 }
                }
            }
        }
        return PhotoRangeMask(width: width, height: height, pixels: Data(result), rangeMetres: rangeMetres)
    }
}

/// Persistent evidence of surfaces actually observed inside the selected range.
/// A walked camera path alone is NOT evidence that a surface was captured.
struct CapturedSurfaceIndex {
    struct Sample {
        let point: SIMD3<Float>
        let camera: SIMD3<Float>
        let range: Float
        /// Sampled camera colour survives lightweight recovery checkpoints.
        let color: SIMD3<Float>
        var photoID: Int?
    }
    private(set) var cells: [SIMD3<Int32>: Sample] = [:]
    let cellSize: Float
    let capacity: Int
    private var retainedPhotos: Set<Int> = []

    init(cellSize: Float = 0.025, capacity: Int = 600_000) {
        self.cellSize = max(0.005, cellSize)
        self.capacity = max(1, capacity)
    }

    private func key(_ p: SIMD3<Float>) -> SIMD3<Int32>? {
        let q = p / cellSize
        guard q.x.isFinite, q.y.isFinite, q.z.isFinite,
              abs(q.x) < 10_000_000, abs(q.y) < 10_000_000, abs(q.z) < 10_000_000 else { return nil }
        return SIMD3(Int32(floor(q.x)), Int32(floor(q.y)), Int32(floor(q.z)))
    }

    @discardableResult
    mutating func insert(_ p: SIMD3<Float>, camera: SIMD3<Float>, range: Float,
                         color: SIMD3<Float> = SIMD3(repeating: 0.7)) -> Bool {
        guard range.isFinite, range > 0, simd_distance_squared(p, camera) <= range * range,
              let k = key(p) else { return false }
        // Preserve prior observations at capacity, never invent new coverage.
        let previous = cells[k]
        guard previous != nil || cells.count < capacity else { return false }
        cells[k] = Sample(point: p, camera: camera, range: range, color: color, photoID: previous?.photoID)
        return true
    }

    mutating func retainPhotos(_ ids: Set<Int>) { retainedPhotos = ids }

    /// Called only after the JPEG is durable, using THAT photo's owned depth.
    /// A photo cannot invent geometry or attach to a different surface in space.
    mutating func markPhotographed(_ p: SIMD3<Float>, photoID: Int) {
        guard retainedPhotos.contains(photoID), let k = key(p), var sample = cells[k],
              simd_distance_squared(sample.point, p) <= 0.035 * 0.035 else { return }
        sample.photoID = photoID
        cells[k] = sample
    }

    /// Constant-time photo query for the live mask. Do not borrow a neighbour's
    /// photo claim: absence should invite another photograph, not paint mint.
    func isPhotographed(_ p: SIMD3<Float>) -> Bool {
        guard let k = key(p), let s = cells[k], let id = s.photoID else { return false }
        return retainedPhotos.contains(id) && simd_distance_squared(s.point, p) <= 0.035 * 0.035 &&
            simd_distance_squared(s.camera, p) <= s.range * s.range
    }

    func sample(at p: SIMD3<Float>, tolerance: Float = 0.04, requirePhoto: Bool = false) -> Sample? {
        guard let k = key(p), tolerance.isFinite, tolerance >= 0 else { return nil }
        func matches(_ s: Sample) -> Bool {
            (!requirePhoto || s.photoID.map { retainedPhotos.contains($0) } == true) &&
            simd_distance_squared(s.point, p) <= tolerance * tolerance &&
            simd_distance_squared(s.camera, p) <= s.range * s.range
        }
        if let s = cells[k], matches(s) { return s }
        let reach = min(8, Int32(ceil(tolerance / cellSize)))
        for dx in -reach...reach {
            for dy in -reach...reach {
                for dz in -reach...reach {
                    guard let s = cells[k &+ SIMD3(dx, dy, dz)], matches(s) else { continue }
                    return s
                }
            }
        }
        return nil
    }

    func contains(_ p: SIMD3<Float>, tolerance: Float = 0.04, requirePhoto: Bool = false) -> Bool {
        sample(at: p, tolerance: tolerance, requirePhoto: requirePhoto) != nil
    }

    /// One observation sphere must contain the whole triangle (a convex set).
    /// A single in-range corner must never admit two out-of-range corners.
    static func withinObservedRange(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                                    observations: [Sample]) -> Bool {
        observations.contains { s in
            [a, b, c].allSatisfy { simd_distance_squared($0, s.camera) <= s.range * s.range }
        }
    }
}

/// Reserve memory for checkpointing and final save, not only accumulation.
enum CaptureBudget {
    static let bytesPerEntry = 128.0
    static func limits(dense: Bool, detailMM: Float, availableMB: Double)
        -> (voxelSize: Float, points: Int, coverageCells: Int) {
        let spacing = dense ? max(0.004, detailMM.isFinite ? detailMM / 1000 : 0.01) : 0.025
        let usableMB = max(0, min(1_000_000, availableMB.isFinite ? availableMB : 0) - 600)
        let entries = usableMB * 1_048_576 * 0.35 / bytesPerEntry
        let coverageDensity = 1600.0
        let pointDensity = dense ? 1 / Double(spacing * spacing) : 0
        let area = entries / (coverageDensity + pointDensity)
        return (spacing, dense ? min(4_000_000, Int(area * pointDensity)) : 0,
                min(3_000_000, Int(area * coverageDensity)))
    }
}
