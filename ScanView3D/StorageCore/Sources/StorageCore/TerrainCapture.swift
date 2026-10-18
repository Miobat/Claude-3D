import Foundation

/// Retained sample density, not sensor resolution or a field-accuracy promise.
enum TerrainSpacing: Int, Codable, CaseIterable {
    case detailed = 50, standard = 100, overview = 200

    var metres: Float { Float(rawValue) / 1000 }
    var label: String { "\(rawValue / 10) cm" }
    var title: String {
        switch self {
        case .detailed: return "Detailed terrain"
        case .standard: return "General terrain"
        case .overview: return "Site overview"
        }
    }

    static func validated(_ millimetres: Float) -> TerrainSpacing {
        guard millimetres.isFinite else { return .standard }
        return allCases.first { Float($0.rawValue) == millimetres } ?? .standard
    }
}

enum TerrainCapture {
    /// Stage 1 deliberately stays bounded through final save/recovery/viewing.
    /// Coverage uses the selected voxel size too; the old 25 mm evidence budget
    /// must not secretly exhaust a sparse scan. No minimum overrides free memory.
    static func limits(spacing: TerrainSpacing, availableMB: Double)
        -> (voxelSize: Float, points: Int, coverageCells: Int) {
        let usable = max(0, min(1_000_000, availableMB.isFinite ? availableMB : 0) - 600)
        let entries = usable * 1_048_576 * 0.35 / CaptureBudget.bytesPerEntry
        let capacity = min(2_000_000, Int(entries / 2))
        return (spacing.metres, capacity, capacity)
    }

    /// Match the capture voxel key, including negative coordinates. A voxel is
    /// only a sampling bin: it is never treated as an observed solid volume.
    static func key(_ point: SIMD3<Float>, spacing: Float) -> SIMD3<Int32>? {
        guard spacing.isFinite, spacing > 0 else { return nil }
        let q = point / spacing
        guard q.x.isFinite, q.y.isFinite, q.z.isFinite,
              abs(q.x) < 10_000_000, abs(q.y) < 10_000_000, abs(q.z) < 10_000_000 else { return nil }
        return SIMD3(Int32(floor(q.x)), Int32(floor(q.y)), Int32(floor(q.z)))
    }

    /// Preserve gravity, yaw, metre scale and slopes. Never fit a "floor" to an
    /// outdoor slope. This translation is already baked into saved PLY positions.
    static func localFrame(minimum: SIMD3<Float>, maximum: SIMD3<Float>) throws -> [Double] {
        guard [minimum.x, minimum.y, minimum.z, maximum.x, maximum.y, maximum.z].allSatisfy({ $0.isFinite }),
              minimum.x <= maximum.x, minimum.y <= maximum.y, minimum.z <= maximum.z else {
            throw CoordinateError.invalidTransform
        }
        var m = CoordinateMath.identity
        m[12] = -(Double(minimum.x) + Double(maximum.x)) / 2
        m[13] = -Double(minimum.y)
        m[14] = -(Double(minimum.z) + Double(maximum.z)) / 2
        return m
    }
}

/// Optional library metadata; remains with the normal scan transaction and copies.
struct TerrainCaptureMetadata: Codable, Equatable {
    var version = 1
    var spacing: TerrainSpacing
    var captureRangeMetres: Float

    enum Failure: LocalizedError {
        case unsupportedVersion
        var errorDescription: String? { "This terrain metadata version is not supported by this app." }
    }

    func normalized() throws -> Self {
        guard version == 1 else { throw Failure.unsupportedVersion }
        var result = self
        result.captureRangeMetres = try CaptureRangeSetting.normalized(captureRangeMetres)
        return result
    }

    func validate() throws { _ = try normalized() }
}

/// Optional terrain.json alongside model.ply and coordinates.json in a delivery.
/// All fields describe the EXPORTED bytes. The coordinate matrix must not be
/// applied again. No ground classification, gap-filling or surveyed datum is implied.
struct TerrainExportManifest: Codable {
    var schema = "com.tinycorp.tinyscanner.terrain"
    var schemaVersion = 1
    var modelFile: String
    var modelSHA256: String
    var coordinatesFile = "coordinates.json"
    var units = "metres"
    var upAxis = "Y"
    var handedness = "right"
    var coordinateFrame = "scanLocal"
    var transformsAlreadyApplied = true
    var spacingMetres: Float
    var pointCount: Int
    var captureRangeMetres: Float
    var sampling = "oneObservedPointPerCaptureVoxel"
    var groundClassification = "unclassified"
    var coverage = "retainedSamplesOnly"
    var interpolated = false
    var unknownAreas = "notReconstructed"
    var verticalDatum = "localLowestObservedSampleNotSurveyedGround"
    var registrationRequired = true
    var limitations = [
        "Spacing is a capture voxel size, not guaranteed point separation or measurement accuracy.",
        "Points include non-ground surfaces. Ground selection belongs to the terrain processor.",
        "No observed footprint or free-space mask is supplied. Do not fill the bounding box or convex hull blindly.",
        "Coordinates are local metres. Phone GPS and compass are not survey control.",
        "No interpolation or plane levelling has been applied. Check independent reference points."
    ]

