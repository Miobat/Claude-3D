import Foundation
import simd

/// Diagnostics describe the saved mesh's surface area, never completeness of
/// the room/object or measurement accuracy. Optional on legacy Scan records.
struct TextureQualityReport: Codable, Equatable {
    let sharpArea: Double
    let softArea: Double
    let fallbackArea: Double
    let atlasSize: Int
    let atlasScale: Float
    let photoCount: Int

    var totalArea: Double { max(0, sharpArea) + max(0, softArea) + max(0, fallbackArea) }
    func fraction(_ area: Double) -> Double {
        guard totalArea.isFinite, totalArea > 0, area.isFinite else { return 0 }
        return min(1, max(0, area / totalArea))
    }
    var sharpFraction: Double { fraction(sharpArea) }
    var softFraction: Double { fraction(softArea) }
    var fallbackFraction: Double { fraction(fallbackArea) }
}

struct TextureFrameQuality: Equatable {
    var blurPixels: Float = 0
    var clippedFraction: Float = 0
    var darkFraction: Float = 0

    var permitsSharpCoverage: Bool {
        blurPixels.isFinite && blurPixels <= 2.5 && clippedFraction < 0.7 && darkFraction < 0.8
    }
    var weight: Float {
        guard blurPixels.isFinite, clippedFraction.isFinite, darkFraction.isFinite else { return 0 }
        return 1 / (1 + max(0, blurPixels) * 0.25) *
            (1 - min(1, max(0, clippedFraction)) * 0.7) * (1 - min(1, max(0, darkFraction)) * 0.6)
    }
    var lightingHint: String? {
        if clippedFraction > 0.25 { return "Bright areas are losing detail — change your angle" }
        if darkFraction > 0.6 { return "Too dark for clear colour — add even lighting" }
        return nil
    }
    static func measure(luma: [UInt8], blurPixels: Float) -> Self {
        guard !luma.isEmpty else { return Self(blurPixels: blurPixels) }
        return Self(blurPixels: blurPixels,
                    clippedFraction: Float(luma.filter { $0 >= 250 }.count) / Float(luma.count),
                    darkFraction: Float(luma.filter { $0 <= 8 }.count) / Float(luma.count))
    }
}

enum TextureQualityMath {
    static func motionBlur(turn: Double, move: Double, seconds: Double,
                           exposure: Double, focalPixels: Double, distance: Double) -> Double {
        guard [turn, move, seconds, exposure, focalPixels, distance].allSatisfy(\.isFinite),
              seconds > 0, exposure > 0, focalPixels > 0 else { return .infinity }
        return (max(0, turn) + max(0, move) / max(0.15, distance)) / seconds * exposure * focalPixels
    }

    static func viewScore(facing: Float, alignment: Float, centre: Float, distance: Float,
                          quality: TextureFrameQuality) -> Float {
        guard [facing, alignment, centre, distance].allSatisfy(\.isFinite),
              facing > 0.1, alignment > 0.15, distance > 0.05 else { return 0 }
        return min(1, facing) * min(1, alignment) * max(0, centre) * quality.weight /
            max(0.04, distance * distance)
    }

    /// Patch continuity may trade at most 15% of local view quality. Stable
    /// double-buffered callers avoid scan-order-dependent propagation.
    static func canAdopt(current: Float, candidate: Float, currentSharp: Bool, candidateSharp: Bool) -> Bool {
        guard candidate.isFinite, candidate > 0, !(currentSharp && !candidateSharp) else { return false }
        if candidateSharp && !currentSharp { return true }
        return candidate >= max(0, current) * 0.85
    }

    /// Small shared colour palette for regions without a usable photo. Swatches
    /// retain sampled camera colour instead of painting those faces grey.
    static func paletteKey(_ c: SIMD3<Float>) -> Int {
        func q(_ f: Float) -> Int { f.isFinite ? Int((min(1, max(0, f)) * 15).rounded()) : 10 }
        return (q(c.x) << 8) | (q(c.y) << 4) | q(c.z)
    }
    static func paletteColor(_ key: Int) -> SIMD3<Float> {
        SIMD3(Float((key >> 8) & 15), Float((key >> 4) & 15), Float(key & 15)) / 15
    }
    static func linearLuminance(_ c: SIMD3<Float>) -> Float {
        func linear(_ s: Float) -> Float { s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return simd_dot(SIMD3(linear(c.x), linear(c.y), linear(c.z)), SIMD3(0.2126, 0.7152, 0.0722))
    }
}

struct TextureSeamMatch {
    let a: Int
    let b: Int
    /// log(linear luminance of A / B) on the SAME visible world point.
    let logRatio: Float
    let weight: Float
}

enum TextureSeamCorrection {
    /// Bounded exposure-only corrections. Never blend spatially misregistered
    /// images or alter hue. Anchor each connected component independently.
    static func gains(frameCount: Int, matches: [TextureSeamMatch]) -> [Float] {
        guard frameCount > 0 else { return [] }
        let edges = matches.filter {
            $0.a >= 0 && $0.b >= 0 && $0.a < frameCount && $0.b < frameCount && $0.a != $0.b &&
            $0.logRatio.isFinite && $0.weight.isFinite && $0.weight > 0
        }
        var adjacency = [[Int]](repeating: [], count: frameCount)
        for e in edges { adjacency[e.a].append(e.b); adjacency[e.b].append(e.a) }
        var visited = Set<Int>(), anchors = Set<Int>()
        for start in 0..<frameCount where !visited.contains(start) {
            anchors.insert(start); visited.insert(start)
            var stack = [start]
            while let n = stack.popLast() {
                for next in adjacency[n] where visited.insert(next).inserted { stack.append(next) }
            }
        }
        var logs = [Float](repeating: 0, count: frameCount)
        let limit = log(Float(1.25))
        for _ in 0..<32 {
            var sums = [Float](repeating: 0, count: frameCount), weights = sums
            for e in edges {
                let ratio = min(log(Float(2)), max(-log(Float(2)), e.logRatio))
                sums[e.a] += (logs[e.b] - ratio) * e.weight; weights[e.a] += e.weight
                sums[e.b] += (logs[e.a] + ratio) * e.weight; weights[e.b] += e.weight
            }
            for i in 0..<frameCount where !anchors.contains(i) && weights[i] > 0 {
                logs[i] = min(limit, max(-limit, 0.5 * logs[i] + 0.5 * sums[i] / weights[i]))
            }
        }
        return logs.map { exp($0) }
    }
}
