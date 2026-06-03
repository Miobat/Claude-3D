import Foundation
import simd

/// A captured keyframe's camera pose + intrinsics, paired with a saved photo
/// (by index). Used to export posed images for desktop Gaussian-splat training.
struct CapturedPose {
    let index: Int
    let transform: simd_float4x4   // camera-to-world (ARKit; OpenGL/nerfstudio convention)
    let intrinsics: simd_float3x3  // for the full-res captured image
    let width: Int
    let height: Int
}

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
    // Re-export / re-process support (all optional so existing saved projects
    // keep decoding). Set only for the relevant capture modes.
    var splatBundleName: String?     // zip under the scan dir, re-shareable anytime (Splat mode)
    var captureFolderName: String?   // folder of source photos kept for later re-reconstruction (HQ mode)
    var modelScale: Float?           // uniform metric scale correction for photogrammetry models

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
    var captureMode: CaptureMode = .fast
    var detailMM: Float = 10.0        // Point/mesh grid spacing in mm (5 = fine, 20 = coarse)
    var reconstructQuality: ReconstructQuality = .best  // High-Quality photogrammetry effort

    // MARK: - Reconstruction Quality (High-Quality / photogrammetry)

    /// On-device iOS photogrammetry is capped at `.reduced` mesh detail by Apple,
    /// so this controls reconstruction *effort* (feature matching + how many photos
    /// are used), trading speed against fidelity — not a higher detail tier.
    enum ReconstructQuality: String, Codable, CaseIterable {
        case draft = "Draft"   // fewer photos, normal sensitivity — fastest
        case best = "Best"     // all photos, high sensitivity — slower, sharper

        var description: String {
            switch self {
            case .draft: return "Fast preview. Uses fewer photos. Re-do as Best later."
            case .best: return "Slower, sharpest the device can do (reduced detail)."
            }
        }

        var icon: String {
            switch self {
            case .draft: return "hare"
            case .best: return "tortoise"
            }
        }
    }

    // MARK: - Capture Mode

    /// Chosen BEFORE scanning. Determines what data is captured.
    enum CaptureMode: String, Codable, CaseIterable {
        /// A: light, mesh-focused. Downscaled frames + texture baking. Best for
        /// large areas where accurate geometry/measurement matters.
        case fast = "Fast"
        /// B: saves full-resolution photos for after-scan photogrammetry
        /// reconstruction (PhotogrammetrySession). Photoreal output, slower,
        /// more storage.
        case highQuality = "High Quality"
        /// C (foundation): accumulates a dense colored point cloud from LiDAR
        /// depth + camera color. The initialization for Gaussian Splatting, and
        /// exportable as PLY.
        case pointCloud = "Point Cloud"
        /// Splat (Desktop): captures posed full-res photos + point cloud and
        /// exports a bundle (images + transforms.json + points3D.ply) so a
        /// computer can train a Gaussian splat, skipping COLMAP.
        case splatExport = "Splat (Desktop)"

        var description: String {
            switch self {
            case .fast: return "Quick mesh + baked texture. Best for big areas & measuring."
            case .highQuality: return "Saves full-res photos for photoreal post-processing."
            case .pointCloud: return "Dense colored point cloud (splat foundation). Exports PLY."
            case .splatExport: return "Posed photos + point cloud, exported for desktop splat training."
            }
        }

        var icon: String {
            switch self {
            case .fast: return "bolt.fill"
            case .highQuality: return "sparkles"
            case .pointCloud: return "aqi.medium"
            case .splatExport: return "square.and.arrow.up.on.square"
            }
        }
    }

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
            case .preview: return 1.0
            case .standard: return 0.5
            case .high: return 0.4
            case .ultra: return 0.3
            }
        }

        var maxTextureFrames: Int {
            switch self {
            case .preview: return 30
            case .standard: return 80
            case .high: return 120
            case .ultra: return 200
            }
        }

        var textureAtlasTileSize: Int {
            switch self {
            case .preview: return 512
            case .standard: return 768
            case .high: return 768
            case .ultra: return 1024
            }
        }

        /// Width to downscale captured camera frames to
        var textureDownscaleWidth: Int {
            switch self {
            case .preview: return 768
            case .standard: return 1280
            case .high: return 1600
            case .ultra: return 1920
            }
        }

        /// Size (px) of the baked UV texture atlas. Larger = sharper surface detail.
        var bakeAtlasSize: Int {
            switch self {
            case .preview: return 2048
            case .standard: return 6144
            case .high: return 8192
            case .ultra: return 8192
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
