import SwiftUI

/// Main project list view showing all scanning projects
struct ProjectListView: View {
    @EnvironmentObject var storageManager: StorageManager
    @State private var showingNewProject = false
    @State private var newProjectName = ""
    @State private var showingImporter = false
    @State private var editingProject: Project?
    @State private var renameName = ""
    @State private var importTargetProject: Project?

    var body: some View {
        NavigationView {
            Group {
                if storageManager.projects.isEmpty {
                    emptyState
                } else {
                    projectList
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingNewProject = true
                        } label: {
                            Label("New Project", systemImage: "folder.badge.plus")
                        }

                        Button {
                            importTargetProject = nil
                            showingImporter = true
                        } label: {
                            Label("Import File", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New Project", isPresented: $showingNewProject) {
                TextField("Project name", text: $newProjectName)
                Button("Create") {
                    if !newProjectName.isEmpty {
                        let _ = storageManager.createProject(name: newProjectName)
                        newProjectName = ""
                    }
                }
                Button("Cancel", role: .cancel) { newProjectName = "" }
            }
            .alert("Rename Project", isPresented: Binding(
                get: { editingProject != nil },
                set: { if !$0 { editingProject = nil } }
            )) {
                TextField("Project name", text: $renameName)
                Button("Rename") {
                    if let project = editingProject, !renameName.isEmpty {
                        storageManager.renameProject(project, newName: renameName)
                        editingProject = nil
                        renameName = ""
                    }
                }
                Button("Cancel", role: .cancel) {
                    editingProject = nil
                    renameName = ""
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.init(filenameExtension: "obj")!, .init(filenameExtension: "ply")!],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 60))
                .foregroundColor(.gray)

            Text("No Projects Yet")
                .font(.title2)
                .fontWeight(.bold)

            Text("Create a project to organize your 3D scans,\nor import existing OBJ/PLY files.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                Button {
                    showingNewProject = true
                } label: {
                    Label("Create Project", systemImage: "folder.badge.plus")
                        .frame(maxWidth: 250)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showingImporter = true
                } label: {
                    Label("Import File", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: 250)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
        .padding()
    }

    // MARK: - Project List

    private var projectList: some View {
        List {
            ForEach(storageManager.projects.sorted(by: { $0.modifiedAt > $1.modifiedAt })) { project in
                NavigationLink(destination: ProjectDetailView(project: project)) {
                    ProjectRow(project: project)
                }
                .contextMenu {
                    Button {
                        renameName = project.name
                        editingProject = project
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    Button {
                        importTargetProject = project
                        showingImporter = true
                    } label: {
                        Label("Import File Here", systemImage: "square.and.arrow.down")
                    }

                    if !project.scans.isEmpty {
                        Button {
                            exportProject(project)
                        } label: {
                            Label("Export All Scans", systemImage: "square.and.arrow.up")
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        storageManager.deleteProject(project)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onDelete { indexSet in
                let sorted = storageManager.projects.sorted(by: { $0.modifiedAt > $1.modifiedAt })
                for index in indexSet {
                    storageManager.deleteProject(sorted[index])
                }
            }
        }
    }

    // MARK: - Import Handler

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            // Use target project, first project, or create new one
            let project: Project
            if let target = importTargetProject {
                project = target
            } else if let first = storageManager.projects.sorted(by: { $0.modifiedAt > $1.modifiedAt }).first {
                project = first
            } else {
                project = storageManager.createProject(name: "Imported Scans")
            }

            for url in urls {
                let name = url.deletingPathExtension().lastPathComponent
                do {
                    let _ = try storageManager.importOBJFile(from: url, name: name, toProject: project)
                } catch {
                    DebugLogger.shared.error("Import error: \(error)", category: "Import")
                }
            }
            importTargetProject = nil

        case .failure(let error):
            DebugLogger.shared.error("File picker error: \(error)", category: "Import")
        }
    }

    private func exportProject(_ project: Project) {
        if let url = storageManager.exportProject(project) {
            let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                rootVC.present(activityVC, animated: true)
            }
        }
    }
}

// MARK: - Project Row

struct ProjectRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail or icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: AppConstants.Layout.thumbnailSize, height: AppConstants.Layout.thumbnailSize)

                if let thumbnailData = project.thumbnailData,
                   let uiImage = UIImage(data: thumbnailData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: AppConstants.Layout.thumbnailSize, height: AppConstants.Layout.thumbnailSize)
                        .cornerRadius(10)
                } else {
                    Image(systemName: "cube.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.accentColor)
                }
            }

            // Project info
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.headline)

                HStack(spacing: 8) {
                    Label("\(project.scanCount) scan\(project.scanCount == 1 ? "" : "s")", systemImage: "viewfinder")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if project.totalFileSize > 0 {
                        Text(project.formattedTotalSize)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Text(project.modifiedAt.relativeString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Scan count badge
            if project.scanCount > 0 {
                Text("\(project.scanCount)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor)
                    .clipShape(Circle())
            }
        }
        .padding(.vertical, 4)
    }
}
