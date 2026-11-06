import Foundation
import simd

/// Validates byte layouts before any SceneKit-backed geometry is read. Counts,
/// offsets and strides come from files; division avoids overflowing on corrupt
/// descriptors, and unaligned loads also support interleaved vertex buffers.
enum GeometryBufferReader {
    static func containsVectors(dataCount: Int, count: Int, offset: Int, stride: Int,
                                vectorBytes: Int = 12) -> Bool {
        guard dataCount >= 0, count >= 0, offset >= 0, offset <= dataCount,
              vectorBytes > 0, stride >= vectorBytes else { return false }
        guard count > 0 else { return true }
        guard vectorBytes <= dataCount - offset else { return false }
        return count == 1 || count - 1 <= (dataCount - offset - vectorBytes) / stride
    }

    static func containsIndices(dataCount: Int, primitiveCount: Int, indicesPerPrimitive: Int,
                                bytesPerIndex: Int) -> Bool {
        guard dataCount >= 0, primitiveCount >= 0, indicesPerPrimitive > 0,
              [1, 2, 4].contains(bytesPerIndex) else { return false }
        return primitiveCount <= dataCount / bytesPerIndex / indicesPerPrimitive
    }

    static func positions(data: Data, count: Int, offset: Int, stride: Int,
                          transform: simd_float4x4) -> [SIMD3<Float>]? {
        guard containsVectors(dataCount: data.count, count: count, offset: offset, stride: stride) else { return nil }
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(count)
        return data.withUnsafeBytes { bytes in
            for i in 0..<count {
                let start = offset + i * stride
                let local = SIMD4<Float>(bytes.loadUnaligned(fromByteOffset: start, as: Float.self),
                    bytes.loadUnaligned(fromByteOffset: start + 4, as: Float.self),
                    bytes.loadUnaligned(fromByteOffset: start + 8, as: Float.self), 1)
                let world = transform * local
                guard world.x.isFinite, world.y.isFinite, world.z.isFinite, world.w.isFinite else { return nil }
                result.append(SIMD3(world.x, world.y, world.z))
            }
            return result
        }
    }
}

/// The viewer uses local Float coordinates and Int32 spatial keys. Reject
/// unrepresentable/extreme geometry without modifying the stored source. Grid
/// density is a display choice, never a change to the measured model.
enum ViewerGeometryLimits {
    static let maximumAbsoluteCoordinate: Float = 1_000_000
    static let maximumGridHalfLines = 64

    struct Bounds {
        let low: SIMD3<Float>
        let high: SIMD3<Float>
        var center: SIMD3<Float> { low * 0.5 + high * 0.5 }
        var extent: SIMD3<Float> { high - low }
    }
    struct Grid {
        let spacing: Float
        let half: Float
        let halfLines: Int
    }

    static func accepts(_ point: SIMD3<Float>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite &&
            abs(point.x) <= maximumAbsoluteCoordinate && abs(point.y) <= maximumAbsoluteCoordinate &&
            abs(point.z) <= maximumAbsoluteCoordinate
    }

    static func bounds(low: SIMD3<Float>, high: SIMD3<Float>) -> Bounds? {
        guard accepts(low), accepts(high), low.x <= high.x, low.y <= high.y, low.z <= high.z else { return nil }
        return Bounds(low: low, high: high)
    }

    static func grid(low: SIMD3<Float>, high: SIMD3<Float>) -> Grid? {
        guard let bounds = bounds(low: low, high: high) else { return nil }
        let extent = Double(max(bounds.extent.x, bounds.extent.z))
        let nominalSpacing: Double = extent > 40 ? 5 : (extent > 12 ? 1 : 0.5)
        let requestedHalf = max(extent * 0.75, 2)
        // Round up to a multiple of the ordinary spacing. No Float-to-Int
        // conversion occurs until the count is proven finite and <=64.
        let spacing = max(nominalSpacing,
            (requestedHalf / Double(maximumGridHalfLines) / nominalSpacing).rounded(.up) * nominalSpacing)
        let lines = (requestedHalf / spacing).rounded(.up)
        guard lines.isFinite, lines >= 1, lines <= Double(maximumGridHalfLines) else { return nil }
        return Grid(spacing: Float(spacing), half: Float(lines * spacing), halfLines: Int(lines))
    }
}

