import Foundation
import simd

/// Categories are hints, not object identities. Unknown/future values stay unknown.
enum SurfaceCategory: UInt8, Codable {
    case unknown = 0, wall = 1, floor = 2, ceiling = 3
    case table = 4, seat = 5, window = 6, door = 7
}

/// Streaming face remap: one output byte per kept triangle, not an extra array
/// of Int indices (eight times larger). Missing/invalid labels stay shape-only.
struct FaceLabelAccumulator {
    private let source: Data?
    private(set) var data: Data?

    init(classifications: Data?, faceCount: Int) {
        let validated = classifications?.count == faceCount ? classifications : nil
        source = validated
        data = validated == nil ? nil : Data()
    }

    mutating func keep(_ face: Int) {
        guard let source, data != nil else { return }
        guard face >= 0, face < source.count else { data = nil; return }
        data?.append(source[source.startIndex + face])
    }

    /// Clustering can fold conflicting classifications onto the same triangle.
    mutating func mergeDuplicate(_ face: Int, into outputFace: Int) {
        guard let source, let count = data?.count else { return }
        guard face >= 0, face < source.count, outputFace >= 0, outputFace < count else { data = nil; return }
        if data?[outputFace] != source[source.startIndex + face] { data?[outputFace] = SurfaceCategory.unknown.rawValue }
    }
}

enum AutomaticMeasurementError: LocalizedError {
    case invalidGeometry, invalidDocument, unsupportedVersion, staleModel, unconfirmedWall, unverifiedScale

    var errorDescription: String? {
        switch self {
        case .invalidGeometry: return "The selected geometry cannot support these dimensions."
        case .invalidDocument: return "The measurement data is invalid. The original file has been preserved."
        case .unsupportedVersion: return "These measurements were saved by a newer app. The original file has been preserved."
        case .staleModel: return "The model, opened geometry or alignment has changed. Review the automatic measurements before using them."
        case .unconfirmedWall: return "Confirm that the object is flush to the wall before using wall-based depth."
        case .unverifiedScale: return "This model's scale is unverified or estimated. Calibrate it before automatic metric measurement."
        }
    }
}

/// One byte per KEPT triangle, in saved mesh / native viewer triangle order.
/// Bound to both files: labels must never be applied to a rebuilt/reordered mesh.
struct SurfaceLabelDocument: Codable, Equatable {
    static let suffix = "_surfaces.json"
    var version = 1
    var modelSHA256: String
    var viewerSHA256: String
    var faceCount: Int
    var classifications: Data

    func validate() throws {
        guard version == 1 else { throw AutomaticMeasurementError.unsupportedVersion }
        guard MeasurementModelRevision.validHash(modelSHA256), MeasurementModelRevision.validHash(viewerSHA256),
              faceCount >= 0, faceCount <= 16_000_000, classifications.count == faceCount else {
            throw AutomaticMeasurementError.invalidDocument
        }
    }

    func category(at face: Int) -> SurfaceCategory {
        guard face >= 0, face < classifications.count else { return .unknown }
        return SurfaceCategory(rawValue: classifications[classifications.startIndex + face]) ?? .unknown
    }

    /// Missing labels remain missing; an incorrect mapping is rejected, not truncated.
    static func retaining(_ indices: [Int], from labels: Data?, originalFaceCount: Int) throws -> Data? {
        guard let labels else { return nil }
        guard labels.count == originalFaceCount, indices.allSatisfy({ $0 >= 0 && $0 < originalFaceCount }) else {
            throw AutomaticMeasurementError.invalidDocument
        }
        return Data(indices.map { labels[labels.startIndex + $0] })
    }
}

/// Content identity, not a file name: duplicating a scan preserves valid results.
/// Alignment is part of identity because saved measurements are in viewer world space.
struct MeasurementModelRevision: Codable, Equatable {
    var modelSHA256: String
    var worldTransform: [Double]
    var viewerSHA256: String? = nil

