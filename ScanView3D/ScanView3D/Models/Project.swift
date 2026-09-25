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
    var modelScale: Float?           // uniform metric scale correction (older photogrammetry scans)
    var modelTransform: [Float]?     // 4×4 column-major: puts a photogrammetry model into real-world space
    var sceneFrame: [Float]?         // 4×4: world → tidy frame used when the scan was saved (HQ re-runs reuse it)
    var northAligned: Bool?          // -Z points to true north (compass-aligned scan)
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var locationAccuracy: Double?    // metres
    var locationTimestamp: Date?
    var verticalLocationAccuracy: Double?
    var locationReducedAccuracy: Bool?
    var locationReference: String?   // "approximatePhoneGPS", never survey control
    /// Previous reconstruction models, measurements and metadata retained for recovery.
    /// Optional for compatibility with every existing projects.json file.
    var retainedReconstructionFiles: [String]?
    var coordinateProvenance: CoordinateProvenance?

    var scaleStatus: CoordinateProvenance.ScaleStatus {
        coordinateProvenance?.scaleStatus ?? ((vertexCount > 0 && modelTransform == nil && modelScale == nil) ? .lidarMetric : .legacyUnverified)
    }
    var scaleDescription: String {
        switch scaleStatus {
        case .lidarMetric: return "LiDAR local metres — field accuracy not verified"
        case .cameraPoseAligned: return "Camera-pose aligned — field accuracy not verified"
        case .estimatedFromBounds: return "Estimated scale from bounds — orientation not verified"
        case .unknown, .legacyUnverified: return "Unverified model scale — not a metric measurement"
        }
    }
    var hasKnownScale: Bool { scaleStatus != .unknown && scaleStatus != .legacyUnverified }

    func validatedModelTransform() throws -> [Double] {
        if let values = modelTransform { return try CoordinateMath.validated(values.map(Double.init)) }
        if let scale = modelScale {
            guard scale.isFinite, scale > 0 else { throw CoordinateError.invalidTransform }
            var m = CoordinateMath.identity
            m[0] = Double(scale); m[5] = Double(scale); m[10] = Double(scale)
            return try CoordinateMath.validated(m)
        }
        return CoordinateMath.identity
    }

    mutating func recordCaptureFrame(_ frame: simd_float4x4) {
        sceneFrame = StorageManager.array(of: frame)
        coordinateProvenance = CoordinateProvenance(sourceKind: "lidar", scaleStatus: .lidarMetric,
            alignmentMethod: "gravity level / local recenter", captureToLocal: sceneFrame?.map(Double.init),
            localDatum: "Local levelled low surface; zero is not a surveyed elevation datum")
    }

    mutating func recordLocation(_ fix: CaptureLocation?, compassRequested: Bool) {
        northAligned = compassRequested
        latitude = fix?.latitude
        longitude = fix?.longitude
        altitude = fix?.altitude
        locationAccuracy = fix?.horizontalAccuracy
        locationTimestamp = fix?.timestamp
        verticalLocationAccuracy = fix?.verticalAccuracy
        locationReducedAccuracy = fix?.reducedAccuracy
        locationReference = fix == nil ? nil : "approximatePhoneGPS"
    }

    /// Transform to apply to the stored model file when showing/measuring it.
    var modelMatrix: simd_float4x4? {
        if let m = Scan.matrix(modelTransform) { return m }
        if let s = modelScale, s > 0, abs(s - 1) > 0.0001 {
            return simd_float4x4(diagonal: SIMD4<Float>(s, s, s, 1))
        }
        return nil
    }

    var sceneFrameMatrix: simd_float4x4? { Scan.matrix(sceneFrame) }

    static func matrix(_ t: [Float]?) -> simd_float4x4? {
        guard let t = t, t.count == 16 else { return nil }
        return simd_float4x4(SIMD4<Float>(t[0], t[1], t[2], t[3]), SIMD4<Float>(t[4], t[5], t[6], t[7]),
                             SIMD4<Float>(t[8], t[9], t[10], t[11]), SIMD4<Float>(t[12], t[13], t[14], t[15]))
    }

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

/// Settings chosen on the scan screen. Remembered between launches.
struct ScanSettings: Codable, Equatable {
    var captureMode: CaptureMode = .fast
    var rangeValue: Float = 3.0        // metres (0.3 – 5.0)
    var detailMM: Float = 10.0         // grid spacing, Fast / Point Cloud (5 fine – 20 coarse)
    var meshMode: MeshMode = .free     // Fast only
    var captureTexture: Bool = true    // colour for Fast / Point Cloud
    var reconstructQuality: ReconstructQuality = .best
    var highResPhotos: Bool = false    // 12 MP stills for High Quality / Splat
    var alignToNorth: Bool = false     // compass-aligned world + GPS tag (outdoor / land)

    init() {}

