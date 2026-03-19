import Foundation

/// Represents a scanning project containing multiple scans
struct Project: Identifiable, Codable {
    let id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var scans: [Scan]
    var thumbnailData: Data?

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.scans = []
        self.thumbnailData = nil
    }

    var scanCount: Int { scans.count }

    var totalVertices: Int {
        scans.reduce(0) { $0 + $1.vertexCount }
    }

    var totalFaces: Int {
        scans.reduce(0) { $0 + $1.faceCount }
    }

    mutating func addScan(_ scan: Scan) {
        scans.append(scan)
        modifiedAt = Date()
    }

    mutating func removeScan(at index: Int) {
        scans.remove(at: index)
        modifiedAt = Date()
    }
}

/// Represents a single 3D scan
struct Scan: Identifiable, Codable {
    let id: UUID
    var name: String
    var createdAt: Date
    var fileName: String
    var vertexCount: Int
    var faceCount: Int
    var fileSize: Int64
    var hasTexture: Bool
    var hasColor: Bool
    var boundingBoxMin: SIMD3<Float>?
    var boundingBoxMax: SIMD3<Float>?

    init(name: String, fileName: String, vertexCount: Int = 0, faceCount: Int = 0, fileSize: Int64 = 0) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.fileName = fileName
        self.vertexCount = vertexCount
        self.faceCount = faceCount
        self.fileSize = fileSize
        self.hasTexture = false
        self.hasColor = false
    }

    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    var dimensions: String? {
        guard let min = boundingBoxMin, let max = boundingBoxMax else { return nil }
        let size = max - min
        return String(format: "%.2f × %.2f × %.2f m", size.x, size.y, size.z)
    }
}

/// Settings for the scanning session
struct ScanSettings: Codable {
    var captureTexture: Bool = true
    var meshDetail: MeshDetail = .medium
    var unit: MeasurementUnit = .meters
    var autoSave: Bool = true

    enum MeshDetail: String, Codable, CaseIterable {
        case low = "Low"
        case medium = "Medium"
        case high = "High"

        var description: String {
            switch self {
            case .low: return "Faster, smaller files"
            case .medium: return "Balanced quality"
            case .high: return "Best detail, larger files"
            }
        }
    }

    enum MeasurementUnit: String, Codable, CaseIterable {
        case meters = "Meters"
        case feet = "Feet"
        case centimeters = "Centimeters"
        case inches = "Inches"

        var abbreviation: String {
            switch self {
            case .meters: return "m"
            case .feet: return "ft"
            case .centimeters: return "cm"
            case .inches: return "in"
            }
        }

        func convert(fromMeters value: Float) -> Float {
            switch self {
            case .meters: return value
            case .feet: return value * 3.28084
            case .centimeters: return value * 100.0
            case .inches: return value * 39.3701
            }
        }
    }
}
