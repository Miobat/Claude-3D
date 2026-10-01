import Foundation
import simd

/// Counts describe stages of the captured mesh, NOT completeness of a room.
/// The original is already range/confidence filtered; it is not raw ARKit data.
struct MeshRetentionReport: Codable, Equatable {
    struct Stage: Codable, Equatable {
        let vertices: Int
        let faces: Int
        let area: Double
    }
    let cleanup: String
    let captured: Stage
    let cleaned: Stage
    let saved: Stage

    var removedAreaFraction: Double {
        guard captured.area.isFinite, saved.area.isFinite, captured.area > 0 else { return 0 }
        return min(1, max(0, 1 - saved.area / captured.area))
    }
}

enum MeshRetentionPolicy {
    /// Sparse wall patches and narrow lamp stems are not debris simply because
    /// ARKit represented them with few vertices. Require physical smallness too.
    static func keepComponent(vertices: Int, minimumVertices: Int, area: Float, extent: SIMD3<Float>) -> Bool {
        vertices >= minimumVertices || area >= 0.01 || max(extent.x, max(extent.y, extent.z)) >= 0.12
    }
}

/// Values are shared with the Metal shader; range blur remains active in Off.
enum CaptureOverlayMode: String, CaseIterable {
    case combined = "Combined", shape = "Shape", photos = "Photos", off = "Off"
    func shaderValue(hasPhotos: Bool) -> Float {
        if self == .off { return 0 }
        if !hasPhotos || self == .shape { return 1 }
        return self == .photos ? 3 : 2
    }
}