    // Tolerant decoding: settings saved by an older version keep their values,
    // and any option added later simply starts at its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScanSettings()
        captureMode = (try? c.decodeIfPresent(CaptureMode.self, forKey: .captureMode)) ?? d.captureMode
        rangeValue = (try? c.decodeIfPresent(Float.self, forKey: .rangeValue)) ?? d.rangeValue
        detailMM = (try? c.decodeIfPresent(Float.self, forKey: .detailMM)) ?? d.detailMM
        meshMode = (try? c.decodeIfPresent(MeshMode.self, forKey: .meshMode)) ?? d.meshMode
        captureTexture = (try? c.decodeIfPresent(Bool.self, forKey: .captureTexture)) ?? d.captureTexture
        reconstructQuality = (try? c.decodeIfPresent(ReconstructQuality.self, forKey: .reconstructQuality)) ?? d.reconstructQuality
        highResPhotos = (try? c.decodeIfPresent(Bool.self, forKey: .highResPhotos)) ?? d.highResPhotos
        alignToNorth = (try? c.decodeIfPresent(Bool.self, forKey: .alignToNorth)) ?? d.alignToNorth
    }

    // MARK: - Persistence

    private static let storageKey = "scanSettings.v2"

    static func load() -> ScanSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(ScanSettings.self, from: data) else {
            return ScanSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: ScanSettings.storageKey)
        }
    }

    // MARK: - Reconstruction Quality (High-Quality / photogrammetry)

    /// On-device iOS photogrammetry is capped at `.reduced` mesh detail by Apple,
    /// so this only trades feature-matching effort for speed.
    enum ReconstructQuality: String, Codable, CaseIterable {
        case draft = "Draft"
        case best = "Best"

        var description: String {
            switch self {
            case .draft: return "Faster, may fail on plain surfaces. Photos are kept, so you can re-run as Best."
            case .best: return "Slower, most reliable and sharpest result on the phone."
            }
        }
    }

    // MARK: - Capture Mode

    /// Chosen BEFORE scanning. Determines what data is captured.
    enum CaptureMode: String, Codable, CaseIterable {
        case fast = "Fast"
        case highQuality = "High Quality"
        case pointCloud = "Point Cloud"
        case splatExport = "Splat (Desktop)"

        var shortName: String {
            switch self {
            case .fast: return "Fast"
            case .highQuality: return "HQ"
            case .pointCloud: return "Points"
            case .splatExport: return "Splat"
            }
        }

        var description: String {
            switch self {
            case .fast: return "Mesh with photo texture. Best for big areas and measuring."
            case .highQuality: return "Takes photos, then builds a photoreal model after the scan."
            case .pointCloud: return "Coloured point cloud (PLY). Good for survey and CAD tools."
            case .splatExport: return "Photos + camera positions to train a Gaussian splat on a PC."
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

        /// Whether the Detail slider affects this mode.
        var usesDetail: Bool { self == .fast || self == .pointCloud }
        /// Whether the colour on/off switch affects this mode.
        var usesColorToggle: Bool { self == .fast || self == .pointCloud }
        /// Whether the mesh filter (Everything / Structure / Room shell) applies.
        var usesMeshMode: Bool { self == .fast }
        /// Whether this mode takes posed photos.
        var usesPhotos: Bool { self == .highQuality || self == .splatExport }
    }

    // MARK: - Mesh Mode

    enum MeshMode: String, Codable, CaseIterable {
        case free = "Everything"
        case structure = "Structure"
        case area = "Room Shell"

        var description: String {
            switch self {
            case .free: return "Everything the LiDAR sees."
            case .structure: return "Walls, floor, ceiling, doors, windows and furniture. Drops clutter."
            case .area: return "Only floor, walls and ceiling, as clean flat surfaces."
            }
        }

        var icon: String {
            switch self {
            case .free: return "scribble.variable"
            case .structure: return "building"
            case .area: return "square.dashed"
            }
        }

        /// Whether a triangle with this ARKit classification (per face) is kept.
        func includes(classification: UInt8) -> Bool {
            guard let cls = ARMeshClassificationCompat(rawValue: Int(classification)) else { return true }
            switch self {
            case .free:
                return true
            case .structure:
                return cls != ARMeshClassificationCompat.none
            case .area:
                switch cls {
                case .wall, .floor, .ceiling, .door, .window: return true
                case .none, .table, .seat: return false
                }
            }
        }
    }

    // MARK: - Texture Capture Quality (internal)

    enum ScanQuality: String, Codable, CaseIterable {
        case preview, standard, high, ultra

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

        /// Width to downscale captured camera frames to
        var textureDownscaleWidth: Int {
            switch self {
            case .preview: return 768
            case .standard: return 1280
            case .high: return 1600
            case .ultra: return 1920
            }
        }

        /// Size (px) of the baked UV texture atlas.
        var bakeAtlasSize: Int {
            switch self {
            case .preview: return 2048
            case .standard: return 6144
            case .high, .ultra: return 8192
            }
        }
    }

    // MARK: - Measurement Unit

    enum MeasurementUnit: String, Codable, CaseIterable {
        case meters = "Meters"
        case centimeters = "Centimeters"
        case feet = "Feet & Inches"
        case inches = "Inches"

        static let storageKey = "measurementUnit"

        /// The unit chosen in Settings.
        static var preferred: MeasurementUnit {
            UserDefaults.standard.string(forKey: storageKey).flatMap(MeasurementUnit.init(rawValue:)) ?? .meters
        }

        var abbreviation: String {
            switch self {
            case .meters: return "m"
            case .centimeters: return "cm"
            case .feet: return "ft"
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

        /// Human-readable length. LiDAR is good to about a centimetre, so we
        /// don't show millimetres.
        func format(meters value: Float) -> String {
            switch self {
            case .meters:
                return String(format: "%.2f m", value)
            case .centimeters:
                return String(format: "%.0f cm", value * 100)
            case .inches:
                return String(format: "%.1f in", value * 39.3701)
            case .feet:
                let totalInches = abs(value) * 39.3701
                var feet = Int(totalInches / 12)
                var inches = (totalInches - Float(feet) * 12).rounded()
                if inches >= 12 { feet += 1; inches = 0 }
                return "\(value < 0 ? "-" : "")\(feet)′ \(Int(inches))″"
            }
        }

        func format(squareMeters value: Float) -> String {
            switch self {
            case .meters, .centimeters:
                return String(format: "%.2f m²", value)
            case .feet, .inches:
                return String(format: "%.1f ft²", value * 10.7639)
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
