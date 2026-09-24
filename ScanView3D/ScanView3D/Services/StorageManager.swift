import Foundation
import SceneKit

/// Manages persistent storage for projects and scan files
class StorageManager: ObservableObject {
    @Published var projects: [Project] = []

    private let fileManager = FileManager.default
    private let projectsFileName = "projects.json"

    // MARK: - Directories

    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
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

    init() {
        createDirectoriesIfNeeded()
        loadProjects()
    }

    private func createDirectoriesIfNeeded() {
        try? fileManager.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: scansDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Threading

    /// `projects` drives SwiftUI, so it may only change on the main thread.
    /// Saving runs on background queues and hops here for the bookkeeping.
    private func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    private func addScan(_ scan: Scan, to project: Project) {
        onMain {
            if let index = projects.firstIndex(where: { $0.id == project.id }) {
                projects[index].addScan(scan)
                if scan.thumbnailData != nil {
                    projects[index].thumbnailData = scan.thumbnailData
                }
                saveProjects()
            }
        }
    }

    // MARK: - Project CRUD

    func loadProjects() {
        guard fileManager.fileExists(atPath: projectsFile.path) else {
            projects = []
            return
        }

        do {
            let data = try Data(contentsOf: projectsFile)
            projects = try JSONDecoder().decode([Project].self, from: data)
        } catch {
            DebugLogger.shared.error("Error loading projects: \(error)", category: "Storage")
            projects = []
        }
    }

    func saveProjects() {
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: projectsFile, options: .atomicWrite)
        } catch {
            DebugLogger.shared.error("Error saving projects: \(error)", category: "Storage")
        }
    }

    @discardableResult
    func createProject(name: String) -> Project {
        let project = Project(name: name)
        projects.append(project)

        // Create project directory
        let projectDir = projectsDirectory.appendingPathComponent(project.id.uuidString)
        try? fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // Create scan directory for this project
        let scanDir = scansDirectory.appendingPathComponent(project.id.uuidString)
        try? fileManager.createDirectory(at: scanDir, withIntermediateDirectories: true)

        saveProjects()
        return project
    }

    func updateProject(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
            saveProjects()
        }
    }

    func deleteProject(_ project: Project) {
        // Delete project files
        let projectDir = projectsDirectory.appendingPathComponent(project.id.uuidString)
        try? fileManager.removeItem(at: projectDir)

        // Delete associated scan files
        let scanDir = scansDirectory.appendingPathComponent(project.id.uuidString)
        try? fileManager.removeItem(at: scanDir)

        projects.removeAll { $0.id == project.id }
        saveProjects()
    }

    func renameProject(_ project: Project, newName: String) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].name = newName
            projects[index].modifiedAt = Date()
            saveProjects()
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
                    textureAtlas: nil,
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

        addScan(scan, to: project)
        return scan
    }

    func getScanFileURL(scan: Scan, project: Project) -> URL {
        return scansDirectory
            .appendingPathComponent(project.id.uuidString)
            .appendingPathComponent(scan.fileName)
    }

    /// Register a scan from an already-produced model file (e.g. a photogrammetry USDZ).
    /// - modelScale: uniform metric scale correction (photogrammetry has no real-world
    ///   scale; we derive this from the LiDAR mesh captured in the same session).
    /// - photosFolder: source photos to keep with the scan for later re-reconstruction.
    func importProcessedModel(modelURL: URL, name: String, toProject project: Project,
                              modelScale: Float? = nil, photosFolder: URL? = nil) throws -> Scan {
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
        scan.modelScale = modelScale
        scan.thumbnailData = generateThumbnail(fromModelURL: destURL)

        // Record true (scaled) dimensions so the info panel reads metric.
        if let scene = try? SCNScene(url: destURL, options: [.checkConsistency: false]) {
            let (mn, mx) = scene.rootNode.flattenedClone().boundingBox
            let s = modelScale ?? 1.0
            scan.boundingBoxMin = SIMD3<Float>(Float(mn.x) * s, Float(mn.y) * s, Float(mn.z) * s)
            scan.boundingBoxMax = SIMD3<Float>(Float(mx.x) * s, Float(mx.y) * s, Float(mx.z) * s)
        }

        // Keep the source photos so the user can re-reconstruct at higher effort later.
        if let photosFolder = photosFolder {
            let kept = scanDir.appendingPathComponent("\(scanId.uuidString)_photos")
            try? fileManager.removeItem(at: kept)
            if (try? fileManager.copyItem(at: photosFolder, to: kept)) != nil {
                scan.captureFolderName = kept.lastPathComponent
            }
        }

        addScan(scan, to: project)
        return scan
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

    /// Copy a prepared Splat zip next to the scan so it can be re-shared anytime.
    func attachSplatBundle(zipURL: URL, toScan scanID: UUID, in project: Project) {
        let scanDir = scansDirectory.appendingPathComponent(project.id.uuidString)
        try? fileManager.createDirectory(at: scanDir, withIntermediateDirectories: true)
        let dest = scanDir.appendingPathComponent("\(scanID.uuidString)_bundle.zip")
        try? fileManager.removeItem(at: dest)
        guard (try? fileManager.copyItem(at: zipURL, to: dest)) != nil else { return }
        onMain {
            if let pi = projects.firstIndex(where: { $0.id == project.id }),
               let si = projects[pi].scans.firstIndex(where: { $0.id == scanID }) {
                projects[pi].scans[si].splatBundleName = dest.lastPathComponent
                saveProjects()
            }
        }
    }

    /// Replace a photogrammetry scan's model file in place (used by re-reconstruct).
    func replacePhotogrammetryModel(scanID: UUID, in project: Project,
                                    newModelURL: URL, modelScale: Float?) throws {
        guard let fileName = onMain({
            projects.first(where: { $0.id == project.id })?.scans.first(where: { $0.id == scanID })?.fileName
        }) else { return }
        let scanDir = scansDirectory.appendingPathComponent(project.id.uuidString)
        let destURL = scanDir.appendingPathComponent(fileName)
        try? fileManager.removeItem(at: destURL)
        try fileManager.copyItem(at: newModelURL, to: destURL)

        let fileSize = (try? fileManager.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
        let thumbnail = generateThumbnail(fromModelURL: destURL)
        var bounds: (SIMD3<Float>, SIMD3<Float>)?
        if let scene = try? SCNScene(url: destURL, options: [.checkConsistency: false]) {
            let (mn, mx) = scene.rootNode.flattenedClone().boundingBox
            let s = modelScale ?? 1.0
            bounds = (SIMD3<Float>(Float(mn.x), Float(mn.y), Float(mn.z)) * s,
                      SIMD3<Float>(Float(mx.x), Float(mx.y), Float(mx.z)) * s)
        }

        onMain {
            guard let pi = projects.firstIndex(where: { $0.id == project.id }),
                  let si = projects[pi].scans.firstIndex(where: { $0.id == scanID }) else { return }
            projects[pi].scans[si].fileSize = fileSize
            projects[pi].scans[si].modelScale = modelScale
            projects[pi].scans[si].thumbnailData = thumbnail
            if let b = bounds {
                projects[pi].scans[si].boundingBoxMin = b.0
                projects[pi].scans[si].boundingBoxMax = b.1
            }
            saveProjects()
        }
    }

    /// Save a colored point cloud (Path C foundation): binary PLY + point-cloud .scn for viewing.
    func savePointCloud(meshData: MeshData, name: String, toProject project: Project) throws -> Scan {
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

        addScan(scan, to: project)
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
        var names = [scan.fileName, "\(base).mtl", "\(base).scn"]
        if let t = scan.textureFileName { names.append(t) }
        if let z = scan.splatBundleName { names.append(z) }
        if let p = scan.captureFolderName { names.append(p) }
        return Array(Set(names))
    }

    func deleteScan(_ scan: Scan, from project: Project) {
        let dir = scansDirectory.appendingPathComponent(project.id.uuidString)
        for name in companionFiles(of: scan) {
            try? fileManager.removeItem(at: dir.appendingPathComponent(name))
        }
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].scans.removeAll { $0.id == scan.id }
            projects[index].modifiedAt = Date()
            saveProjects()
        }
    }

    func renameScan(_ scan: Scan, in project: Project, newName: String) {
        if let projIndex = projects.firstIndex(where: { $0.id == project.id }),
           let scanIndex = projects[projIndex].scans.firstIndex(where: { $0.id == scan.id }) {
            projects[projIndex].scans[scanIndex].name = newName
            projects[projIndex].modifiedAt = Date()
            saveProjects()
        }
    }

    /// Move a scan (and all its files) from one project to another
    func moveScan(_ scan: Scan, from sourceProject: Project, to destProject: Project) {
        guard sourceProject.id != destProject.id else { return }
        let sourceDir = scansDirectory.appendingPathComponent(sourceProject.id.uuidString)
        let destDir = scansDirectory.appendingPathComponent(destProject.id.uuidString)
        try? fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        for name in companionFiles(of: scan) {
            let src = sourceDir.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            let dst = destDir.appendingPathComponent(name)
            try? fileManager.removeItem(at: dst)
            if (try? fileManager.moveItem(at: src, to: dst)) == nil {
                try? fileManager.copyItem(at: src, to: dst)
                try? fileManager.removeItem(at: src)
            }
        }

        if let srcIndex = projects.firstIndex(where: { $0.id == sourceProject.id }) {
            projects[srcIndex].scans.removeAll { $0.id == scan.id }
            projects[srcIndex].modifiedAt = Date()
        }
        if let dstIndex = projects.firstIndex(where: { $0.id == destProject.id }) {
            projects[dstIndex].addScan(scan)
        }
        saveProjects()
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

        if let dstIndex = projects.firstIndex(where: { $0.id == destProject.id }) {
            projects[dstIndex].addScan(newScan)
            saveProjects()
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

        addScan(scan, to: project)
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