    static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    func validate() throws {
        guard Self.validHash(modelSHA256), viewerSHA256.map(Self.validHash) ?? true else {
            throw AutomaticMeasurementError.invalidDocument
        }
        _ = try CoordinateMath.validated(worldTransform)
    }
}

/// Bounds of a selected region, NOT an object detector. Caller must first isolate
/// the object and reject disconnected noise. No percentile trim: real handles and
/// feet must not silently disappear from overall dimensions.
struct UprightMeasurementBounds: Codable, Equatable {
    var center: SIMD3<Float>
    var right: SIMD3<Float>
    var front: SIMD3<Float>
    var size: SIMD3<Float>   // width, height, depth in metres

    static func fit(points: [SIMD3<Float>], front direction: SIMD3<Float>) throws -> Self {
        guard !points.isEmpty, points.allSatisfy(finite), finite(direction) else {
            throw AutomaticMeasurementError.invalidGeometry
        }
        let horizontal = SIMD3<Float>(direction.x, 0, direction.z)
        guard simd_length(horizontal) > 0.0001 else { throw AutomaticMeasurementError.invalidGeometry }
        let front = simd_normalize(horizontal)
        let right = simd_cross(SIMD3<Float>(0, 1, 0), front)
        // Work relative to a real point to reduce cancellation far from the origin.
        let origin = points[0]
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for point in points {
            let p = point - origin
            let local = SIMD3<Float>(simd_dot(p, right), p.y, simd_dot(p, front))
            low = simd_min(low, local); high = simd_max(high, local)
        }
        let middle = low * 0.5 + high * 0.5
        let result = Self(center: origin + right * middle.x + SIMD3<Float>(0, middle.y, 0) + front * middle.z,
                          right: right, front: front, size: high - low)
        try result.validate()
        return result
    }

    /// Height belongs to the object, even for a wall-mounted or raised cabinet.
    var bottom: Float { center.y - size.y * 0.5 }
    var top: Float { center.y + size.y * 0.5 }

    func corners() -> [SIMD3<Float>] {
        (0..<8).map { i in
            center + right * (size.x * (i & 1 == 0 ? -0.5 : 0.5))
                + SIMD3<Float>(0, size.y * (i & 2 == 0 ? -0.5 : 0.5), 0)
                + front * (size.z * (i & 4 == 0 ? -0.5 : 0.5))
        }
    }

    func validate() throws {
        guard Self.finite(center), Self.finite(right), Self.finite(front), Self.finite(size),
              size.x >= 0, size.y >= 0, size.z >= 0,
              abs(right.y) < 0.0001, abs(front.y) < 0.0001,
              abs(simd_length(right) - 1) < 0.001, abs(simd_length(front) - 1) < 0.001,
              abs(simd_dot(right, front)) < 0.001,
              simd_dot(simd_cross(right, SIMD3<Float>(0, 1, 0)), front) > 0.999 else {
            throw AutomaticMeasurementError.invalidGeometry
        }
    }

    private static func finite(_ p: SIMD3<Float>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite }
}

struct AutomaticDimension: Codable, Equatable {
    enum Axis: String, Codable, CaseIterable, Hashable { case width, height, depth }
    enum Evidence: String, Codable {
        case observedSpan, partial, assumedFlushToWall, adjusted, unavailable
    }
    var axis: Axis
    var metres: Float?
    var evidence: Evidence
    var wallContactConfirmed: Bool? = nil

    func validate() throws {
        if evidence == .unavailable {
            guard metres == nil else { throw AutomaticMeasurementError.invalidDocument }
        } else {
            guard let metres, metres.isFinite, metres > 0 else { throw AutomaticMeasurementError.invalidDocument }
        }
        if evidence == .assumedFlushToWall && wallContactConfirmed != true {
            throw AutomaticMeasurementError.unconfirmedWall
        }
    }
}

