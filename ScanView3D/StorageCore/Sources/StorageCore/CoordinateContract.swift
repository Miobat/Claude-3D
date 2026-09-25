import Foundation

final class ExportCancellation {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
    func reset() { lock.lock(); defer { lock.unlock() }; cancelled = false }
    func check() throws { if isCancelled { throw CancellationError() } }
}

/// Stored separately from a display camera. Matrices are column-major, acting
/// on column vectors; coordinates remain local unless a future control solution
/// explicitly supplies a map transform. Phone GPS is never that transform.
struct CoordinateProvenance: Codable, Equatable {
    enum ScaleStatus: String, Codable {
        case lidarMetric, cameraPoseAligned, estimatedFromBounds, unknown, legacyUnverified
    }
    var version = 1
    var sourceKind: String
    var scaleStatus: ScaleStatus
    var alignmentMethod: String
    var alignmentRMSErrorMetres: Double?
    var matchedCameraCount: Int?
    var captureToLocal: [Double]?
    var localDatum: String
}

enum CoordinateError: LocalizedError {
    case invalidTransform, unsupportedArchive, archiveTooLarge, incompleteExport, unknownScale
    var errorDescription: String? {
        switch self {
        case .invalidTransform: return "The model has an invalid coordinate transform. Its source files have not been changed."
        case .unsupportedArchive: return "This model could not be packaged as a corrected USDZ. The original has been kept."
        case .archiveTooLarge: return "This export exceeds the supported 4 GB archive limit."
        case .incompleteExport: return "The export could not be completed or verified. No partial export was shared."
        case .unknownScale: return "This model's scale is unverified. Calibrate its units before making a metric CAD export."
        }
    }
}

enum CoordinateMath {
    static let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    static func validated(_ m: [Double]) throws -> [Double] {
        guard m.count == 16, m.allSatisfy({ $0.isFinite }),
              abs(m[3]) < 1e-10, abs(m[7]) < 1e-10, abs(m[11]) < 1e-10, abs(m[15] - 1) < 1e-10 else {
            throw CoordinateError.invalidTransform
        }
        let determinant = m[0] * (m[5] * m[10] - m[9] * m[6])
            - m[4] * (m[1] * m[10] - m[9] * m[2]) + m[8] * (m[1] * m[6] - m[5] * m[2])
        guard determinant.isFinite, abs(determinant) > 1e-15 else { throw CoordinateError.invalidTransform }
        return m
    }
    static func point(_ p: SIMD3<Double>, by m: [Double]) throws -> SIMD3<Double> {
        let m = try validated(m)
        return SIMD3(m[0]*p.x + m[4]*p.y + m[8]*p.z + m[12],
                     m[1]*p.x + m[5]*p.y + m[9]*p.z + m[13],
                     m[2]*p.x + m[6]*p.y + m[10]*p.z + m[14])
    }
    /// Right-handed Y-up → Z-up: X'=X, Y'=-Z, Z'=Y.
    static func zUp(_ p: SIMD3<Double>, millimetres: Bool = false) -> SIMD3<Double> {
        SIMD3(p.x, -p.z, p.y) * (millimetres ? 1000 : 1)
    }
    /// USD uses row vectors. Rows of its matrix are columns of our matrix.
    static func usdMatrix(_ m: [Double]) throws -> String {
        let m = try validated(m)
        return "(" + (0..<4).map { column in
            "(" + (0..<4).map { String(m[column * 4 + $0]) }.joined(separator: ", ") + ")"
        }.joined(separator: ", ") + ")"
    }
}

struct ModelExportManifest: Codable {
    var schemaVersion = 1
    var scanID: UUID
    var sourceRevision: String
    var sourceSHA256: String
    var exportedAt: Date
    var modelFile: String
    var units: String
    var axes: String
    var sourceModelToLocal: [Double]
    var localToExport: [Double]
    var transformsAlreadyAppliedToExport = true
    var provenance: CoordinateProvenance?
    var referenceState = "local — not georeferenced"
    var limitations: [String]
}
