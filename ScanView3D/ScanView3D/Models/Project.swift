import Foundation

/// Represents a scanning project containing multiple scans
struct Project: Identifiable, Codable, Hashable {
    static func == (lhs: Project, rhs: Project) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

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

    var totalFileSize: Int64 {
        scans.reduce(0) { $0 + $1.fileSize }
    }

    var formattedTotalSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalFileSize)
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
    var thumbnailData: Data?
    var notes: String?
    var textureFileName: String?

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

    var shortDimensions: String? {
        guard let min = boundingBoxMin, let max = boundingBoxMax else { return nil }
        let size = max - min
        return String(format: "%.1f×%.1f×%.1fm", size.x, size.y, size.z)
    }

    /// Generate a descriptive auto-name based on date/time
    static func autoName(prefix: String = "Scan") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "\(prefix) \(formatter.string(from: Date()))"
    }
}

/// Settings for the scanning session
struct ScanSettings: Codable {
    var captureTexture: Bool = true
    var meshDetail: MeshDetail = .medium
    var unit: MeasurementUnit = .meters
    var autoSave: Bool = true
    var scanRange: ScanRange = .room
    var scanQuality: ScanQuality = .standard
    var meshMode: MeshMode = .free
    var rangeValue: Float = 3.0       // Continuous range in meters (0.3 - 5.0)
    var confidenceLevel: Int = 1      // 0=Low, 1=Medium, 2=High

    // MARK: - Mesh Mode

    enum MeshMode: String, Codable, CaseIterable {
        case free = "Free"
        case hybrid = "Hybrid"
        case structure = "Structure"
        case area = "Area"

        var description: String {
            switch self {
            case .free: return "Raw mesh, all surfaces captured as-is"
            case .hybrid: return "Align to detected objects while keeping detail"
            case .structure: return "Walls, floors, ceiling, doors, windows"
            case .area: return "Outline only - floor, walls, ceiling"
            }
        }

        var icon: String {
            switch self {
            case .free: return "scribble.variable"
            case .hybrid: return "square.on.square.dashed"
            case .structure: return "building"
            case .area: return "square.dashed"
            }
        }

        /// Which ARMeshClassification types to include in this mode
        func shouldIncludeVertex(classification: UInt8) -> Bool {
            switch self {
            case .free:
                return true // Everything
            case .hybrid:
                return true // Everything, but structure gets priority (handled at export)
            case .structure:
                // Only structural elements + furniture
                guard let cls = ARMeshClassificationCompat(rawValue: Int(classification)) else { return true }
                switch cls {
                case .wall, .floor, .ceiling, .door, .window, .table, .seat:
                    return true
                case .none:
                    return false // Skip unclassified clutter
                }
            case .area:
                // Only room shell - floor, walls, ceiling
                guard let cls = ARMeshClassificationCompat(rawValue: Int(classification)) else { return true }
                switch cls {
                case .wall, .floor, .ceiling:
                    return true
                case .door, .window:
                    return true // Include openings as part of room shell
                case .none, .table, .seat:
                    return false
                }
            }
        }
    }

    // MARK: - Scan Range

    enum ScanRange: String, Codable, CaseIterable {
        case closeUp = "Close-up"
        case near = "Near"
        case room = "Room"
        case extended = "Extended"

        var maxDistance: Float {
            switch self {
            case .closeUp: return 0.5
            case .near: return 1.5
            case .room: return 3.0
            case .extended: return 5.0
            }
        }

        var description: String {
            switch self {
            case .closeUp: return "Small objects, high precision (0.5m)"
            case .near: return "Furniture and desk items (1.5m)"
            case .room: return "Room interiors (3m)"
            case .extended: return "Large spaces (5m)"
            }
        }

        var icon: String {
            switch self {
            case .closeUp: return "scope"
            case .near: return "cube"
            case .room: return "house"
            case .extended: return "building.2"
            }
        }
    }

    // MARK: - Scan Quality

    enum ScanQuality: String, Codable, CaseIterable {
        case preview = "Preview"
        case standard = "Standard"
        case high = "High"
        case ultra = "Ultra"

        var confidenceThreshold: Float {
            switch self {
            case .preview: return 0.3
            case .standard: return 0.5
            case .high: return 0.6
            case .ultra: return 0.7
            }
        }

        var textureCaptureInterval: TimeInterval {
            switch self {
            case .preview: return 3.0
            case .standard: return 2.0
            case .high: return 1.5
            case .ultra: return 1.0
            }
        }

        var maxTextureFrames: Int {
            switch self {
            case .preview: return 10
            case .standard: return 15
            case .high: return 20
            case .ultra: return 25
            }
        }

        var textureAtlasTileSize: Int {
            switch self {
            case .preview: return 512
            case .standard: return 512
            case .high: return 768
            case .ultra: return 768
            }
        }

        /// Width to downscale captured camera frames to (saves memory)
        var textureDownscaleWidth: Int {
            switch self {
            case .preview: return 480
            case .standard: return 640
            case .high: return 960
            case .ultra: return 1280
            }
        }

        var description: String {
            switch self {
            case .preview: return "Fast scan, lower detail"
            case .standard: return "Good balance of speed and detail"
            case .high: return "Detailed scan, slower"
            case .ultra: return "Maximum detail, large files"
            }
        }

        var icon: String {
            switch self {
            case .preview: return "hare"
            case .standard: return "circle.grid.2x2"
            case .high: return "circle.grid.3x3"
            case .ultra: return "sparkles"
            }
        }
    }

    // MARK: - Mesh Detail (kept for backward compatibility)

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

    // MARK: - Measurement Unit

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

/// Platform-independent mesh classification matching ARMeshClassification raw values
/// This allows MeshMode filtering to work without importing ARKit (simulator compatibility)
enum ARMeshClassificationCompat: Int {
    case none = 0
    case wall = 1
    case floor = 2
    case ceiling = 3
    case table = 4
    case seat = 5
    case window = 6
    case door = 7
}
