import Foundation

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
            print("Error loading projects: \(error)")
            projects = []
        }
    }

    func saveProjects() {
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: projectsFile, options: .atomicWrite)
        } catch {
            print("Error saving projects: \(error)")
        }
    }

    func createProject(name: String) -> Project {
        var project = Project(name: name)
        projects.append(project)

        // Create project directory
        let projectDir = projectsDirectory.appendingPathComponent(project.id.uuidString)
        try? fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)

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
        for scan in project.scans {
            deleteScanFile(scan)
        }

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

    func saveScan(meshData: MeshData, name: String, toProject project: Project) throws -> Scan {
        let scanId = UUID()
        let fileName = "\(scanId.uuidString).obj"
        let scanDir = scansDirectory.appendingPathComponent(project.id.uuidString)
        try fileManager.createDirectory(at: scanDir, withIntermediateDirectories: true)

        // Export as OBJ
        let fileURL = try OBJExporter.export(
            meshData: meshData,
            fileName: scanId.uuidString,
            directory: scanDir
        )

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

        // Add scan to project
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].addScan(scan)
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
            saveProjects()
        }
    }

    private func deleteScanFile(_ scan: Scan) {
        // Try to find and delete the scan file from any project directory
        if let enumerator = fileManager.enumerator(at: scansDirectory, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL {
                if url.lastPathComponent == scan.fileName {
                    try? fileManager.removeItem(at: url)
                    break
                }
            }
        }
    }

    // MARK: - Import

    func importOBJFile(from sourceURL: URL, name: String, toProject project: Project) throws -> Scan {
        let scanId = UUID()
        let fileName = "\(scanId.uuidString).obj"
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

        let exportName = "\(scan.name.replacingOccurrences(of: " ", with: "_")).obj"
        let exportURL = exportDir.appendingPathComponent(exportName)

        // Remove existing export if any
        try? fileManager.removeItem(at: exportURL)
        try? fileManager.copyItem(at: sourceURL, to: exportURL)

        return exportURL
    }
}
