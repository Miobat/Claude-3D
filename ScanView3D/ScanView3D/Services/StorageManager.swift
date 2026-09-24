import Foundation
import SceneKit

/// Manages persistent storage for projects and scan files
class StorageManager: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published var storageError: String?
    @Published private(set) var isLibraryReadOnly = false

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
                                    newModelURL: URL, modelTransform: simd_float4x4?) throws {
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

    /// Stream-copy a text file, replacing `old` with `new` in its first 64 KB
    /// (where OBJ `mtllib` lines live). Works for very large OBJ files.
    private func copyPatchingHeader(from src: URL, to dst: URL, replacing old: String, with new: String) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        guard fileManager.createFile(atPath: dst.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }

        let head = try input.read(upToCount: 65_536) ?? Data()
        if let text = String(data: head, encoding: .utf8) {
            try output.write(contentsOf: Data(text.replacingOccurrences(of: old, with: new).utf8))
        } else {
            try output.write(contentsOf: head)
        }
        while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
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

        try addScan(scan, to: project)
        return scan
    }

    // MARK: - Export / Share

    /// Prepare a scan for sharing under its display name. Returns a single URL:
    /// the model file itself, or — for a textured OBJ — a .zip containing the
    /// .obj, .mtl and texture so it opens correctly in other apps.
    func exportScan(_ scan: Scan, from project: Project) -> URL? {
        let srcDir = scansDirectory.appendingPathComponent(project.id.uuidString)
        guard fileManager.fileExists(atPath: srcDir.appendingPathComponent(scan.fileName).path) else { return nil }

        let shareRoot = documentsDirectory.appendingPathComponent(AppConstants.exportDirectory).appendingPathComponent("Share")
        try? fileManager.removeItem(at: shareRoot)   // previous shares are finished by now
        let base = exportBaseName(scan.name)
        let folder = shareRoot.appendingPathComponent(base)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = try copyModel(of: scan, from: srcDir, to: folder, newBase: base)
            if copy.allFiles.count == 1 { return copy.model }
            return StorageManager.zipFolder(folder, to: shareRoot.appendingPathComponent("\(base).zip"))
        } catch {
            DebugLogger.shared.error("Export failed: \(error)", category: "Export")
            return nil
        }
    }

    /// Export all scans from a project into one folder (textured OBJs complete).
    func exportProject(_ project: Project) -> URL? {
        let srcDir = scansDirectory.appendingPathComponent(project.id.uuidString)
        let exportDir = documentsDirectory
            .appendingPathComponent(AppConstants.exportDirectory)
            .appendingPathComponent(exportBaseName(project.name))
        try? fileManager.removeItem(at: exportDir)
        try? fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)

        var used = Set<String>()
        for scan in project.scans {
            var base = exportBaseName(scan.name)
            var n = 2
            while used.contains(base) { base = "\(exportBaseName(scan.name))_\(n)"; n += 1 }
            used.insert(base)
            _ = try? copyModel(of: scan, from: srcDir, to: exportDir, newBase: base)
        }
        return exportDir
    }

    // MARK: - CAD / 3D-print exports (Z up)

    /// OBJ with Z pointing up (the usual convention in CAD). Textured OBJ scans
    /// keep their texture (shared as a .zip); other models export their geometry.
    func exportZUpOBJ(_ scan: Scan, from project: Project) -> URL? {
        let srcDir = scansDirectory.appendingPathComponent(project.id.uuidString)
        let shareRoot = documentsDirectory.appendingPathComponent(AppConstants.exportDirectory).appendingPathComponent("Share")
        try? fileManager.removeItem(at: shareRoot)
        let base = exportBaseName(scan.name) + "_Zup"
        let folder = shareRoot.appendingPathComponent(base)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            if (scan.fileName as NSString).pathExtension.lowercased() == "obj" && scan.modelMatrix == nil {
                let copy = try copyModel(of: scan, from: srcDir, to: folder, newBase: base)
                try StorageManager.convertOBJToZUp(at: copy.model)
                if copy.allFiles.count == 1 { return copy.model }
                return StorageManager.zipFolder(folder, to: shareRoot.appendingPathComponent("\(base).zip"))
            }
            let triangles = worldTriangles(of: scan, in: project)
            guard !triangles.isEmpty else { return nil }
            let url = folder.appendingPathComponent("\(base).obj")
            try StorageManager.writeOBJ(triangles: triangles, to: url)
            return url
        } catch {
            DebugLogger.shared.error("Z-up OBJ export failed: \(error)", category: "Export")
            return nil
        }
    }

    /// Binary STL in millimetres with Z up (3D printing and most CAD tools).
    func exportSTL(_ scan: Scan, from project: Project) -> URL? {
        let triangles = worldTriangles(of: scan, in: project)
        guard !triangles.isEmpty else { return nil }
        let shareRoot = documentsDirectory.appendingPathComponent(AppConstants.exportDirectory).appendingPathComponent("Share")
        try? fileManager.removeItem(at: shareRoot)
        try? fileManager.createDirectory(at: shareRoot, withIntermediateDirectories: true)
        let url = shareRoot.appendingPathComponent(exportBaseName(scan.name) + "_mm.stl")

        let triCount = triangles.count / 3
        var data = Data(capacity: 84 + triCount * 50)
        var header = Data("ScanView 3D export - units: mm, Z up".utf8)
        header.count = 80
        data.append(header)
        var count = UInt32(triCount).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        func zUpMM(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3<Float>(v.x, -v.z, v.y) * 1000 }
        for t in 0..<triCount {
            let a = zUpMM(triangles[t * 3]), b = zUpMM(triangles[t * 3 + 1]), c = zUpMM(triangles[t * 3 + 2])
            var n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            n = len > 0 ? n / len : SIMD3<Float>(0, 0, 1)
            var floats: [Float] = [n.x, n.y, n.z, a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z]
            floats.withUnsafeBytes { data.append(contentsOf: $0) }
            data.append(contentsOf: [0, 0])   // attribute byte count
        }
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// All triangles of a scan in world space (with its real-world transform),
    /// flattened: every three points are one triangle.
    private func worldTriangles(of scan: Scan, in project: Project) -> [SIMD3<Float>] {
        let modelURL = getScanFileURL(scan: scan, project: project)
        let scnURL = modelURL.deletingPathExtension().appendingPathExtension("scn")
        let url = fileManager.fileExists(atPath: scnURL.path) ? scnURL : modelURL
        guard let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) else { return [] }
        let root = SCNNode()
        scene.rootNode.childNodes.forEach { root.addChildNode($0.clone()) }
        if let m = scan.modelMatrix { root.simdTransform = m }

        var result: [SIMD3<Float>] = []
        for source in ModelGeometryIndex.sources(in: root) {
            guard let vsrc = source.geometry.sources(for: .vertex).first, vsrc.usesFloatComponents,
                  vsrc.bytesPerComponent == 4, vsrc.componentsPerVector >= 3 else { continue }
            let m = source.transform
            var positions = [SIMD3<Float>](repeating: .zero, count: vsrc.vectorCount)
            vsrc.data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                for i in 0..<vsrc.vectorCount {
                    let f = base.advanced(by: vsrc.dataOffset + vsrc.dataStride * i).assumingMemoryBound(to: Float.self)
                    let w = m * SIMD4<Float>(f[0], f[1], f[2], 1)
                    positions[i] = SIMD3<Float>(w.x, w.y, w.z)
                }
            }
            for element in source.geometry.elements where element.primitiveType == .triangles {
                let bpi = element.bytesPerIndex
                element.data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    for i in 0..<(element.primitiveCount * 3) {
                        let p = base.advanced(by: i * bpi)
                        let index: Int
                        switch bpi {
                        case 1: index = Int(p.assumingMemoryBound(to: UInt8.self).pointee)
                        case 2: index = Int(p.assumingMemoryBound(to: UInt16.self).pointee)
                        default: index = Int(p.assumingMemoryBound(to: UInt32.self).pointee)
                        }
                        result.append(index < positions.count ? positions[index] : .zero)
                    }
                }
            }
        }
        return result
    }

    /// Rewrite an OBJ's vertex and normal lines from Y-up to Z-up.
    static func convertOBJToZUp(at url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var out = ""
        out.reserveCapacity(text.utf8.count + 1024)
        text.enumerateLines { line, _ in
            if line.hasPrefix("v ") || line.hasPrefix("vn ") {
                let parts = line.split(separator: " ")
                if parts.count >= 4, let x = Double(parts[1]), let y = Double(parts[2]), let z = Double(parts[3]) {
                    out += String(format: "%@ %.6f %.6f %.6f", String(parts[0]), x, -z, y)
                    for extra in parts.dropFirst(4) { out += " " + extra }
                    out += "\n"
                    return
                }
            }
            out += line + "\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Plain OBJ (geometry only, Z up) from world-space triangles.
    static func writeOBJ(triangles: [SIMD3<Float>], to url: URL) throws {
        var out = "# ScanView 3D export - metres, Z up\n"
        out.reserveCapacity(triangles.count * 40)
        for v in triangles { out += String(format: "v %.5f %.5f %.5f\n", v.x, -v.z, v.y) }
        for t in 0..<(triangles.count / 3) {
            out += "f \(t * 3 + 1) \(t * 3 + 2) \(t * 3 + 3)\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
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