/// Exact point-cloud picking, with a spatial hierarchy instead of projecting
/// every point through SceneKit on every crosshair update. No point thinning.
final class PointCloudPicker {
    private struct Node {
        let low: SIMD3<Float>
        let high: SIMD3<Float>
        let children: [Int]
        let indices: [Int]
    }
    let points: [SIMD3<Float>]
    private var nodes: [Node] = []
    private var root: Int?

    init(points: [SIMD3<Float>]) {
        self.points = points
        let indices = points.indices.filter {
            let p = points[$0]
            return p.x.isFinite && p.y.isFinite && p.z.isFinite
        }
        if !indices.isEmpty { root = build(indices, depth: 0) }
    }

    private func build(_ indices: [Int], depth: Int) -> Int {
        var low = points[indices[0]], high = low
        for i in indices { low = simd_min(low, points[i]); high = simd_max(high, points[i]) }
        var children: [Int] = []
        if indices.count > 96 && depth < 18 && simd_length(high - low) > 0.0001 {
            let middle = (low + high) * 0.5
            var groups = [[Int]](repeating: [], count: 8)
            for i in indices {
                let p = points[i]
                let bucket = (p.x >= middle.x ? 1 : 0) | (p.y >= middle.y ? 2 : 0) | (p.z >= middle.z ? 4 : 0)
                groups[bucket].append(i)
            }
            for group in groups where !group.isEmpty { children.append(build(group, depth: depth + 1)) }
        }
        let id = nodes.count
        nodes.append(Node(low: low, high: high, children: children, indices: children.isEmpty ? indices : []))
        return id
    }

    /// `projection` maps world to OpenGL clip coordinates; screen has Y down.
    func pick(at tap: SIMD2<Float>, viewport: SIMD2<Float>, projection: simd_float4x4,
              radius: Float = 8) -> SIMD3<Float>? {
        guard let root, viewport.x > 0, viewport.y > 0, radius > 0 else { return nil }
        var pending = [root]
        var candidates: [(Int, Float, Float)] = []
        var nearest = radius
        while let id = pending.popLast() {
            let node = nodes[id]
            var minScreen = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
            var maxScreen = -minScreen
            var inFront = 0
            for corner in 0..<8 {
                let p = SIMD3<Float>(corner & 1 == 0 ? node.low.x : node.high.x,
                                     corner & 2 == 0 ? node.low.y : node.high.y,
                                     corner & 4 == 0 ? node.low.z : node.high.z)
                let c = projection * SIMD4(p, 1)
                if c.w > 0.00001 {
                    inFront += 1
                    let screen = SIMD2((c.x / c.w + 1) * viewport.x / 2, (1 - c.y / c.w) * viewport.y / 2)
                    minScreen = simd_min(minScreen, screen); maxScreen = simd_max(maxScreen, screen)
                }
            }
            if inFront == 0 { continue }
            if inFront == 8 && (tap.x < minScreen.x - radius || tap.x > maxScreen.x + radius ||
                               tap.y < minScreen.y - radius || tap.y > maxScreen.y + radius) { continue }
            pending.append(contentsOf: node.children)
            for i in node.indices {
                let c = projection * SIMD4(points[i], 1)
                guard c.w > 0, c.z >= -c.w, c.z <= c.w else { continue }
                let screen = SIMD2((c.x / c.w + 1) * viewport.x / 2, (1 - c.y / c.w) * viewport.y / 2)
                let d = simd_distance(screen, tap)
                guard d <= radius else { continue }
                nearest = min(nearest, d)
                candidates.append((i, d, c.z / c.w))
            }
        }
        // Depth only resolves the SAME rendered pixel, not an entire finger-sized
        // search disc. The old depth-first ranking jumped to adjacent foreground.
        return candidates.filter { $0.1 <= nearest + 0.75 }
            .min { $0.2 < $1.2 }.map { points[$0.0] }
    }
}

enum WalkGeometry {
    static let eyeHeight: Float = 1.8
    static let maximumStep: Float = 0.25

    static func acceptsGround(previousY: Float, groundY: Float, normalY: Float) -> Bool {
        previousY.isFinite && groundY.isFinite && normalY.isFinite &&
        abs(groundY - previousY) <= maximumStep && abs(normalY) >= 0.75
    }

    /// Rebase the orbit on a surface without moving or turning the camera.
    static func orbitOffset(camera: SIMD3<Float>, pivot: SIMD3<Float>, orientation: simd_quatf) -> SIMD3<Float> {
        orientation.inverse.act(camera - pivot)
    }
}