/// A reviewed selection's data contract. Detectors must supply evidence separately:
/// a bounding box alone cannot prove that any dimension is complete.
struct AutomaticMeasuredRegion: Codable, Equatable, Identifiable {
    /// Distance from the observed front to a fitted background wall. This is a
    /// separate quantity: it includes any unseen air gap behind the object.
    struct WallProjection: Codable, Equatable {
        let metres: Float
        let wallPoint: SIMD3<Float>
    }
    enum Kind: String, Codable { case object, room }
    var id = UUID()
    var name: String
    var kind: Kind
    var bounds: UprightMeasurementBounds
    var dimensions: [AutomaticDimension]
    var createdAt = Date()
    var selection: AutomaticRegionSelection? = nil
    var wallProjection: WallProjection? = nil

    var usesWallProjectionForDisplay: Bool {
        wallProjection != nil && dimensions.first(where: { $0.axis == .depth })?.metres == nil
    }
    var displayBounds: UprightMeasurementBounds {
        guard usesWallProjectionForDisplay, let wallProjection else { return bounds }
        var result = bounds
        result.center -= bounds.front * ((wallProjection.metres - bounds.size.z) * 0.5)
        result.size.z = wallProjection.metres
        return result
    }

    func validate() throws {
        try bounds.validate()
        try selection?.validate()
        if let projection = wallProjection {
            let p = projection.wallPoint
            let expected = bounds.center + bounds.front * (bounds.size.z * 0.5 - projection.metres)
            guard projection.metres.isFinite, projection.metres > bounds.size.z,
                  projection.metres <= bounds.size.z + 1.5,
                  p.x.isFinite, p.y.isFinite, p.z.isFinite,
                  simd_distance(p, expected) < 0.001 else { throw AutomaticMeasurementError.invalidDocument }
        }
        guard name.count <= 200, createdAt.timeIntervalSince1970.isFinite, dimensions.count == 3,
              Set(dimensions.map(\.axis)).count == 3 else { throw AutomaticMeasurementError.invalidDocument }
        for dimension in dimensions {
            try dimension.validate()
            let span: Float
            switch dimension.axis { case .width: span = bounds.size.x; case .height: span = bounds.size.y; case .depth: span = bounds.size.z }
            if let value = dimension.metres, abs(value - span) > max(0.0001, span * 0.0001) {
                throw AutomaticMeasurementError.invalidDocument
            }
        }
    }
}

/// Separate from legacy _measurements.json: older app versions cannot erase or
/// fail to load manual measurements because an automatic type was introduced.
struct AutomaticMeasurementDocument: Codable, Equatable {
    static let suffix = "_automatic-measurements.json"
    var version = 1
    var revision: MeasurementModelRevision
    var regions: [AutomaticMeasuredRegion]

    func validate() throws {
        guard version == 1 else { throw AutomaticMeasurementError.unsupportedVersion }
        try revision.validate()
        guard regions.count <= 1000, Set(regions.map(\.id)).count == regions.count else {
            throw AutomaticMeasurementError.invalidDocument
        }
        for region in regions { try region.validate() }
    }

    func validate(for current: MeasurementModelRevision) throws {
        try validate(); try current.validate()
        guard revision == current else { throw AutomaticMeasurementError.staleModel }
    }

    static func decode(_ data: Data) throws -> Self {
        // Read the version FIRST so unfamiliar enum values do not disguise a
        // newer document as corruption. Never replace an unreadable document.
        struct Header: Decodable { let version: Int }
        guard data.count <= 4_000_000 else { throw AutomaticMeasurementError.invalidDocument }
        guard try JSONDecoder().decode(Header.self, from: data).version == 1 else {
            throw AutomaticMeasurementError.unsupportedVersion
        }
        let document = try JSONDecoder().decode(Self.self, from: data)
        try document.validate()
        return document
    }

    func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= 4_000_000 else { throw AutomaticMeasurementError.invalidDocument }
        return data
    }
}
