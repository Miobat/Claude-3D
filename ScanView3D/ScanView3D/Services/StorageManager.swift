import Foundation
import SceneKit
import CryptoKit

/// Manages persistent storage for projects and scan files
class StorageManager: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published var storageError: String?
    @Published private(set) var isLibraryReadOnly = false
    @Published private(set) var isExporting = false
    @Published private(set) var exportMessage = ""
    private let exportQueue = DispatchQueue(label: "scanview.export", qos: .userInitiated)
    private let exportCancellation = ExportCancellation()

    func cancelExport() { exportCancellation.cancel() }

    /// One bounded worker; UI only receives a complete package. Exporting is a
    /// model-delivery action, not a project backup or a mutation of saved scans.
    func prepareExport(_ work: @escaping () throws -> URL, completion: @escaping (URL) -> Void) {
        guard !isExporting else { return }
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
    private lazy var persistence = LibraryPersistence<[Project]>(indexURL: projectsFile)
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
            try fileManager.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: scansDirectory, withIntermediateDirectories: true)
            projects = try persistence.load(default: [])
        } catch {
            isLibraryReadOnly = true
            report(error, action: "Open library. Saving is disabled; existing files have been preserved")
        }
    }

    // MARK: - Threading

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
            try fileManager.createDirectory(at: projectsDirectory.appendingPathComponent(project.id.uuidString), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: scansDirectory.appendingPathComponent(project.id.uuidString), withIntermediateDirectories: true)
            try commitProjects(projects + [project])
        } ? project : nil
    }

    func updateProject(_ project: Project) {
        perform("Update project") {
            var candidate = projects
            guard let index = candidate.firstIndex(where: { $0.id == project.id }) else { throw StorageFailure.missingItem }
            candidate[index] = project
            try commitProjects(candidate)
        }
    }

    func deleteProject(_ project: Project) {
        perform("Delete project") {
            try commitProjects(projects.filter { $0.id != project.id })
            // Remove files only AFTER the index commits. Interrupted cleanup leaves
            // recoverable unused files, not a library pointing at missing models.
            try removeExistingItems([
                projectsDirectory.appendingPathComponent(project.id.uuidString),
                scansDirectory.appendingPathComponent(project.id.uuidString)
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
        baked: BakedTexture? = nil
    ) throws -> Scan {
        let scanId = UUID()
        let fileExtension = format == .ply ? "ply" : "obj"
        let fileName = "\(scanId.uuidString).\(fileExtension)"
        let scanDir = scansDirectory.appendingPathComponent(project.id.uuidString)
        try fileManager.createDirectory(at: scanDir, withIntermediateDirectories: true)

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
        scene.write(to: scnURL, delegate: nil)

        // Generate thumbnail
        scan.thumbnailData = generateThumbnail(for: meshData)

        try addScan(scan, to: project)
        return scan
    }

    func getScanFileURL(scan: Scan, project: Project) -> URL {
        return scansDirectory
            .appendingPathComponent(project.id.uuidString)
            .appendingPathComponent(scan.fileName)
    }

    /// Register a scan from an already-produced model file (e.g. a photogrammetry USDZ).
    /// - modelTransform: places the model in real-world space (photogrammetry has no real-world
    ///   scale; we derive this from the LiDAR mesh captured in the same session).
    /// - photosFolder: source photos to keep with the scan for later re-reconstruction.
    func importProcessedModel(modelURL: URL, name: String, toProject project: Project,
                              modelTransform: simd_float4x4? = nil, photosFolder: URL? = nil) throws -> Scan {
        let scanId = UUID()
        let ext = modelURL.pathExtension.isEmpty ? "usdz" : modelURL.pathExtension
        let fileName = "\(scanId.uuidString).\(ext)"
        let scanDir = scansDirectory.appendingPathComponent(project.id.uuidString)
        try fileManager.createDirectory(at: scanDir, withIntermediateDirectories: true)

        let destURL = scanDir.appendingPathComponent(fileName)
        try? fileManager.removeItem(at: destURL)
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
            let kept = scanDir.appendingPathComponent("\(scanId.uuidString)_photos")
            try fileManager.copyItem(at: photosFolder, to: kept)
            scan.captureFolderName = kept.lastPathComponent
            let poses = PoseFile.url(forPhotoFolder: photosFolder)
            if fileManager.fileExists(atPath: poses.path) {
                try fileManager.copyItem(at: poses, to: PoseFile.url(forPhotoFolder: kept))
            }
        }

        try addScan(scan, to: project)
        return scan
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

    private func measurementsURL(for scan: Scan, in project: Project) -> URL {
        let base = (scan.fileName as NSString).deletingPathExtension
        return scansDirectory.appendingPathComponent(project.id.uuidString)
            .appendingPathComponent("\(base)_measurements.json")
    }

    func loadMeasurements(for scan: Scan, in project: Project) -> [ScanMeasurement] {
        let url = measurementsURL(for: scan, in: project)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do { return try JSONDecoder().decode([ScanMeasurement].self, from: Data(contentsOf: url)) }
        catch { report(error, action: "Read measurements. The original file has been preserved"); return [] }
    }

    func saveMeasurements(_ measurements: [ScanMeasurement], for scan: Scan, in project: Project) throws {
        try onMain {
            guard !isLibraryReadOnly else { throw StorageFailure.readOnly }
            guard let current = projects.first(where: { $0.id == project.id })?.scans.first(where: { $0.id == scan.id }),
                  current.fileName == scan.fileName else { throw StorageFailure.missingItem }
            let url = measurementsURL(for: scan, in: project)
            if fileManager.fileExists(atPath: url.path) {
                // A failed load must not turn into silently overwriting a corrupt file.
                _ = try JSONDecoder().decode([ScanMeasurement].self, from: Data(contentsOf: url))
            }
            try JSONEncoder().encode(measurements).write(to: url, options: .atomic)
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
        guard let name = scan.splatBundleName else { return nil }
        let url = scansDirectory.appendingPathComponent(project.id.uuidString).appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// URL of the kept source-photos folder for a High-Quality scan, if present.
    func captureFolderURL(for scan: Scan, in project: Project) -> URL? {
        guard let name = scan.captureFolderName else { return nil }
        let url = scansDirectory.appendingPathComponent(project.id.uuidString).appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Publish a new model only after it is copied. The old model, measurements,
    /// and metadata stay with the scan as recovery files, including across moves.
    func replacePhotogrammetryModel(scanID: UUID, in project: Project,
                                    newModelURL: URL, modelTransform: simd_float4x4?, provenance: CoordinateProvenance? = nil) throws {
        try onMain {
            guard let pi = projects.firstIndex(where: { $0.id == project.id }),
                  let si = projects[pi].scans.firstIndex(where: { $0.id == scanID }) else { throw StorageFailure.missingItem }
            let original = projects[pi].scans[si]
            let dir = scansDirectory.appendingPathComponent(project.id.uuidString)
            let base = UUID().uuidString
            let dest = dir.appendingPathComponent("\(base).usdz")
            let metadata = dir.appendingPathComponent("\(base)_previous.json")
            try persistence.copyAndCommit([(newModelURL, dest)]) {
                var updated = original
                updated.fileName = dest.lastPathComponent
                updated.fileSize = (try fileManager.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
                updated.modelScale = nil
                updated.modelTransform = modelTransform.map(StorageManager.array(of:))
                updated.coordinateProvenance = provenance
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
    func savePointCloud(meshData: MeshData, name: String, toProject project: Project, splatBundle: URL? = nil) throws -> Scan {
        let scanId = UUID()
        let fileName = "\(scanId.uuidString).ply"
        let scanDir = scansDirectory.appendingPathComponent(project.id.uuidString)
        try fileManager.createDirectory(at: scanDir, withIntermediateDirectories: true)

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

        // Native point-cloud scene for fast in-app viewing
        let scnURL = scanDir.appendingPathComponent("\(scanId.uuidString).scn")
        let node = MeshProcessor.createPointCloudNode(from: meshData)
        let scene = SCNScene()
        scene.rootNode.addChildNode(node)
        scene.write(to: scnURL, delegate: nil)

        scan.thumbnailData = generateThumbnail(fromModelURL: scnURL)

        if let bundle = splatBundle {
            let destination = scanDir.appendingPathComponent("\(scanId.uuidString)_bundle.zip")
            try fileManager.copyItem(at: bundle, to: destination)
            scan.splatBundleName = destination.lastPathComponent
        }
        try addScan(scan, to: project)
        return scan
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
    private func companionFiles(of scan: Scan) -> [String] {
        let base = (scan.fileName as NSString).deletingPathExtension
        var names = [scan.fileName, "\(base).mtl", "\(base).scn", "\(base)_measurements.json"]
        if let t = scan.textureFileName { names.append(t) }
        if let z = scan.splatBundleName { names.append(z) }
        if let p = scan.captureFolderName { names.append(p); names.append(p + PoseFile.suffix) }
        names += scan.retainedReconstructionFiles ?? []
        return Array(Set(names)).sorted()
    }

    func deleteScan(_ scan: Scan, from project: Project) {
        perform("Delete scan") {
            var candidate = projects
            guard let index = candidate.firstIndex(where: { $0.id == project.id }),
                  let current = candidate[index].scans.first(where: { $0.id == scan.id }) else { throw StorageFailure.missingItem }
            candidate[index].scans.removeAll { $0.id == scan.id }
            candidate[index].modifiedAt = Date()
            try commitProjects(candidate)
            let dir = scansDirectory.appendingPathComponent(project.id.uuidString)
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
            let sourceDir = scansDirectory.appendingPathComponent(sourceProject.id.uuidString)
            let destDir = scansDirectory.appendingPathComponent(destProject.id.uuidString)
            // The primary model and all explicitly registered companions are required.
            let required = [current.fileName] + [current.textureFileName, current.splatBundleName, current.captureFolderName].compactMap { $0 }
                + (current.retainedReconstructionFiles ?? [])
            guard required.allSatisfy({ fileManager.fileExists(atPath: sourceDir.appendingPathComponent($0).path) }) else {
                throw StorageFailure.missingItem
            }
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
            let files = companionFiles(of: current).filter { fileManager.fileExists(atPath: sourceDir.appendingPathComponent($0).path) }
            let copies = files.map { (source: sourceDir.appendingPathComponent($0), destination: destDir.appendingPathComponent($0)) }
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
        let sourceDir = scansDirectory.appendingPathComponent(sourceProject.id.uuidString)
        let destDir = scansDirectory.appendingPathComponent(destProject.id.uuidString)
        guard fileManager.fileExists(atPath: sourceDir.appendingPathComponent(scan.fileName).path) else { return nil }
        try? fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        let oldBase = (scan.fileName as NSString).deletingPathExtension
        let newBase = UUID().uuidString
        let copied: ModelCopy
        do {
            copied = try copyModel(of: scan, from: sourceDir, to: destDir, newBase: newBase)
        } catch {
            DebugLogger.shared.error("Error duplicating scan: \(error)", category: "Storage")
            return nil
        }
        // Extra files: internal viewer scene, splat bundle, kept photos.
        func copyExtra(_ name: String?, as newName: String) -> String? {
            guard let name = name else { return nil }
            let src = sourceDir.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: src.path) else { return nil }
            let dst = destDir.appendingPathComponent(newName)
            try? fileManager.removeItem(at: dst)
            return (try? fileManager.copyItem(at: src, to: dst)) != nil ? newName : nil
        }
        _ = copyExtra("\(oldBase).scn", as: "\(newBase).scn")
        _ = copyExtra("\(oldBase)_measurements.json", as: "\(newBase)_measurements.json")

        var newScan = Scan(
            name: "\(scan.name) (Copy)",
            fileName: copied.model.lastPathComponent,
            vertexCount: scan.vertexCount,
            faceCount: scan.faceCount,
            fileSize: scan.fileSize
        )
        newScan.hasTexture = scan.hasTexture
        newScan.hasColor = scan.hasColor
        newScan.boundingBoxMin = scan.boundingBoxMin
        newScan.boundingBoxMax = scan.boundingBoxMax
        newScan.thumbnailData = scan.thumbnailData
        newScan.notes = scan.notes
        newScan.modelScale = scan.modelScale
        newScan.textureFileName = copied.textureName
        newScan.splatBundleName = copyExtra(scan.splatBundleName, as: "\(newBase)_bundle.zip")
        newScan.captureFolderName = copyExtra(scan.captureFolderName, as: "\(newBase)_photos")
        _ = copyExtra(scan.captureFolderName.map { $0 + PoseFile.suffix }, as: "\(newBase)_photos" + PoseFile.suffix)
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

        do { try addScan(newScan, to: destProject); return newScan }
        catch { report(error, action: "Duplicate scan"); return nil }
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
        let oldBase = (scan.fileName as NSString).deletingPathExtension
        let ext = (scan.fileName as NSString).pathExtension
        let src = srcDir.appendingPathComponent(scan.fileName)
        let dst = dstDir.appendingPathComponent("\(newBase).\(ext)")
        try? fileManager.removeItem(at: dst)

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
                try? fileManager.removeItem(at: texDst)
                try fileManager.copyItem(at: texSrc, to: texDst)
                newTexture = name
                files.append(texDst)
            }
        }

        let mtlSrc = srcDir.appendingPathComponent("\(oldBase).mtl")
        if var mtl = try? String(contentsOf: mtlSrc, encoding: .utf8) {
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
    }

    private func exportBaseName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .replacingOccurrences(of: " ", with: "_")
        return cleaned.isEmpty ? "Scan" : cleaned
    }

    // MARK: - Import

    func importOBJFile(from sourceURL: URL, name: String, toProject project: Project) throws -> Scan {
        let scanId = UUID()
        let fileExtension = sourceURL.pathExtension.lowercased()
        let fileName = "\(scanId.uuidString).\(fileExtension)"
        let scanDir = scansDirectory.appendingPathComponent(project.id.uuidString)
        try fileManager.createDirectory(at: scanDir, withIntermediateDirectories: true)

        let destURL = scanDir.appendingPathComponent(fileName)

        // Start accessing security-scoped resource
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let newBase = scanId.uuidString
        if fileExtension == "obj" {
            // Point the copy at its renamed .mtl
            try copyPatchingHeader(from: sourceURL, to: destURL,
                                   replacing: "\(baseName).mtl", with: "\(newBase).mtl")
        } else {
            try fileManager.copyItem(at: sourceURL, to: destURL)
        }

        // Texture next to the model (our own "_texture" naming)
        let sourceDir = sourceURL.deletingLastPathComponent()
        var textureName: String?
        for suffix in ["_texture.jpg", "_texture.png"] {
            let texSourceURL = sourceDir.appendingPathComponent("\(baseName)\(suffix)")
            if fileManager.fileExists(atPath: texSourceURL.path) {
                let name = "\(newBase)\(suffix)"
                if (try? fileManager.copyItem(at: texSourceURL, to: scanDir.appendingPathComponent(name))) != nil {
                    textureName = name
                }
                break
            }
        }

        // Material file, with its texture reference renamed to match
        let mtlSourceURL = sourceURL.deletingPathExtension().appendingPathExtension("mtl")
        if var mtl = try? String(contentsOf: mtlSourceURL, encoding: .utf8) {
            mtl = mtl.replacingOccurrences(of: "\(baseName)_texture", with: "\(newBase)_texture")
            try? mtl.write(to: scanDir.appendingPathComponent("\(newBase).mtl"), atomically: true, encoding: .utf8)
        }

        let fileSize = (try? fileManager.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0

        var scan = Scan(
            name: name,
            fileName: fileName,
            fileSize: fileSize
        )
        scan.textureFileName = textureName
        scan.hasTexture = textureName != nil
        scan.coordinateProvenance = CoordinateProvenance(sourceKind: "imported", scaleStatus: .unknown,
            alignmentMethod: "none", localDatum: "Unknown source origin and units; calibration required")

        try addScan(scan, to: project)
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
                    try validateExportCompanions(scan, directory: sourceDirectory)
                    model = try copyModel(of: scan, from: sourceDirectory, to: folder, newBase: base).model
                }
            case .zUpOBJ:
                if ext == "obj", transform == CoordinateMath.identity {
                    try validateExportCompanions(scan, directory: sourceDirectory)
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
            let factor: Double = kind == .stl ? 1000 : 1
            let convention = kind == .native ? CoordinateMath.identity :
                [factor, 0, 0, 0, 0, 0, factor, 0, 0, -factor, 0, 0, 0, 0, 0, 1]
            let manifest = ModelExportManifest(scanID: scan.id, sourceRevision: scan.fileName, sourceSHA256: sourceHash,
                exportedAt: Date(), modelFile: model.lastPathComponent,
                units: scan.hasKnownScale ? (kind == .stl ? "millimetres" : "metres") : "source units — scale unverified",
                axes: kind == .native ? (scan.hasKnownScale ? "right-handed Y up" : "source convention unverified") : "right-handed Z up; X'=X, Y'=-Z, Z'=Y",
                sourceModelToLocal: transform, localToExport: convention, provenance: scan.coordinateProvenance, limitations: limitations)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
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
        if (scan.fileName as NSString).pathExtension.lowercased() == "obj" {
            let expected = (scan.fileName as NSString).deletingPathExtension + ".mtl"
            try ExportText.lines(directory.appendingPathComponent(scan.fileName)) { line in
                try exportCancellation.check()
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                if parts.first == "mtllib" {
                    guard parts.count == 2, String(parts[1]) == expected,
                          fileManager.fileExists(atPath: directory.appendingPathComponent(expected).path) else {
                        throw CoordinateError.incompleteExport
                    }
                    // Arbitrary imported material packaging is not implemented:
                    // reject unsupported maps instead of sharing a broken package.
                    try ExportText.lines(directory.appendingPathComponent(expected)) { material in
                        let fields = material.split(whereSeparator: { $0.isWhitespace })
                        if let keyword = fields.first, keyword.hasPrefix("map_") || ["bump", "disp", "decal", "refl"].contains(String(keyword)) {
                            guard fields.count == 2, String(fields[1]) == scan.textureFileName,
                                  fileManager.fileExists(atPath: directory.appendingPathComponent(String(fields[1])).path) else {
                                throw CoordinateError.incompleteExport
                            }
                        }
                    }
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
        var header = Data("ScanView 3D — millimetres, Z up".utf8); header.count = 80
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
        try handle.write(contentsOf: Data("# ScanView 3D export - metres, Z up\n".utf8))
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
