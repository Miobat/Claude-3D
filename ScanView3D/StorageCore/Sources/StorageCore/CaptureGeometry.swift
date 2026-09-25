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
    }
    private(set) var cells: [SIMD3<Int32>: Sample] = [:]
    let cellSize: Float
    let capacity: Int

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
    mutating func insert(_ p: SIMD3<Float>, camera: SIMD3<Float>, range: Float) -> Bool {
        guard range.isFinite, range > 0, simd_distance_squared(p, camera) <= range * range,
              let k = key(p) else { return false }
        // Preserve prior observations at capacity, never invent new coverage.
        guard cells[k] != nil || cells.count < capacity else { return false }
        cells[k] = Sample(point: p, camera: camera, range: range)
        return true
    }

    func contains(_ p: SIMD3<Float>, tolerance: Float = 0.04) -> Bool {
        guard let k = key(p), tolerance.isFinite, tolerance >= 0 else { return false }
        let reach = min(8, Int32(ceil(tolerance / cellSize)))
        for dx in -reach...reach {
            for dy in -reach...reach {
                for dz in -reach...reach {
                    guard let s = cells[k + SIMD3(dx, dy, dz)],
                          simd_distance_squared(s.point, p) <= tolerance * tolerance,
                          simd_distance_squared(s.camera, p) <= s.range * s.range else { continue }
                    return true
                }
            }
        }
        return false
    }
}
