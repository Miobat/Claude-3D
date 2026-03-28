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

    func saveScan(meshData: MeshData, name: String, toProject project: Project, format: ExportFormat = .obj) throws -> Scan {
        let scanId = UUID()
        let fileExtension = format == .ply ? "ply" : "obj"
        let fileName = "\(scanId.uuidString).\(fileExtension)"
        let scanDir = scansDirectory.appendingPathComponent(project.id.uuidString)
        try fileManager.createDirectory(at: scanDir, withIntermediateDirectories: true)

        // Export based on format
        let fileURL: URL
        switch format {
        case .obj:
            fileURL = try OBJExporter.export(
                meshData: meshData,
                fileName: scanId.uuidString,
                directory: scanDir
            )
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
        scan.boundingBoxMin = meshData.boundingBoxMin
        scan.boundingBoxMax = meshData.boundingBoxMax

        // Generate thumbnail
        scan.thumbnailData = generateThumbnail(for: meshData)

        // Add scan to project
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].addScan(scan)

            // Update project thumbnail with latest scan
            if scan.thumbnailData != nil {
                projects[index].thumbnailData = scan.thumbnailData
            }

            saveProjects()
        }

        return scan
    }

    func getScanFileURL(scan: Scan, project: Project) -> URL {
        return scansDirectory
            .appendingPathComponent(project.id.uuidString)
            .appendingPathComponent(scan.fileName)
    }

    func deleteScan(_ scan: Scan, from project: Project) {
        let fileURL = getScanFileURL(scan: scan, project: project)
        try? fileManager.removeItem(at: fileURL)

        // Also delete MTL file if exists
        let mtlURL = fileURL.deletingPathExtension().appendingPathExtension("mtl")
        try? fileManager.removeItem(at: mtlURL)

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

    /// Move a scan from one project to another
    func moveScan(_ scan: Scan, from sourceProject: Project, to destProject: Project) {
        let sourceURL = getScanFileURL(scan: scan, project: sourceProject)
        let destDir = scansDirectory.appendingPathComponent(destProject.id.uuidString)
        try? fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destURL = destDir.appendingPathComponent(scan.fileName)

        // Move the file
        do {
            try fileManager.moveItem(at: sourceURL, to: destURL)

            // Move MTL too if exists
            let mtlSource = sourceURL.deletingPathExtension().appendingPathExtension("mtl")
            if fileManager.fileExists(atPath: mtlSource.path) {
                let mtlDest = destURL.deletingPathExtension().appendingPathExtension("mtl")
                try fileManager.moveItem(at: mtlSource, to: mtlDest)
            }
        } catch {
            // If move fails, try copy
            try? fileManager.copyItem(at: sourceURL, to: destURL)
            try? fileManager.removeItem(at: sourceURL)
        }

        // Update project metadata
        if let srcIndex = projects.firstIndex(where: { $0.id == sourceProject.id }) {
            projects[srcIndex].scans.removeAll { $0.id == scan.id }
            projects[srcIndex].modifiedAt = Date()
        }
        if let dstIndex = projects.firstIndex(where: { $0.id == destProject.id }) {
            projects[dstIndex].addScan(scan)
        }
        saveProjects()
    }

    /// Duplicate a scan within the same or different project
    func duplicateScan(_ scan: Scan, from sourceProject: Project, to destProject: Project) -> Scan? {
        let sourceURL = getScanFileURL(scan: scan, project: sourceProject)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }

        let newScanId = UUID()
        let fileExtension = (scan.fileName as NSString).pathExtension
        let newFileName = "\(newScanId.uuidString).\(fileExtension)"
        let destDir = scansDirectory.appendingPathComponent(destProject.id.uuidString)
        try? fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destURL = destDir.appendingPathComponent(newFileName)

        do {
            try fileManager.copyItem(at: sourceURL, to: destURL)

            // Copy MTL too
            let mtlSource = sourceURL.deletingPathExtension().appendingPathExtension("mtl")
            if fileManager.fileExists(atPath: mtlSource.path) {
                let mtlDest = destURL.deletingPathExtension().appendingPathExtension("mtl")
                try fileManager.copyItem(at: mtlSource, to: mtlDest)
            }

            var newScan = Scan(
                name: "\(scan.name) (Copy)",
                fileName: newFileName,
                vertexCount: scan.vertexCount,
                faceCount: scan.faceCount,
                fileSize: scan.fileSize
            )
            newScan.hasTexture = scan.hasTexture
            newScan.hasColor = scan.hasColor
            newScan.boundingBoxMin = scan.boundingBoxMin
            newScan.boundingBoxMax = scan.boundingBoxMax
            newScan.thumbnailData = scan.thumbnailData

            if let dstIndex = projects.firstIndex(where: { $0.id == destProject.id }) {
                projects[dstIndex].addScan(newScan)
                saveProjects()
            }

            return newScan
        } catch {
            DebugLogger.shared.error("Error duplicating scan: \(error)", category: "Storage")
            return nil
        }
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

        try fileManager.copyItem(at: sourceURL, to: destURL)

        // Also copy MTL file if it exists
        let mtlSourceURL = sourceURL.deletingPathExtension().appendingPathExtension("mtl")
        if fileManager.fileExists(atPath: mtlSourceURL.path) {
            let mtlDestURL = scanDir.appendingPathComponent("\(scanId.uuidString).mtl")
            try? fileManager.copyItem(at: mtlSourceURL, to: mtlDestURL)
        }

        let fileSize = (try? fileManager.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0

        let scan = Scan(
            name: name,
            fileName: fileName,
            fileSize: fileSize
        )

        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].addScan(scan)
            saveProjects()
        }

        return scan
    }

    // MARK: - Export / Share

    func exportScan(_ scan: Scan, from project: Project) -> URL? {
        let sourceURL = getScanFileURL(scan: scan, project: project)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }

        // Copy to a shareable location with a nice filename
        let exportDir = documentsDirectory.appendingPathComponent(AppConstants.exportDirectory)
        try? fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let sanitizedName = scan.name
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        let fileExtension = (scan.fileName as NSString).pathExtension
        let exportName = "\(sanitizedName).\(fileExtension)"
        let exportURL = exportDir.appendingPathComponent(exportName)

        // Remove existing export if any
        try? fileManager.removeItem(at: exportURL)
        try? fileManager.copyItem(at: sourceURL, to: exportURL)

        // Also copy MTL if OBJ
        if fileExtension == "obj" {
            let mtlSource = sourceURL.deletingPathExtension().appendingPathExtension("mtl")
            if fileManager.fileExists(atPath: mtlSource.path) {
                let mtlExport = exportDir.appendingPathComponent("\(sanitizedName).mtl")
                try? fileManager.removeItem(at: mtlExport)
                try? fileManager.copyItem(at: mtlSource, to: mtlExport)
            }
        }

        return exportURL
    }

    /// Export all scans from a project into a folder
    func exportProject(_ project: Project) -> URL? {
        let exportDir = documentsDirectory
            .appendingPathComponent(AppConstants.exportDirectory)
            .appendingPathComponent(project.name.replacingOccurrences(of: " ", with: "_"))
        try? fileManager.removeItem(at: exportDir)
        try? fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)

        for scan in project.scans {
            let sourceURL = getScanFileURL(scan: scan, project: project)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }

            let sanitizedName = scan.name
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "-")
            let ext = (scan.fileName as NSString).pathExtension
            let destURL = exportDir.appendingPathComponent("\(sanitizedName).\(ext)")
            try? fileManager.copyItem(at: sourceURL, to: destURL)

            // Copy MTL if exists
            let mtlSource = sourceURL.deletingPathExtension().appendingPathExtension("mtl")
            if fileManager.fileExists(atPath: mtlSource.path) {
                let mtlDest = exportDir.appendingPathComponent("\(sanitizedName).mtl")
                try? fileManager.copyItem(at: mtlSource, to: mtlDest)
            }
        }

        return exportDir
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
        scene.background?.contents = UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)

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
