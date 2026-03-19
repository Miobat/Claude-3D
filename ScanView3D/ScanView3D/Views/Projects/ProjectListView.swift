import SwiftUI

/// Main project list view showing all scanning projects
struct ProjectListView: View {
    @EnvironmentObject var storageManager: StorageManager
    @State private var showingNewProject = false
    @State private var newProjectName = ""
    @State private var showingImporter = false
    @State private var editingProject: Project?
    @State private var renameName = ""

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
                            showingImporter = true
                        } label: {
                            Label("Import OBJ File", systemImage: "square.and.arrow.down")
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
                allowedContentTypes: [.init(filenameExtension: "obj")!],
                allowsMultipleSelection: false
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

            Text("Create a project to organize your 3D scans,\nor import existing OBJ files.")
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
                    Label("Import OBJ File", systemImage: "square.and.arrow.down")
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
            ForEach(storageManager.projects) { project in
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

                    Button(role: .destructive) {
                        storageManager.deleteProject(project)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    storageManager.deleteProject(storageManager.projects[index])
                }
            }
        }
    }

    // MARK: - Import Handler

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Create a default project if none exist
            let project: Project
            if let first = storageManager.projects.first {
                project = first
            } else {
                project = storageManager.createProject(name: "Imported Scans")
            }

            let name = url.deletingPathExtension().lastPathComponent
            do {
                let _ = try storageManager.importOBJFile(from: url, name: name, toProject: project)
            } catch {
                print("Import error: \(error)")
            }

        case .failure(let error):
            print("File picker error: \(error)")
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
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: AppConstants.Layout.thumbnailSize, height: AppConstants.Layout.thumbnailSize)

                if let thumbnailData = project.thumbnailData,
                   let uiImage = UIImage(data: thumbnailData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: AppConstants.Layout.thumbnailSize, height: AppConstants.Layout.thumbnailSize)
                        .cornerRadius(8)
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

                    if project.totalVertices > 0 {
                        Label("\(project.totalVertices.formatted()) verts", systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Text(project.modifiedAt.relativeString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}
