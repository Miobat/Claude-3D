import Foundation
import SceneKit
import CryptoKit
import ImageIO

/// Manages persistent storage for projects and scan files
class StorageManager: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published var storageError: String?
    @Published private(set) var isLibraryReadOnly = false
    @Published private(set) var isExporting = false
    @Published private(set) var isImporting = false
    @Published private(set) var exportMessage = ""
    private let exportQueue = DispatchQueue(label: "scanview.export", qos: .userInitiated)
    private let exportCancellation = ExportCancellation()

    func cancelExport() { exportCancellation.cancel() }

    /// One bounded worker; UI only receives a complete package. Exporting is a
    /// model-delivery action, not a project backup or a mutation of saved scans.
    func prepareExport(_ work: @escaping () throws -> URL, completion: @escaping (URL) -> Void) {
        guard !isExporting, !isImporting else { return }
        isExporting = true
        exportMessage = "Preparing model package…"
        exportCancellation.reset()
        exportQueue.async {
            let result = Result { try work() }
            DispatchQueue.main.async {
                self.isExporting = false
                self.exportMessage = ""
                if self.exportCancellation.isCancelled { return }
                switch result {
                case .success(let url): completion(url)
                case .failure(let error): self.report(error, action: "Export")
                }
            }
        }
    }

    private let fileManager = FileManager.default
    private let projectsFileName = "projects.json"
    private let rootDirectory: URL
    private lazy var persistence = LibraryPersistence<[Project]>(indexURL: projectsFile, validate: Self.validateLibrary)
    private typealias StorageFailure = LibraryPersistence<[Project]>.Failure

    // MARK: - Directories

    private var documentsDirectory: URL {
        rootDirectory
    }

    private var projectsDirectory: URL {
        documentsDirectory.appendingPathComponent(AppConstants.projectsDirectory)
    }

    private var scansDirectory: URL {
        documentsDirectory.appendingPathComponent(AppConstants.scansDirectory)
    }

    private var projectsFile: URL {
        documentsDirectory.appendingPathComponent(projectsFileName)
    }

    // MARK: - Initialization

    init(directory: URL? = nil) {
        rootDirectory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            _ = try LibraryFileSafety.child(AppConstants.projectsDirectory, of: rootDirectory)
            _ = try LibraryFileSafety.child(AppConstants.scansDirectory, of: rootDirectory)
            try fileManager.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: scansDirectory, withIntermediateDirectories: true)
            if !LibraryFileSafety.exists(projectsFile) {
                for folder in try fileManager.contentsOfDirectory(at: scansDirectory, includingPropertiesForKeys: nil) {
                    let kind = try fileManager.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType
                    // Empty UUID folders can be left by an interrupted first
                    // project creation. Actual assets must never be orphaned.
                    guard kind == .typeDirectory, UUID(uuidString: folder.lastPathComponent) != nil,
                          try fileManager.contentsOfDirectory(atPath: folder.path).isEmpty else { throw StorageFailure.readOnly }
                }
            }
            projects = try persistence.load(default: [])
        } catch {
            isLibraryReadOnly = true
            report(error, action: "Open library. Saving is disabled; existing files have been preserved")
        }
    }

    // MARK: - Threading

    /// Reject bad metadata before exposing it to viewers or destructive actions.
    /// Missing assets remain visible/recoverable; unsafe paths and aliasing do not.
    static func validateLibrary(_ projects: [Project]) throws {
        var projectIDs = Set<UUID>(), scanIDs = Set<UUID>()
        var totalVertices = 0, totalFaces = 0
        var totalBytes: Int64 = 0
        for project in projects {
            guard projectIDs.insert(project.id).inserted else { throw StorageFailure.invalidLibrary }
            var owners: [String: UUID] = [:]
            for scan in project.scans {
                guard scanIDs.insert(scan.id).inserted, scan.vertexCount >= 0, scan.faceCount >= 0,
                      scan.fileSize >= 0 else { throw StorageFailure.invalidLibrary }
                let vertices = totalVertices.addingReportingOverflow(scan.vertexCount)
                let faces = totalFaces.addingReportingOverflow(scan.faceCount)
                let bytes = totalBytes.addingReportingOverflow(scan.fileSize)
                guard !vertices.overflow, !faces.overflow, !bytes.overflow else { throw StorageFailure.invalidLibrary }
                totalVertices = vertices.partialValue; totalFaces = faces.partialValue; totalBytes = bytes.partialValue
                _ = try scan.validatedModelTransform()
                if let frame = scan.sceneFrame { _ = try CoordinateMath.validated(frame.map(Double.init)) }
                for bounds in [scan.boundingBoxMin, scan.boundingBoxMax].compactMap({ $0 }) {
                    guard bounds.x.isFinite, bounds.y.isFinite, bounds.z.isFinite else { throw StorageFailure.invalidLibrary }
                }
                if let lo = scan.boundingBoxMin, let hi = scan.boundingBoxMax {
                    guard lo.x <= hi.x, lo.y <= hi.y, lo.z <= hi.z else { throw StorageFailure.invalidLibrary }
                }
                for name in Self.fileNames(of: scan) {
                    try LibraryFileSafety.validateName(name)
                    let key = LibraryFileSafety.key(name)
                    guard owners[key] == nil || owners[key] == scan.id else { throw StorageFailure.invalidLibrary }
                    owners[key] = scan.id
                }
            }
        }
    }

    private func validatedDirectory(for project: Project) throws -> URL {
        let root = try LibraryFileSafety.child(AppConstants.scansDirectory, of: documentsDirectory)
        return try LibraryFileSafety.child(project.id.uuidString, of: root)
    }

    private func writableDirectory(for project: Project) throws -> URL {
        try onMain {
            guard !isLibraryReadOnly else { throw StorageFailure.readOnly }
            guard projects.contains(where: { $0.id == project.id }) else { throw StorageFailure.missingItem }
            return try validatedDirectory(for: project)
        }
    }

    private func newCandidateFiles(base: String, extension ext: String, directory: URL) throws -> [URL] {
        let names = ["\(base).\(ext)", "\(base).scn", "\(base).mtl", "\(base)_texture.jpg", "\(base)_texture.png",
                     base + SurfaceLabelDocument.suffix, "\(base)_original.mesh", "\(base)_photos",
                     "\(base)_photos" + PoseFile.suffix]
        let urls = try names.map { try LibraryFileSafety.child($0, of: directory) }
        guard urls.allSatisfy({ !fileManager.fileExists(atPath: $0.path) }) else { throw StorageFailure.destinationExists }
        return urls
    }

    private func validateFiles(of scan: Scan, in directory: URL, requireRegistered: Bool = false) throws {
        for name in companionFiles(of: scan) { _ = try LibraryFileSafety.child(name, of: directory) }
        if requireRegistered {
            let required = [scan.fileName] + [scan.textureFileName, scan.splatBundleName, scan.captureFolderName].compactMap { $0 }
                + (scan.originalMeshSHA256 == nil ? [] : [(scan.fileName as NSString).deletingPathExtension + "_original.mesh"])
            for name in required {
                let url = try LibraryFileSafety.child(name, of: directory)
                guard fileManager.fileExists(atPath: url.path) else { throw StorageFailure.missingItem }
                try LibraryFileSafety.validateTree(url)
            }
        }
    }

    /// `projects` drives SwiftUI, so it may only change on the main thread.
    /// Saving runs on background queues and hops here for the bookkeeping.
    private func onMain<T>(_ work: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try work() }
        return try DispatchQueue.main.sync(execute: work)
    }

    func report(_ error: Error, action: String) {
        onMain {
            storageError = "\(action): \(error.localizedDescription)"
            DebugLogger.shared.error(storageError!, category: "Storage")
        }
    }

    /// Persist first; SwiftUI must never present a change that failed to save.
    private func commitProjects(_ candidate: [Project]) throws {
        do {
            try persistence.commit(candidate)
            projects = candidate
        } catch {
            isLibraryReadOnly = persistence.isReadOnly
            throw error
        }
    }

    private func addScan(_ scan: Scan, to project: Project) throws {
        try onMain {
            var candidate = projects
            guard let index = candidate.firstIndex(where: { $0.id == project.id }) else { throw StorageFailure.missingItem }
            candidate[index].addScan(scan)
            if scan.thumbnailData != nil { candidate[index].thumbnailData = scan.thumbnailData }
            try commitProjects(candidate)
        }
    }

    /// UI-only mutations report failures without losing their last committed state.
    @discardableResult
    private func perform(_ action: String, _ work: () throws -> Void) -> Bool {
        onMain {
            do { try work(); return true }
            catch { report(error, action: action); return false }
        }
    }

    // MARK: - Project CRUD

    @discardableResult
    func createProject(name: String) -> Project? {
        let project = Project(name: name)
        return perform("Create project") {
            guard !isLibraryReadOnly else { throw StorageFailure.readOnly }
            let projectRoot = try LibraryFileSafety.child(AppConstants.projectsDirectory, of: documentsDirectory)
            let projectFolder = try LibraryFileSafety.child(project.id.uuidString, of: projectRoot)
            let scanFolder = try validatedDirectory(for: project)
            try fileManager.createDirectory(at: projectFolder, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: scanFolder, withIntermediateDirectories: true)
            var committed = false
            defer { if !committed { try? removeExistingItems([projectFolder, scanFolder]) } }
            try commitProjects(projects + [project])
            committed = true
        } ? project : nil
    }

    func updateProject(_ project: Project) {
        perform("Update project") {
            var candidate = projects
            guard let index = candidate.firstIndex(where: { $0.id == project.id }) else { throw StorageFailure.missingItem }
            // A view holds a snapshot; replacing it wholesale can drop scans saved
            // since that snapshot was made. Project edits never replace scan records.
            candidate[index].name = project.name
            candidate[index].modifiedAt = Date()
            try commitProjects(candidate)
        }
    }

    func deleteProject(_ project: Project) {
        perform("Delete project") {
            guard projects.contains(where: { $0.id == project.id }) else { throw StorageFailure.missingItem }
            let scanDirectory = try validatedDirectory(for: project)
            let projectRoot = try LibraryFileSafety.child(AppConstants.projectsDirectory, of: documentsDirectory)
            let projectDirectory = try LibraryFileSafety.child(project.id.uuidString, of: projectRoot)
            try commitProjects(projects.filter { $0.id != project.id })
            // Remove files only AFTER the index commits. Interrupted cleanup leaves
            // recoverable unused files, not a library pointing at missing models.
            try removeExistingItems([
                projectDirectory,
                scanDirectory
            ])
        }
    }

    func renameProject(_ project: Project, newName: String) {
        perform("Rename project") {
            var candidate = projects
            guard let index = candidate.firstIndex(where: { $0.id == project.id }) else { throw StorageFailure.missingItem }
            candidate[index].name = newName
            candidate[index].modifiedAt = Date()
            try commitProjects(candidate)
        }
    }

    private func removeExistingItems(_ urls: [URL]) throws {
        for url in urls where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: - Scan Management

    func saveScan(
        meshData: MeshData,
        name: String,
        toProject project: Project,
        format: ExportFormat = .obj,
        baked: BakedTexture? = nil,
        originalMesh: MeshData? = nil,
        metadata: ((inout Scan) -> Void)? = nil
    ) throws -> Scan {
        guard meshData.faceClassifications == nil || meshData.faceClassifications?.count == meshData.faceCount else {
            throw AutomaticMeasurementError.invalidDocument
        }
        let scanId = UUID()
        let fileExtension = format == .ply ? "ply" : "obj"
        let fileName = "\(scanId.uuidString).\(fileExtension)"
        let scanDir = try writableDirectory(for: project)
        try fileManager.createDirectory(at: scanDir, withIntermediateDirectories: true)
        let candidates = try newCandidateFiles(base: scanId.uuidString, extension: fileExtension, directory: scanDir)
        var committed = false
        defer { if !committed { try? removeExistingItems(candidates) } }

        let isTextured = (format == .obj && baked != nil)

        // Export based on format
        let fileURL: URL
        switch format {
        case .obj:
            if let baked = baked {
                fileURL = try OBJExporter.exportTextured(
                    meshData: meshData,
                    fileName: scanId.uuidString,
                    baked: baked,
                    directory: scanDir
                )
            } else {
                fileURL = try OBJExporter.export(
                    meshData: meshData,
                    fileName: scanId.uuidString,
                    directory: scanDir
                )
            }
        case .ply:
            fileURL = try OBJExporter.exportPLY(
                meshData: meshData,
                fileName: scanId.uuidString,
                directory: scanDir
            )
        }

        let fileSize = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0

        var scan = Scan(
            name: name,
            fileName: fileName,
            vertexCount: meshData.vertexCount,
            faceCount: meshData.faceCount,
            fileSize: fileSize
        )
        scan.hasColor = !meshData.colors.isEmpty
        scan.hasTexture = isTextured
        scan.textureQuality = isTextured ? baked?.quality : nil
        scan.boundingBoxMin = meshData.boundingBoxMin
        scan.boundingBoxMax = meshData.boundingBoxMax

        // Store texture file name if we baked a texture
        if isTextured {
            scan.textureFileName = "\(scanId.uuidString)_texture.jpg"
        }

        // Save native SceneKit scene for fast internal viewing.
        // Use the UV-textured node when we have a baked atlas, otherwise per-vertex color.
        let scnURL = scanDir.appendingPathComponent("\(scanId.uuidString).scn")
        let scnNode: SCNNode
        if let baked = baked, isTextured {
            scnNode = MeshProcessor.createTexturedNode(from: meshData, baked: baked)
        } else {
            scnNode = MeshProcessor.createSceneKitNode(from: meshData)
        }
        let scene = SCNScene()
        scene.rootNode.addChildNode(scnNode)
        guard scene.write(to: scnURL, delegate: nil) else { throw CocoaError(.fileWriteUnknown) }

        // Commit semantic metadata before adding the scan to the library. OBJ/PLY
        // and native viewer builders preserve the kept triangle order, including
        // textured per-corner expansion. Never use this map on a new HQ topology.
        if let labels = meshData.faceClassifications {
            let document = SurfaceLabelDocument(modelSHA256: try measurementSHA256(fileURL),
                                                viewerSHA256: try measurementSHA256(scnURL),
                                                faceCount: meshData.faceCount, classifications: labels)
            try document.validate()
            try JSONEncoder().encode(document).write(
                to: scanDir.appendingPathComponent(scanId.uuidString + SurfaceLabelDocument.suffix), options: .atomic)
        }

        // Generate thumbnail
        scan.thumbnailData = generateThumbnail(for: meshData)

        // Fail the save (and retain the recovery checkpoint) if the original
        // cannot be preserved. Never report a recoverable save without its file.
        if let originalMesh {
            let url = scanDir.appendingPathComponent(scanId.uuidString + "_original.mesh")
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            try encoder.encode(originalMesh).write(to: url, options: .atomic)
            scan.originalMeshSHA256 = try measurementSHA256(url)
        }

        metadata?(&scan)
        try addScan(scan, to: project)
        committed = true
        return scan
    }

    func getScanFileURL(scan: Scan, project: Project) -> URL {
        // Legacy nonthrowing viewer API: fail to an unreadable model, never follow
        // a library reference that was replaced with a symlink through file sharing.
        guard let directory = try? validatedDirectory(for: project),
              (try? validateFiles(of: scan, in: directory)) != nil,
              let url = try? LibraryFileSafety.child(scan.fileName, of: directory) else {
            return URL(fileURLWithPath: "/dev/null")
        }
        return url
    }

    /// Register a scan from an already-produced model file (e.g. a photogrammetry USDZ).
    /// - modelTransform: places the model in real-world space (photogrammetry has no real-world
    ///   scale; we derive this from the LiDAR mesh captured in the same session).
    /// - photosFolder: source photos to keep with the scan for later re-reconstruction.
    func importProcessedModel(modelURL: URL, name: String, toProject project: Project,
                              modelTransform: simd_float4x4? = nil, photosFolder: URL? = nil,
                              metadata: ((inout Scan) -> Void)? = nil) throws -> Scan {
        let scanId = UUID()
        let ext = modelURL.pathExtension.isEmpty ? "usdz" : modelURL.pathExtension
        let fileName = "\(scanId.uuidString).\(ext)"
        let scanDir = try writableDirectory(for: project)
        try fileManager.createDirectory(at: scanDir, withIntermediateDirectories: true)
        let candidates = try newCandidateFiles(base: scanId.uuidString, extension: ext, directory: scanDir)
        var committed = false
        defer { if !committed { try? removeExistingItems(candidates) } }

        let destURL = scanDir.appendingPathComponent(fileName)
        try LibraryFileSafety.validateTree(modelURL)
        try fileManager.copyItem(at: modelURL, to: destURL)

        let fileSize = (try? fileManager.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
        var scan = Scan(name: name, fileName: fileName, vertexCount: 0, faceCount: 0, fileSize: fileSize)
        scan.hasTexture = true
        scan.hasColor = true
        scan.modelTransform = modelTransform.map(StorageManager.array(of:))
        scan.thumbnailData = generateThumbnail(fromModelURL: destURL)

        // Record true (real-world) dimensions so the info panel reads metric.
        if let bounds = StorageManager.transformedBounds(of: destURL, by: modelTransform) {
            scan.boundingBoxMin = bounds.0
            scan.boundingBoxMax = bounds.1
        }

        // Keep the source photos (and their ARKit poses) for re-reconstruction later.
        if let photosFolder = photosFolder {
            try LibraryFileSafety.validateTree(photosFolder)
            let kept = scanDir.appendingPathComponent("\(scanId.uuidString)_photos")
            try fileManager.copyItem(at: photosFolder, to: kept)
            scan.captureFolderName = kept.lastPathComponent
            let poses = PoseFile.url(forPhotoFolder: photosFolder)
            if fileManager.fileExists(atPath: poses.path) {
                try fileManager.copyItem(at: poses, to: PoseFile.url(forPhotoFolder: kept))
            }
        }

        metadata?(&scan)
        try addScan(scan, to: project)
        committed = true
        return scan
    }

    /// New library item; never replaces geometry or measurements of the source.
    /// This is the accepted pre-cleanup mesh, not unfiltered/out-of-range AR data.
    func saveOriginalCopy(of scan: Scan, in project: Project) throws -> Scan {
        guard let hash = scan.originalMeshSHA256, MeasurementModelRevision.validHash(hash) else {
            throw StorageFailure.missingItem
        }
        let url = try measurementSidecar("_original.mesh", scan: scan, project: project)
        guard try measurementSHA256(url) == hash else { throw CocoaError(.fileReadCorruptFile) }
        let bytes = try boundedMeasurementData(url, maximumBytes: 512_000_000)
        let mesh = try PropertyListDecoder().decode(MeshData.self, from: bytes)
        return try saveScan(meshData: mesh, name: scan.name + " · Original", toProject: project) {
            $0.sceneFrame = scan.sceneFrame; $0.coordinateProvenance = scan.coordinateProvenance
            $0.modelScale = scan.modelScale; $0.modelTransform = scan.modelTransform
            $0.northAligned = scan.northAligned; $0.latitude = scan.latitude; $0.longitude = scan.longitude
            $0.altitude = scan.altitude; $0.locationAccuracy = scan.locationAccuracy
            $0.locationTimestamp = scan.locationTimestamp; $0.verticalLocationAccuracy = scan.verticalLocationAccuracy
            $0.locationReducedAccuracy = scan.locationReducedAccuracy; $0.locationReference = scan.locationReference
            $0.notes = "Original captured mesh before cleanup. Range/confidence filtering still applies. Vertex colour only; photo atlas and measurements are not copied."
        }
    }

    /// Change stored details of a saved scan.
    func updateScan(_ scanID: UUID, in project: Project, _ change: (inout Scan) -> Void) throws {
        try onMain {
            var candidate = projects
            guard let pi = candidate.firstIndex(where: { $0.id == project.id }),
                  let si = candidate[pi].scans.firstIndex(where: { $0.id == scanID }) else { throw StorageFailure.missingItem }
            change(&candidate[pi].scans[si])
            candidate[pi].modifiedAt = Date()
            try commitProjects(candidate)
        }
    }

    // MARK: - Measurements

    private func measurementsURL(for scan: Scan, in project: Project) throws -> URL {
        try measurementSidecar("_measurements.json", scan: scan, project: project)
    }

    func loadMeasurements(for scan: Scan, in project: Project) -> [ScanMeasurement] {
        do {
            let url = try measurementsURL(for: scan, in: project)
            guard LibraryFileSafety.exists(url) else { return [] }
            return try JSONDecoder().decode([ScanMeasurement].self, from: boundedMeasurementData(url, maximumBytes: 16_000_000))
        }
        catch { report(error, action: "Read measurements. The original file has been preserved"); return [] }
    }

    func saveMeasurements(_ measurements: [ScanMeasurement], for scan: Scan, in project: Project) throws {
        try onMain {
            guard !isLibraryReadOnly else { throw StorageFailure.readOnly }
            guard let current = projects.first(where: { $0.id == project.id })?.scans.first(where: { $0.id == scan.id }),
                  current.fileName == scan.fileName else { throw StorageFailure.missingItem }
            let url = try measurementsURL(for: scan, in: project)
            if LibraryFileSafety.exists(url) {
                // A failed load must not turn into silently overwriting a corrupt file.
                _ = try JSONDecoder().decode([ScanMeasurement].self, from: boundedMeasurementData(url, maximumBytes: 16_000_000))
            }
            let bytes = try JSONEncoder().encode(measurements)
            guard bytes.count <= 16_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
            try bytes.write(to: url, options: .atomic)
        }
    }

    // MARK: - Automatic measurement foundation

    private func measurementSidecar(_ suffix: String, scan: Scan, project: Project) throws -> URL {
        let base = (scan.fileName as NSString).deletingPathExtension
        return try LibraryFileSafety.child(base + suffix, of: validatedDirectory(for: project))
    }

    /// Stream hashes without the export cancellation state. Call expensive reads
    /// on a worker queue when the selection UI is added; no whole-model Data copy.
    private func measurementSHA256(_ url: URL) throws -> String {
        guard try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while let bytes = try input.read(upToCount: 1 << 20), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func boundedMeasurementData(_ url: URL, maximumBytes: Int) throws -> Data {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let count = (attributes[.size] as? NSNumber)?.intValue ?? maximumBytes + 1
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              count >= 0, count <= maximumBytes else { throw AutomaticMeasurementError.invalidDocument }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= maximumBytes else { throw AutomaticMeasurementError.invalidDocument }
        return bytes
    }

    func loadSurfaceLabels(for scan: Scan, in project: Project) throws -> SurfaceLabelDocument? {
        let url = try measurementSidecar(SurfaceLabelDocument.suffix, scan: scan, project: project)
        guard fileManager.fileExists(atPath: url.path) else { return nil } // legacy / point-cloud / HQ
        let document = try JSONDecoder().decode(SurfaceLabelDocument.self,
            from: boundedMeasurementData(url, maximumBytes: 24_000_000))
        try document.validate()
        let viewer = try measurementSidecar(".scn", scan: scan, project: project)
        guard document.faceCount == scan.faceCount,
              document.modelSHA256 == (try measurementSHA256(getScanFileURL(scan: scan, project: project))),
              fileManager.fileExists(atPath: viewer.path), document.viewerSHA256 == (try measurementSHA256(viewer)) else {
            throw AutomaticMeasurementError.staleModel
        }
        return document
    }

    /// Estimated bounding-box scale is not a calibration. Only metric LiDAR or
    /// camera-pose-aligned reconstruction can start automatic dimensions today.
    func automaticMeasurementRevision(for scan: Scan, in project: Project) throws -> MeasurementModelRevision {
        guard scan.hasKnownScale, scan.scaleStatus == .lidarMetric || scan.scaleStatus == .cameraPoseAligned else {
            throw AutomaticMeasurementError.unverifiedScale
        }
        let viewer = try measurementSidecar(".scn", scan: scan, project: project)
        let revision = MeasurementModelRevision(
            modelSHA256: try measurementSHA256(getScanFileURL(scan: scan, project: project)),
            worldTransform: try scan.validatedModelTransform(),
            viewerSHA256: fileManager.fileExists(atPath: viewer.path) ? try measurementSHA256(viewer) : nil)
        try revision.validate()
        return revision
    }

    /// Throws on stale, corrupt, or newer data; nil means genuinely absent. The
    /// UI must not turn a failed load into an empty selection that overwrites it.
    func loadAutomaticMeasurements(for scan: Scan, in project: Project) throws -> AutomaticMeasurementDocument? {
        let url = try measurementSidecar(AutomaticMeasurementDocument.suffix, scan: scan, project: project)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let document = try AutomaticMeasurementDocument.decode(boundedMeasurementData(url, maximumBytes: 4_000_000))
        try document.validate(for: automaticMeasurementRevision(for: scan, in: project))
        return document
    }

    func saveAutomaticMeasurements(_ document: AutomaticMeasurementDocument, for scan: Scan, in project: Project,
                                   replacingStaleResults: Bool = false) throws {
        let snapshot: Scan = try onMain {
            guard !isLibraryReadOnly else { throw StorageFailure.readOnly }
            guard let current = projects.first(where: { $0.id == project.id })?.scans.first(where: { $0.id == scan.id }),
                  current.fileName == scan.fileName else { throw StorageFailure.missingItem }
            return current
        }
        // Model hashing runs on the caller's worker queue, not inside the main
        // thread library commit. A changed model/alignment is rechecked below.
        try document.validate(for: automaticMeasurementRevision(for: snapshot, in: project))
        let url = try measurementSidecar(AutomaticMeasurementDocument.suffix, scan: snapshot, project: project)
        let previous: Data? = fileManager.fileExists(atPath: url.path)
            ? try boundedMeasurementData(url, maximumBytes: 4_000_000) : nil
        if let previous {
            let existing = try AutomaticMeasurementDocument.decode(previous)
            guard existing.revision == document.revision || replacingStaleResults else {
                throw AutomaticMeasurementError.staleModel
            }
        }
        let bytes = try document.encoded()
        try onMain {
            guard !isLibraryReadOnly else { throw StorageFailure.readOnly }
            guard let current = projects.first(where: { $0.id == project.id })?.scans.first(where: { $0.id == scan.id }),
                  current.fileName == snapshot.fileName, current.scaleStatus == snapshot.scaleStatus,
                  try current.validatedModelTransform() == snapshot.validatedModelTransform() else {
                throw AutomaticMeasurementError.staleModel
            }
            _ = try measurementSidecar(AutomaticMeasurementDocument.suffix, scan: current, project: project)
            let latest: Data? = fileManager.fileExists(atPath: url.path)
                ? try boundedMeasurementData(url, maximumBytes: 4_000_000) : nil
            guard latest == previous else { throw StorageFailure.missingItem } // concurrent selection edit
            try bytes.write(to: url, options: .atomic)
        }
    }

    /// Measurements as a CSV file ready to share.
    func exportMeasurementsCSV(_ measurements: [ScanMeasurement], scanName: String,
                               unit: ScanSettings.MeasurementUnit) -> URL? {
        let dir = documentsDirectory.appendingPathComponent(AppConstants.exportDirectory).appendingPathComponent("Share")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(exportBaseName(scanName))_measurements.csv")
        do {
            try ScanMeasurement.csv(measurements, unit: unit).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Re-export / Re-process helpers

    /// URL of a saved Splat bundle zip, if this scan has one.
    func splatBundleURL(for scan: Scan, in project: Project) -> URL? {
        guard let name = scan.splatBundleName, let directory = try? validatedDirectory(for: project),
              let url = try? LibraryFileSafety.child(name, of: directory),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return url
    }

    /// URL of the kept source-photos folder for a High-Quality scan, if present.
    func captureFolderURL(for scan: Scan, in project: Project) -> URL? {
        guard let name = scan.captureFolderName, let directory = try? validatedDirectory(for: project),
              let url = try? LibraryFileSafety.child(name, of: directory),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (try? LibraryFileSafety.validateTree(url)) != nil,
              (try? LibraryFileSafety.child(name + PoseFile.suffix, of: directory)) != nil else { return nil }
        return url
    }

    /// Publish a new model only after it is copied. The old model, measurements,
    /// and metadata stay with the scan as recovery files, including across moves.
    func replacePhotogrammetryModel(scanID: UUID, in project: Project,
                                    newModelURL: URL, modelTransform: simd_float4x4?, provenance: CoordinateProvenance? = nil) throws {
        try onMain {
            guard !isLibraryReadOnly else { throw StorageFailure.readOnly }
            guard let pi = projects.firstIndex(where: { $0.id == project.id }),
                  let si = projects[pi].scans.firstIndex(where: { $0.id == scanID }) else { throw StorageFailure.missingItem }
            let original = projects[pi].scans[si]
            let dir = try validatedDirectory(for: project)
            try validateFiles(of: original, in: dir)
            let base = UUID().uuidString
            let dest = try LibraryFileSafety.child("\(base).usdz", of: dir)
            let metadata = try LibraryFileSafety.child("\(base)_previous.json", of: dir)
            guard !LibraryFileSafety.exists(dest), !LibraryFileSafety.exists(metadata) else { throw StorageFailure.destinationExists }
            try persistence.copyAndCommit([(newModelURL, dest)]) {
                var updated = original
                updated.fileName = dest.lastPathComponent
                updated.fileSize = (try fileManager.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
                updated.modelScale = nil
                updated.modelTransform = modelTransform.map(StorageManager.array(of:))
                updated.coordinateProvenance = provenance
                updated.textureQuality = nil // A new reconstruction has different surfaces/photos.
                updated.meshRetention = nil; updated.originalMeshSHA256 = nil
                updated.terrainCapture = nil // This replacement is no longer a measured terrain point cloud.
                updated.thumbnailData = generateThumbnail(fromModelURL: dest)
                guard let bounds = StorageManager.transformedBounds(of: dest, by: modelTransform) else {
                    throw StorageFailure.missingItem
                }
                updated.boundingBoxMin = bounds.0
                updated.boundingBoxMax = bounds.1
                updated.retainedReconstructionFiles = companionFiles(of: original).filter {
                    fileManager.fileExists(atPath: dir.appendingPathComponent($0).path)
                } + [metadata.lastPathComponent]
                do {
                    try JSONEncoder().encode(original).write(to: metadata, options: .atomic)
                    var candidate = projects
                    candidate[pi].scans[si] = updated
                    candidate[pi].modifiedAt = Date()
                    try commitProjects(candidate)
                } catch {
                    try? fileManager.removeItem(at: metadata)
                    throw error
                }
            }
        }
    }

    static func array(of m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    /// Bounding box of a model file after applying a transform (8 corners).
    static func transformedBounds(of url: URL, by transform: simd_float4x4?) -> (SIMD3<Float>, SIMD3<Float>)? {
        guard let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) else { return nil }
        let (mn, mx) = scene.rootNode.flattenedClone().boundingBox
        let m = transform ?? matrix_identity_float4x4
        var corners: [SIMD3<Float>] = []
        for x in [mn.x, mx.x] { for y in [mn.y, mx.y] { for z in [mn.z, mx.z] {
            let w = m * SIMD4<Float>(Float(x), Float(y), Float(z), 1)
            corners.append(SIMD3<Float>(w.x, w.y, w.z))
        } } }
        return MeshData.bounds(of: corners)
    }

    /// Save a colored point cloud (Path C foundation): binary PLY + point-cloud .scn for viewing.
    /// What a long capture hands over so its drift record is saved with the scan.
    struct AlignmentRecord {
        let prepared: DriftPipeline.Prepared
        let capture: AlignmentCapture
        /// Segment of each point, in the order of the mesh being saved.
        let pointSegments: [UInt16]
        /// Capture frame → saved frame.
        let frame: RigidPose
    }

    /// - alignment: drift record of a fresh capture. - alignmentDocument: a
    ///   ready record for a copy (called with the new model's hash).
    /// Both sidecars are written before the scan enters the library.
    func savePointCloud(meshData: MeshData, name: String, toProject project: Project, splatBundle: URL? = nil,
                        alignment: AlignmentRecord? = nil,
                        alignmentDocument: ((String) throws -> ScanAlignmentDocument)? = nil,
                        references: ScanReferenceDocument? = nil,
                        metadata: ((inout Scan) -> Void)? = nil) throws -> Scan {
        let scanId = UUID()
        let fileName = "\(scanId.uuidString).ply"
        let scanDir = try writableDirectory(for: project)
        try fileManager.createDirectory(at: scanDir, withIntermediateDirectories: true)

        let scnURL = scanDir.appendingPathComponent("\(scanId.uuidString).scn")
        let bundleURL = scanDir.appendingPathComponent("\(scanId.uuidString)_bundle.zip")
        let alignmentURL = scanDir.appendingPathComponent(scanId.uuidString + ScanAlignmentDocument.suffix)
        let referencesURL = scanDir.appendingPathComponent(scanId.uuidString + ScanReferenceDocument.suffix)
        let fresh = [scanDir.appendingPathComponent(fileName), scnURL, bundleURL, alignmentURL, referencesURL]
        guard fresh.allSatisfy({ !fileManager.fileExists(atPath: $0.path) }) else {
            throw StorageFailure.destinationExists
        }
        var committed = false
        defer {
            if !committed {
                // Only this save's fresh UUID files; never touch the recovery draft.
                for url in fresh {
                    try? fileManager.removeItem(at: url)
                }
            }
        }

        let fileURL = try OBJExporter.exportPointCloudPLY(
            meshData: meshData,
            fileName: scanId.uuidString,
            directory: scanDir
        )
        let fileSize = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0

        var scan = Scan(name: name, fileName: fileName, vertexCount: meshData.vertexCount, faceCount: 0, fileSize: fileSize)
        scan.hasColor = !meshData.colors.isEmpty
        scan.boundingBoxMin = meshData.boundingBoxMin
        scan.boundingBoxMax = meshData.boundingBoxMax

        // Drift record: bound to the exact bytes just written, because it lists
        // the segment of each point in file order.
        var alignmentSummary: ScanAlignmentSummary?
        if alignment != nil || alignmentDocument != nil {
            let hash = try measurementSHA256(fileURL)
            let document: ScanAlignmentDocument
            if let alignmentDocument {
                document = try alignmentDocument(hash)
            } else if let alignment {
                document = DriftPipeline.document(prepared: alignment.prepared, capture: alignment.capture,
                    pointSegments: alignment.pointSegments, frame: alignment.frame, modelSHA256: hash)
            } else { throw ScanAlignmentError.invalidDocument }
            guard document.pointCount == meshData.vertexCount, document.modelSHA256 == hash else {
                throw ScanAlignmentError.invalidDocument
            }
            try document.validate()
            let bytes = try JSONEncoder().encode(document)
            guard bytes.count <= ScanAlignmentDocument.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            try bytes.write(to: alignmentURL, options: .atomic)
            alignmentSummary = document.summary.sanitised
        }
        if let references, !references.isEmpty {
            try references.validate()
            try JSONEncoder().encode(references).write(to: referencesURL, options: .atomic)
        }

        // Native point-cloud scene for fast in-app viewing
        let node = MeshProcessor.createPointCloudNode(from: meshData)
        let scene = SCNScene()
        scene.rootNode.addChildNode(node)
        guard writePointCloudScene(scene, to: scnURL) else { throw PointCloudSaveError.nativeSceneWriteFailed }

        scan.thumbnailData = generateThumbnail(fromModelURL: scnURL)

        if let bundle = splatBundle {
            try fileManager.copyItem(at: bundle, to: bundleURL)
            scan.splatBundleName = bundleURL.lastPathComponent
        }
        metadata?(&scan)   // stored in the same index write as the scan itself
        if let alignmentSummary { scan.alignment = alignmentSummary }
        scan.terrainCapture = try scan.terrainCapture?.normalized()
        try addScan(scan, to: project)
        committed = true
        return scan
    }

    // MARK: - Drift record, as-captured and fitted copies

    /// The scan's drift record, or nil when it has none (older scans, meshes).
    /// A record that no longer matches the model file is refused, never reused.
    func loadAlignment(for scan: Scan, in project: Project) throws -> ScanAlignmentDocument? {
        let url = try measurementSidecar(ScanAlignmentDocument.suffix, scan: scan, project: project)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let document = try JSONDecoder().decode(ScanAlignmentDocument.self,
            from: boundedMeasurementData(url, maximumBytes: ScanAlignmentDocument.maximumBytes))
        try document.validate()
        let model = try LibraryFileSafety.child(scan.fileName, of: validatedDirectory(for: project))
        guard document.pointCount == scan.vertexCount, try measurementSHA256(model) == document.modelSHA256 else {
            throw ScanAlignmentError.staleModel
        }
        return document
    }

    func loadReferences(for scan: Scan, in project: Project) throws -> ScanReferenceDocument {
        let url = try measurementSidecar(ScanReferenceDocument.suffix, scan: scan, project: project)
        guard fileManager.fileExists(atPath: url.path) else { return ScanReferenceDocument() }
        let document = try JSONDecoder().decode(ScanReferenceDocument.self,
            from: boundedMeasurementData(url, maximumBytes: ScanReferenceDocument.maximumBytes))
        try document.validate()
        return document
    }

    func saveReferences(_ references: ScanReferenceDocument, for scan: Scan, in project: Project) throws {
        try references.validate()
        try onMain {
            guard !isLibraryReadOnly else { throw StorageFailure.readOnly }
            guard let current = projects.first(where: { $0.id == project.id })?.scans.first(where: { $0.id == scan.id }),
                  current.fileName == scan.fileName else { throw StorageFailure.missingItem }
            let url = try measurementSidecar(ScanReferenceDocument.suffix, scan: scan, project: project)
            if references.isEmpty {
                if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
                return
            }
            let bytes = try JSONEncoder().encode(references)
            guard bytes.count <= ScanReferenceDocument.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            try bytes.write(to: url, options: .atomic)
        }
    }

    private func copyPlacement(from scan: Scan, to copy: inout Scan) {
        copy.sceneFrame = scan.sceneFrame; copy.coordinateProvenance = scan.coordinateProvenance
        copy.northAligned = scan.northAligned; copy.latitude = scan.latitude; copy.longitude = scan.longitude
        copy.altitude = scan.altitude; copy.locationAccuracy = scan.locationAccuracy
        copy.locationTimestamp = scan.locationTimestamp; copy.verticalLocationAccuracy = scan.verticalLocationAccuracy
        copy.locationReducedAccuracy = scan.locationReducedAccuracy; copy.locationReference = scan.locationReference
        copy.terrainCapture = scan.terrainCapture
    }

    private func storedPointCloud(of scan: Scan, in project: Project) throws -> (positions: [SIMD3<Float>], colors: [SIMD4<Float>]) {
        let model = try LibraryFileSafety.child(scan.fileName, of: validatedDirectory(for: project))
        guard scan.faceCount == 0, model.pathExtension.lowercased() == "ply", fileManager.fileExists(atPath: model.path) else {
            throw ScanAlignmentError.noSegments
        }
        let cloud = try PointCloudPLYReader.read(model)
        guard cloud.positions.count == scan.vertexCount else { throw ScanAlignmentError.staleModel }
        return cloud
    }

    /// New library item holding the points exactly as the phone recorded them
    /// (before any drift correction). The corrected scan is left untouched.
    func saveAsCapturedCopy(of scan: Scan, in project: Project) throws -> Scan {
        guard let document = try loadAlignment(for: scan, in: project) else { throw ScanAlignmentError.noSegments }
        let cloud = try storedPointCloud(of: scan, in: project)
        let restored = try DriftPipeline.asCaptured(points: cloud.positions, document: document)
        let bounds = MeshData.bounds(of: restored)
        let mesh = MeshData(vertices: restored, normals: [], faces: [], colors: cloud.colors,
                            boundingBoxMin: bounds.0, boundingBoxMax: bounds.1)
        var summary = document.summary
        summary.corrected = false; summary.asCapturedCopy = true; summary.largestMoveMetres = 0
        let copySummary = summary
        return try savePointCloud(meshData: mesh, name: scan.name + " · As captured", toProject: project,
            alignmentDocument: { hash in
                // The copy keeps the walk recording, so it can still be lined up or fitted later.
                var copy = document
                copy.modelSHA256 = hash
                copy.summary = copySummary
                copy.segments = copy.segments.map { var s = $0; s.saved = s.captured; return s }
                return copy
            }) {
            self.copyPlacement(from: scan, to: &$0)
            $0.notes = "Points as the phone recorded them, before drift correction. Measurements are not copied."
        }
    }

    /// New library item fitted to the scan's references (known distances,
    /// straight lines, control points). The source scan is left untouched.
    func saveFittedCopy(of scan: Scan, in project: Project, references: ScanReferenceDocument,
                        cancelled: () -> Bool = { false }) throws -> Scan {
        let cloud = try storedPointCloud(of: scan, in: project)
        let document = try loadAlignment(for: scan, in: project)
        let segments = document.map { ScanAlignmentDocument.unpackSegments($0.pointSegments) }
            ?? [UInt16](repeating: 0, count: cloud.positions.count)
        let up = document.flatMap { ScanReferenceDocument.vector($0.up) } ?? SIMD3<Double>(0, 1, 0)
        let fit = try DriftReferences.fit(points: cloud.positions, segments: segments,
            poses: document?.savedPoses ?? [.identity], captured: document?.phonePoses ?? [.identity],
            links: document?.links.map(ScanAlignmentDocument.unpackLink) ?? [], up: up, references: references,
            cancelled: cancelled)
        let bounds = MeshData.bounds(of: fit.points)
        let mesh = MeshData(vertices: fit.points, normals: [], faces: [], colors: cloud.colors,
                            boundingBoxMin: bounds.0, boundingBoxMax: bounds.1)
        var summary = document?.summary ?? ScanAlignmentSummary(pathLengthMetres: 0, segmentCount: 0, trackingJumps: 0,
            fastTurnSeconds: 0, phoneCorrectionMetres: 0, overlap: "notRun", largestMoveMetres: 0, corrected: true)
        summary.corrected = true; summary.fittedToReferences = true; summary.asCapturedCopy = nil
        summary.largestMoveMetres = max(summary.largestMoveMetres, fit.largestMoveMetres)
        summary.siteOrigin = fit.siteOrigin
        let fittedSummary = summary
        var builder: ((String) throws -> ScanAlignmentDocument)?
        if let document {
            builder = { hash in
                var copy = document
                copy.modelSHA256 = hash
                copy.summary = fittedSummary
                let frame = fit.frame
                let rotatedUp = frame.rotate(up)
                copy.up = [rotatedUp.x, rotatedUp.y, rotatedUp.z]
                if let old = RigidPose(array: document.captureToSaved) { copy.captureToSaved = frame.composed(with: old).array }
                copy.segments = try document.segments.enumerated().map { index, segment -> ScanAlignmentDocument.Segment in
                    guard index < fit.poses.count, let captured = RigidPose(array: segment.captured),
                          let phone = RigidPose(array: segment.phone) else { throw ScanAlignmentError.invalidDocument }
                    return ScanAlignmentDocument.Segment(captured: frame.composed(with: captured).array,
                        phone: frame.composed(with: phone).array, saved: fit.poses[index].array, startTime: segment.startTime)
                }
                return copy
            }
        }
        let controlCount = references.controls.count
        return try savePointCloud(meshData: mesh, name: scan.name + " · Fitted", toProject: project,
                                  alignmentDocument: builder, references: fit.references) {
            self.copyPlacement(from: scan, to: &$0)
            if let origin = fit.siteOrigin {
                // Now in the surveyor's grid (minus a whole-metre origin): the old
                // capture-to-local transform no longer describes these coordinates.
                $0.sceneFrame = nil
                $0.coordinateProvenance = CoordinateProvenance(sourceKind: "lidar", scaleStatus: .lidarMetric,
                    alignmentMethod: "fitted to \(controlCount) control points (heading and position)", captureToLocal: nil,
                    localDatum: String(format: "Control-point grid: X = east − %.0f, Y = height − %.0f, Z = −(north − %.0f)",
                                       origin[0], origin[2], origin[1]))
            }
            $0.alignment = fittedSummary.sanitised
            $0.notes = "Fitted to references. The source scan is unchanged. Measurements are not copied."
        }
    }

    /// Native-test seam for a failed SceneKit write; production uses the same writer.
    func writePointCloudScene(_ scene: SCNScene, to url: URL) -> Bool {
        scene.write(to: url, delegate: nil)
    }

    /// Render a thumbnail from a model file (USDZ/OBJ/SCN).
    private func generateThumbnail(fromModelURL url: URL) -> Data? {
        guard let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) else { return nil }

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 600
        scene.rootNode.addChildNode(ambient)

        let dir = SCNNode()
        dir.light = SCNLight()
        dir.light!.type = .directional
        dir.light!.intensity = 800
        dir.position = SCNVector3(5, 10, 5)
        dir.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(dir)

        let (minB, maxB) = scene.rootNode.flattenedClone().boundingBox
        let center = MeshProcessor.calculateCenter(min: minB, max: maxB)
        let distance = MeshProcessor.calculateViewDistance(min: minB, max: maxB)

        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.position = SCNVector3(center.x + distance * 0.3, center.y + distance * 0.4, center.z + distance * 0.8)
        cam.look(at: center)
        scene.rootNode.addChildNode(cam)
        scene.background.contents = UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)

        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cam
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 120, height: 120), antialiasingMode: .multisampling4X)
        return image.jpegData(compressionQuality: 0.7)
    }

    /// Every file that belongs to a scan, relative to its project folder:
    /// the model, its .mtl / texture, the internal .scn viewer file, a splat
    /// bundle zip, and the folder of kept High-Quality photos.
    private static func fileNames(of scan: Scan) -> [String] {
        let base = (scan.fileName as NSString).deletingPathExtension
        var names = [scan.fileName, "\(base).mtl", "\(base).scn", "\(base)_measurements.json",
                     base + SurfaceLabelDocument.suffix, base + AutomaticMeasurementDocument.suffix,
                     base + ScanAlignmentDocument.suffix, base + ScanReferenceDocument.suffix]
        if scan.originalMeshSHA256 != nil { names.append(base + "_original.mesh") }
        if let t = scan.textureFileName { names.append(t) }
        if let z = scan.splatBundleName { names.append(z) }
        if let p = scan.captureFolderName { names.append(p); names.append(p + PoseFile.suffix) }
        names += scan.retainedReconstructionFiles ?? []
        return Array(Set(names)).sorted()
    }

    private func companionFiles(of scan: Scan) -> [String] { Self.fileNames(of: scan) }

    func deleteScan(_ scan: Scan, from project: Project) {
        perform("Delete scan") {
            var candidate = projects
            guard let index = candidate.firstIndex(where: { $0.id == project.id }),
                  let current = candidate[index].scans.first(where: { $0.id == scan.id }) else { throw StorageFailure.missingItem }
            let dir = try validatedDirectory(for: project)
            try validateFiles(of: current, in: dir)
            candidate[index].scans.removeAll { $0.id == scan.id }
            candidate[index].modifiedAt = Date()
            try commitProjects(candidate)
            try removeExistingItems(companionFiles(of: current).map { dir.appendingPathComponent($0) })
        }
    }

    func renameScan(_ scan: Scan, in project: Project, newName: String) {
        perform("Rename scan") {
            try updateScan(scan.id, in: project) { $0.name = newName }
        }
    }

    /// Move a scan (and all its files) from one project to another
    @discardableResult
    func moveScan(_ scan: Scan, from sourceProject: Project, to destProject: Project) -> Bool {
        guard sourceProject.id != destProject.id else { return true }
        return perform("Move scan") {
            var candidate = projects
            guard let srcIndex = candidate.firstIndex(where: { $0.id == sourceProject.id }),
                  let dstIndex = candidate.firstIndex(where: { $0.id == destProject.id }),
                  let current = candidate[srcIndex].scans.first(where: { $0.id == scan.id }),
                  !candidate[dstIndex].scans.contains(where: { $0.id == scan.id }) else { throw StorageFailure.missingItem }
            let sourceDir = try validatedDirectory(for: sourceProject)
            let destDir = try validatedDirectory(for: destProject)
            try validateFiles(of: current, in: sourceDir, requireRegistered: true)
            // The primary model and all explicitly registered companions are required.
            let required = [current.fileName] + [current.textureFileName, current.splatBundleName, current.captureFolderName].compactMap { $0 }
                + (current.retainedReconstructionFiles ?? [])
                + (current.originalMeshSHA256 == nil ? [] : [(current.fileName as NSString).deletingPathExtension + "_original.mesh"])
            guard required.allSatisfy({ fileManager.fileExists(atPath: sourceDir.appendingPathComponent($0).path) }) else {
                throw StorageFailure.missingItem
            }
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
            let files = companionFiles(of: current).filter { fileManager.fileExists(atPath: sourceDir.appendingPathComponent($0).path) }
            let copies = files.map { (source: sourceDir.appendingPathComponent($0), destination: destDir.appendingPathComponent($0)) }
            // Existing destinations may be recovery data, not disposable orphans.
            // copyAndCommit rejects collisions without deleting either copy.
            candidate[srcIndex].scans.removeAll { $0.id == scan.id }
            candidate[srcIndex].modifiedAt = Date()
            candidate[dstIndex].addScan(current)
            try persistence.copyAndCommit(copies) { try commitProjects(candidate) }
            // A cleanup failure after commit is safe: the new copy is already indexed.
            do { try removeExistingItems(copies.map { $0.source }) }
            catch { report(error, action: "Scan moved; some old copies could not be cleaned up") }
        }
    }

    /// Duplicate a scan (and all its files) within the same or a different project
    func duplicateScan(_ scan: Scan, from sourceProject: Project, to destProject: Project) -> Scan? {
        do { return try onMain { try duplicateStoredScan(scan, from: sourceProject, to: destProject) } }
        catch { report(error, action: "Duplicate scan"); return nil }
    }

    private func duplicateStoredScan(_ requested: Scan, from sourceProject: Project, to destProject: Project) throws -> Scan {
        guard !isLibraryReadOnly,
              let scan = projects.first(where: { $0.id == sourceProject.id })?.scans.first(where: { $0.id == requested.id }),
              projects.contains(where: { $0.id == destProject.id }) else { throw StorageFailure.missingItem }
        let sourceDir = try validatedDirectory(for: sourceProject)
        let finalDir = try validatedDirectory(for: destProject)
        try validateFiles(of: scan, in: sourceDir, requireRegistered: true)
        try fileManager.createDirectory(at: finalDir, withIntermediateDirectories: true)

        let oldBase = (scan.fileName as NSString).deletingPathExtension
        let newBase = UUID().uuidString
        let destDir = finalDir.appendingPathComponent(".duplicate-" + newBase)
        guard !fileManager.fileExists(atPath: destDir.path) else { throw StorageFailure.destinationExists }
        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: destDir) }
        let copied: ModelCopy
        copied = try copyModel(of: scan, from: sourceDir, to: destDir, newBase: newBase)
        // Extra files: internal viewer scene, splat bundle, kept photos.
        func copyExtra(_ name: String?, as newName: String, required: Bool = false) throws -> String? {
            guard let name = name else { return nil }
            let src = try LibraryFileSafety.child(name, of: sourceDir)
            guard fileManager.fileExists(atPath: src.path) else {
                if required { throw StorageFailure.missingItem }
                return nil
            }
            try LibraryFileSafety.validateTree(src)
            let dst = destDir.appendingPathComponent(newName)
            try fileManager.copyItem(at: src, to: dst)
            return newName
        }
        _ = try copyExtra("\(oldBase).scn", as: "\(newBase).scn")
        _ = try copyExtra("\(oldBase)_measurements.json", as: "\(newBase)_measurements.json")
        // Point files are copied byte for byte, so the drift record's model hash stays valid.
        _ = try copyExtra(oldBase + ScanAlignmentDocument.suffix, as: newBase + ScanAlignmentDocument.suffix)
        _ = try copyExtra(oldBase + ScanReferenceDocument.suffix, as: newBase + ScanReferenceDocument.suffix)
        // A duplicate must not silently lose automatic results / semantic labels.
        // OBJ material references are renamed during copying, changing the byte
        // hash but not geometry. Rebind ONLY validated, current version-1 data.
        // Unknown future versions and already-stale data remain byte-for-byte.
        do {
            for suffix in [SurfaceLabelDocument.suffix, AutomaticMeasurementDocument.suffix] {
                let source = sourceDir.appendingPathComponent(oldBase + suffix)
                if fileManager.fileExists(atPath: source.path) {
                    let destination = destDir.appendingPathComponent(newBase + suffix)
                    try fileManager.copyItem(at: source, to: destination)
                    struct Header: Decodable { let version: Int }
                    let bytes = try boundedMeasurementData(source, maximumBytes: 24_000_000)
                    guard try JSONDecoder().decode(Header.self, from: bytes).version == 1 else { continue }
                    let oldModelHash = try measurementSHA256(sourceDir.appendingPathComponent(scan.fileName))
                    let newModelHash = try measurementSHA256(copied.model)
                    let oldViewer = sourceDir.appendingPathComponent(oldBase + ".scn")
                    let newViewer = destDir.appendingPathComponent(newBase + ".scn")
                    let oldViewerHash = fileManager.fileExists(atPath: oldViewer.path) ? try measurementSHA256(oldViewer) : nil
                    let newViewerHash = fileManager.fileExists(atPath: newViewer.path) ? try measurementSHA256(newViewer) : nil
                    guard oldViewerHash == newViewerHash else { throw AutomaticMeasurementError.staleModel }
                    if suffix == SurfaceLabelDocument.suffix {
                        var document = try JSONDecoder().decode(SurfaceLabelDocument.self, from: bytes)
                        try document.validate()
                        if document.modelSHA256 == oldModelHash && document.viewerSHA256 == oldViewerHash {
                            document.modelSHA256 = newModelHash
                            try JSONEncoder().encode(document).write(to: destination, options: .atomic)
                        }
                    } else {
                        var document = try AutomaticMeasurementDocument.decode(bytes)
                        let expected = MeasurementModelRevision(modelSHA256: oldModelHash,
                            worldTransform: try scan.validatedModelTransform(), viewerSHA256: oldViewerHash)
                        if document.revision == expected {
                            document.revision.modelSHA256 = newModelHash
                            try document.encoded().write(to: destination, options: .atomic)
                        }
                    }
                }
            }
        } catch {
            throw error
        }

        var newScan = Scan(
            name: "\(scan.name) (Copy)",
            fileName: copied.model.lastPathComponent,
            vertexCount: scan.vertexCount,
            faceCount: scan.faceCount,
            fileSize: scan.fileSize
        )
        newScan.hasTexture = scan.hasTexture
        newScan.textureQuality = scan.textureQuality
        newScan.meshRetention = scan.meshRetention
        newScan.terrainCapture = scan.terrainCapture
        newScan.alignment = scan.alignment
        if let hash = scan.originalMeshSHA256 {
            do {
                let source = sourceDir.appendingPathComponent(oldBase + "_original.mesh")
                guard try measurementSHA256(source) == hash else { throw CocoaError(.fileReadCorruptFile) }
                try fileManager.copyItem(at: source, to: destDir.appendingPathComponent(newBase + "_original.mesh"))
                newScan.originalMeshSHA256 = hash
            } catch { throw error }
        }
        newScan.hasColor = scan.hasColor
        newScan.boundingBoxMin = scan.boundingBoxMin
        newScan.boundingBoxMax = scan.boundingBoxMax
        newScan.thumbnailData = scan.thumbnailData
        newScan.notes = scan.notes
        newScan.modelScale = scan.modelScale
        newScan.textureFileName = copied.textureName
        newScan.splatBundleName = try copyExtra(scan.splatBundleName, as: "\(newBase)_bundle.zip", required: true)
        newScan.captureFolderName = try copyExtra(scan.captureFolderName, as: "\(newBase)_photos", required: true)
        _ = try copyExtra(scan.captureFolderName.map { $0 + PoseFile.suffix }, as: "\(newBase)_photos" + PoseFile.suffix)
        newScan.modelTransform = scan.modelTransform
        newScan.sceneFrame = scan.sceneFrame
        newScan.coordinateProvenance = scan.coordinateProvenance
        newScan.northAligned = scan.northAligned
        newScan.latitude = scan.latitude
        newScan.longitude = scan.longitude
        newScan.altitude = scan.altitude
        newScan.locationAccuracy = scan.locationAccuracy
        newScan.locationTimestamp = scan.locationTimestamp
        newScan.verticalLocationAccuracy = scan.verticalLocationAccuracy
        newScan.locationReducedAccuracy = scan.locationReducedAccuracy
        newScan.locationReference = scan.locationReference

        let files = try fileManager.contentsOfDirectory(at: destDir, includingPropertiesForKeys: nil)
        try persistence.copyAndCommit(files.map { (source: $0, destination: finalDir.appendingPathComponent($0.lastPathComponent)) }) {
            try addScan(newScan, to: destProject)
        }
        return newScan
    }

    // MARK: - Model Copying

    struct ModelCopy {
        let model: URL
        let textureName: String?
        let allFiles: [URL]
    }

    /// Copy a scan's model under a new base name. For OBJ, the .mtl and texture
    /// come along and the file references inside are rewritten, so the copy
    /// still finds its material and texture.
    private func copyModel(of scan: Scan, from srcDir: URL, to dstDir: URL, newBase: String) throws -> ModelCopy {
        try validateFiles(of: scan, in: srcDir)
        try validateExportCompanions(scan, directory: srcDir)
        let oldBase = (scan.fileName as NSString).deletingPathExtension
        let ext = (scan.fileName as NSString).pathExtension
        let src = srcDir.appendingPathComponent(scan.fileName)
        let dst = dstDir.appendingPathComponent("\(newBase).\(ext)")
        guard !fileManager.fileExists(atPath: dst.path) else { throw StorageFailure.destinationExists }

        guard ext.lowercased() == "obj" else {
            try fileManager.copyItem(at: src, to: dst)
            return ModelCopy(model: dst, textureName: nil, allFiles: [dst])
        }

        try copyPatchingHeader(from: src, to: dst, replacing: "\(oldBase).mtl", with: "\(newBase).mtl")
        var files = [dst]

        var newTexture: String?
        if let tex = scan.textureFileName {
            let texSrc = srcDir.appendingPathComponent(tex)
            if fileManager.fileExists(atPath: texSrc.path) {
                let name = "\(newBase)_texture.\((tex as NSString).pathExtension)"
                let texDst = dstDir.appendingPathComponent(name)
                guard !fileManager.fileExists(atPath: texDst.path) else { throw StorageFailure.destinationExists }
                try fileManager.copyItem(at: texSrc, to: texDst)
                newTexture = name
                files.append(texDst)
            } else { throw StorageFailure.missingItem }
        }

        let mtlSrc = srcDir.appendingPathComponent("\(oldBase).mtl")
        if fileManager.fileExists(atPath: mtlSrc.path) {
            var mtl = try String(contentsOf: mtlSrc, encoding: .utf8)
            if let tex = scan.textureFileName, let newTex = newTexture {
                mtl = mtl.replacingOccurrences(of: tex, with: newTex)
            }
            let mtlDst = dstDir.appendingPathComponent("\(newBase).mtl")
            try mtl.write(to: mtlDst, atomically: true, encoding: .utf8)
            files.append(mtlDst)
        }
        return ModelCopy(model: dst, textureName: newTexture, allFiles: files)
    }

    /// Stream-copy OBJ references, including late material declarations and
    /// UTF-8 characters that cross a read boundary.
    private func copyPatchingHeader(from src: URL, to dst: URL, replacing old: String, with new: String) throws {
        guard fileManager.createFile(atPath: dst.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }

        try ExportText.lines(src) { line in
            try output.write(contentsOf: Data((line.replacingOccurrences(of: old, with: new) + "\n").utf8))
        }
        try output.synchronize()
    }

    private func exportBaseName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .replacingOccurrences(of: " ", with: "_")
        return cleaned.isEmpty ? "Scan" : cleaned
    }

    // MARK: - Import

    /// File copying and native model parsing must not block the app's main/UI
    /// thread. Index publication still occurs on main after each complete import.
    func importFiles(_ urls: [URL], to project: Project) {
        guard !isImporting, !isExporting else { return }
        isImporting = true
        exportQueue.async {
            var failures: [String] = []
            for url in urls {
                do { _ = try self.importOBJFile(from: url, name: url.deletingPathExtension().lastPathComponent, toProject: project) }
                catch {
                    let message = error is CoordinateError
                        ? "The model or its companion files are incomplete or unsupported. OBJ imports need a same-name MTL and, if textured, one same-base _texture.jpg or _texture.png. PLY imports must have valid bounded geometry."
                        : error.localizedDescription
                    failures.append("\(url.lastPathComponent): \(message)")
                }
            }
            DispatchQueue.main.async {
                self.isImporting = false
                if !failures.isEmpty { self.storageError = "Some imports failed. Existing scans are unchanged.\n" + failures.joined(separator: "\n") }
            }
        }
    }

    func importOBJFile(from sourceURL: URL, name: String, toProject project: Project) throws -> Scan {
        let scanId = UUID()
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard ["obj", "ply"].contains(fileExtension) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let fileName = "\(scanId.uuidString).\(fileExtension)"
        let scanDir = try writableDirectory(for: project)
        try fileManager.createDirectory(at: scanDir, withIntermediateDirectories: true)
        let candidates = try newCandidateFiles(base: scanId.uuidString, extension: fileExtension, directory: scanDir)
        var committed = false
        defer { if !committed { try? removeExistingItems(candidates) } }

        let destURL = scanDir.appendingPathComponent(fileName)

        // Start accessing security-scoped resource
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
        }
        try LibraryFileSafety.validateTree(sourceURL)
        let sourceSize = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard sourceSize.isRegularFile == true, let size = sourceSize.fileSize, size > 0, size <= 512 * 1024 * 1024 else {
            throw CocoaError(.fileReadTooLarge)
        }

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let newBase = scanId.uuidString
        let sourceDir = sourceURL.deletingLastPathComponent()
        var textureName: String?
        if fileExtension == "obj" {
            let materials = try ExportText.objMaterialReferences(sourceURL)
            guard materials.isEmpty || materials == [baseName + ".mtl"] else { throw CoordinateError.incompleteExport }
            if let material = materials.first {
                let mtlSourceURL = try LibraryFileSafety.child(material, of: sourceDir)
                try LibraryFileSafety.validateTree(mtlSourceURL)
                let mtlSize = try mtlSourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard mtlSize <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
                let textures = try ExportText.materialTextureReferences(mtlSourceURL)
                guard textures.count <= 1 else { throw CoordinateError.incompleteExport }
                if let texture = textures.first {
                    guard [baseName + "_texture.jpg", baseName + "_texture.png"].contains(texture) else {
                        throw CoordinateError.incompleteExport
                    }
                    let textureSource = try LibraryFileSafety.child(texture, of: sourceDir)
                    try LibraryFileSafety.validateTree(textureSource)
                    let textureSize = try textureSource.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    guard textureSize > 0, textureSize <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    // Compressed bytes alone do not bound decoded image memory.
                    // Match the largest native atlas; inspect metadata without
                    // allocating the decompressed bitmap before SceneKit loads it.
                    guard let image = CGImageSourceCreateWithURL(textureSource as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                          CGImageSourceGetCount(image) == 1,
                          let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                          width.intValue > 0, height.intValue > 0,
                          width.intValue <= 8192, height.intValue <= 8192 else { throw CocoaError(.fileReadCorruptFile) }
                    let renamed = newBase + "_texture." + textureSource.pathExtension
                    try fileManager.copyItem(at: textureSource, to: scanDir.appendingPathComponent(renamed))
                    textureName = renamed
                }
                let mtl = try String(contentsOf: mtlSourceURL, encoding: .utf8)
                    .replacingOccurrences(of: baseName + "_texture", with: newBase + "_texture")
                try mtl.write(to: scanDir.appendingPathComponent(newBase + ".mtl"), atomically: true, encoding: .utf8)
            }
            // Point the copy at its renamed .mtl
            try copyPatchingHeader(from: sourceURL, to: destURL,
                                   replacing: "\(baseName).mtl", with: "\(newBase).mtl")
        } else {
            try ExportText.validatePLYHeader(sourceURL)
            try fileManager.copyItem(at: sourceURL, to: destURL)
        }

        let fileSize = (try? fileManager.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
        let scene = try SCNScene(url: destURL, options: [.checkConsistency: true])
        var vertexCount = 0, faceCount = 0, hasColor = false
        var invalid = false
        scene.rootNode.enumerateChildNodes { node, stop in
            guard let geometry = node.geometry else { return }
            let count = geometry.sources(for: .vertex).first?.vectorCount ?? 0
            guard count >= 0, count <= 5_000_000 - vertexCount else { invalid = true; stop.pointee = true; return }
            vertexCount += count
            for element in geometry.elements where element.primitiveType == .triangles {
                guard element.primitiveCount >= 0, element.primitiveCount <= 5_000_000 - faceCount else {
                    invalid = true; stop.pointee = true; return
                }
                faceCount += element.primitiveCount
            }
            hasColor = hasColor || !geometry.sources(for: .color).isEmpty
        }
        guard !invalid, vertexCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let measuredBounds = try SceneCoordinateValidation.bounds(scene: scene)
        guard measuredBounds.vertexCount == vertexCount,
              let safeBounds = ViewerGeometryLimits.bounds(low: SIMD3<Float>(measuredBounds.minimum),
                                                           high: SIMD3<Float>(measuredBounds.maximum)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var scan = Scan(
            name: name,
            fileName: fileName,
            vertexCount: vertexCount,
            faceCount: faceCount,
            fileSize: fileSize
        )
        scan.textureFileName = textureName
        scan.hasTexture = textureName != nil
        scan.hasColor = hasColor
        scan.boundingBoxMin = safeBounds.low
        scan.boundingBoxMax = safeBounds.high
        scan.coordinateProvenance = CoordinateProvenance(sourceKind: "imported", scaleStatus: .unknown,
            alignmentMethod: "none", localDatum: "Unknown source origin and units; calibration required")

        try addScan(scan, to: project)
        committed = true
        return scan
    }

    // MARK: - Export / Share

    func exportScan(_ scan: Scan, from project: Project) throws -> URL {
        try exportPackage([scan], project: project, name: scan.name, kind: .native)
    }
    func exportProject(_ project: Project) throws -> URL {
        try exportPackage(project.scans, project: project, name: project.name, kind: .native)
    }

    // MARK: - CAD / 3D-print exports (Z up)

    /// OBJ with Z pointing up (the usual convention in CAD). Textured OBJ scans
    /// keep their texture (shared as a .zip); other models export their geometry.
    func exportZUpOBJ(_ scan: Scan, from project: Project) throws -> URL {
        try exportPackage([scan], project: project, name: scan.name + "_Zup", kind: .zUpOBJ)
    }

    /// Binary STL in millimetres with Z up (3D printing and most CAD tools).
    func exportSTL(_ scan: Scan, from project: Project) throws -> URL {
        try exportPackage([scan], project: project, name: scan.name + "_mm", kind: .stl)
    }

    private enum ModelExportKind { case native, zUpOBJ, stl }

    private func exportPackage(_ scans: [Scan], project: Project, name: String, kind: ModelExportKind) throws -> URL {
        guard !scans.isEmpty else { throw CoordinateError.incompleteExport }
        let request = documentsDirectory.appendingPathComponent(AppConstants.exportDirectory)
            .appendingPathComponent("Share").appendingPathComponent(UUID().uuidString)
        let package = request.appendingPathComponent("Models")
        try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? fileManager.removeItem(at: request) } }
        let sourceDirectory = scansDirectory.appendingPathComponent(project.id.uuidString)
        for scan in scans {
            try exportCancellation.check()
            onMain { exportMessage = "Preparing \(scan.name)…" }
            let transform = try scan.validatedModelTransform()
            if kind != .native, !scan.hasKnownScale { throw CoordinateError.unknownScale }
            let base = "model" // Each scan has its own UUID folder: no collisions/path injection.
            let folder = package.appendingPathComponent(scan.id.uuidString)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = getScanFileURL(scan: scan, project: project)
            let sourceHash = try exportSHA256(source)
            let ext = source.pathExtension.lowercased()
            var limitations = [scan.scaleDescription, "Local coordinates, not georeferenced. Phone GPS is not survey control.",
                               "Model delivery only: not a project backup. Photos and measurements are not included."]
            if let origin = scan.alignment?.siteOrigin, origin.count == 3 {
                limitations[1] = String(format: "Fitted to control points entered in the app: X = east − %.0f, Y = height − %.0f, Z = −(north − %.0f). Verify against your control before use.", origin[0], origin[2], origin[1])
            }
            let model: URL
            switch kind {
            case .native:
                if ext == "usdz", transform != CoordinateMath.identity {
                    model = folder.appendingPathComponent("\(base).usdz")
                    try AlignedUSDZ.write(source: source, to: model, transform: transform, cancelled: { self.exportCancellation.isCancelled })
                    try exportCancellation.check()
                    try SceneCoordinateValidation.verify(source: source, exported: model, transform: transform)
                } else {
                    guard transform == CoordinateMath.identity else { throw CoordinateError.unsupportedArchive }
                    model = try copyModel(of: scan, from: sourceDirectory, to: folder, newBase: base).model
                }
            case .zUpOBJ:
                if ext == "obj", transform == CoordinateMath.identity {
                    model = try copyModel(of: scan, from: sourceDirectory, to: folder, newBase: base).model
                    try StorageManager.convertOBJToZUp(at: model, cancelled: { self.exportCancellation.isCancelled })
                } else {
                    let triangles = try worldTriangles(of: scan, in: project)
                    guard !triangles.isEmpty else { throw CoordinateError.incompleteExport }
                    model = folder.appendingPathComponent("\(base).obj")
                    try StorageManager.writeOBJ(triangles: triangles, to: model, cancelled: { self.exportCancellation.isCancelled })
                    limitations.append("Converted CAD mesh is geometry-only; materials are not included.")
                }
            case .stl:
                let triangles = try worldTriangles(of: scan, in: project)
                guard !triangles.isEmpty else { throw CoordinateError.incompleteExport }
                model = folder.appendingPathComponent("\(base).stl")
                try writeSTL(triangles, to: model)
                limitations.append("STL does not embed units or colour; coordinates are millimetres.")
            }
            try exportCancellation.check()
            // A replacement/move/delete during export must not silently change its source revision.
            guard try exportSHA256(source) == sourceHash else { throw CoordinateError.incompleteExport }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            if let terrain = scan.terrainCapture, kind == .native {
                guard ext == "ply", transform == CoordinateMath.identity, scan.hasKnownScale else {
                    throw CoordinateError.incompleteExport
                }
                let terrainManifest = try TerrainExportManifest(metadata: terrain, modelFile: model.lastPathComponent,
                    modelSHA256: exportSHA256(model), pointCount: scan.vertexCount)
                try encoder.encode(terrainManifest).write(to: folder.appendingPathComponent("terrain.json"), options: .atomic)
                limitations.append(contentsOf: terrainManifest.limitations)
                limitations.append("Import terrain.json and coordinates.json with the PLY. Saved positions are already transformed: do not apply captureToLocal again.")
            }
            if kind == .native, let summary = scan.alignment {
                // The drift record travels with the points it describes (same bytes, same order).
                limitations.append("Drift correction: " + summary.overlapDescription
                    + String(format: "; largest move %.3f m over a %.0f m walk. Not a field-accuracy guarantee.",
                             summary.largestMoveMetres, summary.pathLengthMetres))
                for (suffix, name) in [(ScanAlignmentDocument.suffix, "alignment.json"), (ScanReferenceDocument.suffix, "references.json")] {
                    let sidecar = sourceDirectory.appendingPathComponent((scan.fileName as NSString).deletingPathExtension + suffix)
                    if fileManager.fileExists(atPath: sidecar.path) {
                        try fileManager.copyItem(at: sidecar, to: folder.appendingPathComponent(name))
                    }
                }
            }
            let factor: Double = kind == .stl ? 1000 : 1
            let convention = kind == .native ? CoordinateMath.identity :
                [factor, 0, 0, 0, 0, 0, factor, 0, 0, -factor, 0, 0, 0, 0, 0, 1]
            let manifest = ModelExportManifest(scanID: scan.id, sourceRevision: scan.fileName, sourceSHA256: sourceHash,
                exportedAt: Date(), modelFile: model.lastPathComponent,
                units: scan.hasKnownScale ? (kind == .stl ? "millimetres" : "metres") : "source units — scale unverified",
                axes: kind == .native ? (scan.hasKnownScale ? "right-handed Y up" : "source convention unverified") : "right-handed Z up; X'=X, Y'=-Z, Z'=Y",
                sourceModelToLocal: transform, localToExport: convention, provenance: scan.coordinateProvenance, limitations: limitations)
            try encoder.encode(manifest).write(to: folder.appendingPathComponent("coordinates.json"), options: .atomic)
            try "\(scan.name)\nOpen \(model.lastPathComponent).\n\(limitations.joined(separator: "\n"))\nSee coordinates.json for units, axes and source revision.\n"
                .write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        }
        try exportCancellation.check()
        guard let zip = StorageManager.zipFolder(package, to: request.appendingPathComponent(exportBaseName(name) + ".zip")) else {
            throw CoordinateError.incompleteExport
        }
        try exportCancellation.check()
        completed = true
        return zip
    }

    private func exportSHA256(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 1 << 20), !data.isEmpty {
            try exportCancellation.check()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func validateExportCompanions(_ scan: Scan, directory: URL) throws {
        try validateFiles(of: scan, in: directory)
        if (scan.fileName as NSString).pathExtension.lowercased() == "obj" {
            let expected = (scan.fileName as NSString).deletingPathExtension + ".mtl"
            let materials = try ExportText.objMaterialReferences(directory.appendingPathComponent(scan.fileName))
            guard materials.isEmpty || materials == [expected] else { throw CoordinateError.incompleteExport }
            if !materials.isEmpty {
                let references = try ExportText.materialTextureReferences(directory.appendingPathComponent(expected))
                guard references.allSatisfy({ $0 == scan.textureFileName &&
                    fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }) else {
                    throw CoordinateError.incompleteExport
                }
            }
        }
        if let texture = scan.textureFileName {
            guard fileManager.fileExists(atPath: directory.appendingPathComponent(texture).path),
                  fileManager.fileExists(atPath: directory.appendingPathComponent((scan.fileName as NSString).deletingPathExtension + ".mtl").path) else {
                throw CoordinateError.incompleteExport
            }
        }
    }

    private func writeSTL(_ triangles: [SIMD3<Float>], to url: URL) throws {
        let count = triangles.count / 3
        guard count <= Int(UInt32.max), triangles.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw CoordinateError.incompleteExport
        }
        guard fileManager.createFile(atPath: url.path, contents: nil) else { throw CoordinateError.incompleteExport }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var header = Data("TinyScanner by TinyCorp — millimetres, Z up".utf8); header.count = 80
        var number = UInt32(count).littleEndian
        withUnsafeBytes(of: &number) { header.append(contentsOf: $0) }
        try handle.write(contentsOf: header)
        for index in 0..<count {
            if index % 4096 == 0 { try exportCancellation.check() }
            func point(_ i: Int) -> SIMD3<Float> { let v = triangles[index * 3 + i]; return SIMD3(v.x, -v.z, v.y) * 1000 }
            let a = point(0), b = point(1), c = point(2)
            let cross = simd_cross(b - a, c - a), length = simd_length(cross)
            let n = length > 0 ? cross / length : SIMD3<Float>(0, 0, 1)
            var data = Data()
            for scalar in [n.x, n.y, n.z, a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z] {
                guard scalar.isFinite else { throw CoordinateError.incompleteExport }
                var bits = scalar.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
            data.append(contentsOf: [0, 0]); try handle.write(contentsOf: data)
        }
        try handle.synchronize()
    }

    /// All triangles of a scan in world space (with its real-world transform),
    /// flattened: every three points are one triangle.
    private func worldTriangles(of scan: Scan, in project: Project) throws -> [SIMD3<Float>] {
        let modelURL = getScanFileURL(scan: scan, project: project)
        let scnURL = modelURL.deletingPathExtension().appendingPathExtension("scn")
        let url = fileManager.fileExists(atPath: scnURL.path) ? scnURL : modelURL
        guard let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) else { return [] }
        let root = SCNNode()
        scene.rootNode.childNodes.forEach { root.addChildNode($0.clone()) }
        if let m = scan.modelMatrix { root.simdTransform = m }

        var result: [SIMD3<Float>] = []
        for source in ModelGeometryIndex.sources(in: root) {
            try exportCancellation.check()
            guard let vsrc = source.geometry.sources(for: .vertex).first, vsrc.usesFloatComponents,
                  vsrc.bytesPerComponent == 4, vsrc.componentsPerVector >= 3,
                  vsrc.dataOffset >= 0, vsrc.dataStride >= 12,
                  vsrc.vectorCount <= vsrc.data.count / vsrc.dataStride + 1 else { throw CoordinateError.incompleteExport }
            let m = source.transform
            var positions = [SIMD3<Float>](repeating: .zero, count: vsrc.vectorCount)
            try vsrc.data.withUnsafeBytes { raw in
                guard raw.baseAddress != nil else { return }
                for i in 0..<vsrc.vectorCount {
                    let start = vsrc.dataOffset + vsrc.dataStride * i
                    guard start <= raw.count - 12 else { throw CoordinateError.incompleteExport }
                    let w = m * SIMD4<Float>(raw.loadUnaligned(fromByteOffset: start, as: Float.self),
                                             raw.loadUnaligned(fromByteOffset: start + 4, as: Float.self),
                                             raw.loadUnaligned(fromByteOffset: start + 8, as: Float.self), 1)
                    guard w.x.isFinite, w.y.isFinite, w.z.isFinite else { throw CoordinateError.incompleteExport }
                    positions[i] = SIMD3<Float>(w.x, w.y, w.z)
                }
            }
            for element in source.geometry.elements where element.primitiveType == .triangles {
                let bpi = element.bytesPerIndex
                guard [1, 2, 4].contains(bpi), element.primitiveCount <= element.data.count / (3 * bpi) else {
                    throw CoordinateError.incompleteExport
                }
                try element.data.withUnsafeBytes { raw in
                    guard raw.baseAddress != nil else { return }
                    for i in 0..<(element.primitiveCount * 3) {
                        let index: Int
                        switch bpi {
                        case 1: index = Int(raw.loadUnaligned(fromByteOffset: i * bpi, as: UInt8.self))
                        case 2: index = Int(raw.loadUnaligned(fromByteOffset: i * bpi, as: UInt16.self))
                        default: index = Int(raw.loadUnaligned(fromByteOffset: i * bpi, as: UInt32.self))
                        }
                        guard index < positions.count else { throw CoordinateError.incompleteExport }
                        result.append(positions[index])
                    }
                }
            }
        }
        return result
    }

    /// Rewrite an OBJ's vertex and normal lines from Y-up to Z-up.
    static func convertOBJToZUp(at url: URL, cancelled: () -> Bool = { false }) throws {
        // url is this export's disposable copy, never the library's source model.
        let temporary = url.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).obj")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CoordinateError.incompleteExport }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try ExportText.lines(url) { line in
            if cancelled() { throw CancellationError() }
            try handle.write(contentsOf: Data((try ExportText.zUpLine(line) + "\n").utf8))
        }
        try handle.synchronize(); try handle.close()
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
    }

    /// Plain OBJ (geometry only, Z up) from world-space triangles.
    static func writeOBJ(triangles: [SIMD3<Float>], to url: URL, cancelled: () -> Bool = { false }) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CoordinateError.incompleteExport }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("# TinyScanner by TinyCorp export - metres, Z up\n".utf8))
        for v in triangles {
            if cancelled() { throw CancellationError() }
            guard v.x.isFinite, v.y.isFinite, v.z.isFinite else { throw CoordinateError.incompleteExport }
            try handle.write(contentsOf: Data("v \(v.x) \(-v.z) \(v.y)\n".utf8))
        }
        for t in 0..<(triangles.count / 3) {
            if cancelled() { throw CancellationError() }
            try handle.write(contentsOf: Data("f \(t * 3 + 1) \(t * 3 + 2) \(t * 3 + 3)\n".utf8))
        }
        try handle.synchronize()
    }

    /// Zip a folder (via NSFileCoordinator, no third-party library).
    static func zipFolder(_ folder: URL, to dest: URL) -> URL? {
        let coordinator = NSFileCoordinator()
        var nsError: NSError?
        var result: URL?
        coordinator.coordinate(readingItemAt: folder, options: [.forUploading], error: &nsError) { zipURL in
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: zipURL, to: dest)) != nil {
                result = dest
            }
        }
        return result
    }

    // MARK: - Thumbnail Generation

    private func generateThumbnail(for meshData: MeshData) -> Data? {
        let node = MeshProcessor.createSceneKitNode(from: meshData)

        let scene = SCNScene()
        scene.rootNode.addChildNode(node)

        // Add lighting
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light!.type = .ambient
        ambientLight.light!.intensity = 500
        scene.rootNode.addChildNode(ambientLight)

        let dirLight = SCNNode()
        dirLight.light = SCNLight()
        dirLight.light!.type = .directional
        dirLight.light!.intensity = 800
        dirLight.position = SCNVector3(5, 10, 5)
        dirLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(dirLight)

        // Camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        let (minBound, maxBound) = node.boundingBox
        let center = MeshProcessor.calculateCenter(min: minBound, max: maxBound)
        let distance = MeshProcessor.calculateViewDistance(min: minBound, max: maxBound)
        cameraNode.position = SCNVector3(center.x + distance * 0.3, center.y + distance * 0.4, center.z + distance * 0.8)
        cameraNode.look(at: center)
        scene.rootNode.addChildNode(cameraNode)
        scene.background.contents = UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)

        // Render thumbnail
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode

        let size = CGSize(width: 120, height: 120)
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        return image.jpegData(compressionQuality: 0.7)
    }

    // MARK: - Helpers

    enum ExportFormat {
        case obj
        case ply
    }
}