    init(metadata: TerrainCaptureMetadata, modelFile: String, modelSHA256: String, pointCount: Int) throws {
        let metadata = try metadata.normalized()
        guard modelFile == (modelFile as NSString).lastPathComponent, modelFile.hasSuffix(".ply"),
              !modelFile.contains("\\"), !modelFile.contains(":"),
              modelSHA256.count == 64, modelSHA256.allSatisfy({ $0.isHexDigit }), pointCount > 0 else {
            throw CoordinateError.incompleteExport
        }
        self.modelFile = modelFile
        self.modelSHA256 = modelSHA256
        self.spacingMetres = metadata.spacing.metres
        self.captureRangeMetres = metadata.captureRangeMetres
        self.pointCount = pointCount
    }
}

/// Save failures must identify the stage instead of claiming that a share failed.
enum PointCloudSaveError: LocalizedError, Equatable {
    case noPoints, colorCountMismatch, nonFinitePosition, nonFiniteColor, nativeSceneWriteFailed

    var errorDescription: String? {
        switch self {
        case .noPoints: return "There are no captured points to save."
        case .colorCountMismatch: return "The point cloud has a different number of colours and positions."
        case .nonFinitePosition: return "The point cloud contains an invalid position."
        case .nonFiniteColor: return "The point cloud contains an invalid colour value."
        case .nativeSceneWriteFailed: return "The in-app viewer file could not be saved. The scan was not added to the library."
        }
    }
}

/// Stream binary PLY to a sibling staging file. A failed write never exposes a
/// truncated model. Explicit replacement is used only for retryable derived splat
/// files, after the complete staged file has been synchronized.
enum PointCloudPLYWriter {
    static func write(positions: [SIMD3<Float>], colors: [SIMD4<Float>], to destination: URL,
                      replacingExisting: Bool = false) throws {
        guard !positions.isEmpty else { throw PointCloudSaveError.noPoints }
        guard colors.isEmpty || colors.count == positions.count else {
            throw PointCloudSaveError.colorCountMismatch
        }
        let fm = FileManager.default
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".ply-\(UUID().uuidString).partial")
        guard fm.createFile(atPath: staged.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        var complete = false
        defer { if !complete { try? fm.removeItem(at: staged) } }
        let output = try FileHandle(forWritingTo: staged)
        defer { try? output.close() }
        var header = "ply\nformat binary_little_endian 1.0\ncomment TinyScanner by TinyCorp Point Cloud\n"
        header += "element vertex \(positions.count)\nproperty float x\nproperty float y\nproperty float z\n"
        if !colors.isEmpty { header += "property uchar red\nproperty uchar green\nproperty uchar blue\n" }
        header += "end_header\n"
        try output.write(contentsOf: Data(header.utf8))
        var buffer = Data(); buffer.reserveCapacity(65_536)
        for i in positions.indices {
            let p = positions[i]
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { throw PointCloudSaveError.nonFinitePosition }
            for value in [p.x, p.y, p.z] {
                let b = value.bitPattern
                buffer.append(contentsOf: [UInt8(truncatingIfNeeded: b), UInt8(truncatingIfNeeded: b >> 8),
                    UInt8(truncatingIfNeeded: b >> 16), UInt8(truncatingIfNeeded: b >> 24)])
            }
            if !colors.isEmpty {
                let c = colors[i]
                guard c.x.isFinite, c.y.isFinite, c.z.isFinite else { throw PointCloudSaveError.nonFiniteColor }
                buffer.append(contentsOf: [c.x, c.y, c.z].map { UInt8(max(0, min(255, $0 * 255))) })
            }
            if buffer.count >= 65_520 { try output.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        if !buffer.isEmpty { try output.write(contentsOf: buffer) }
        try output.synchronize()
        try output.close()
        if replacingExisting && fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } else {
            // Library saves use fresh destinations; refuse accidental overwrite.
            try fm.moveItem(at: staged, to: destination)
        }
        complete = true
    }
}
