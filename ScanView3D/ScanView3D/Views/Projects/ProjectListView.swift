import SwiftUI

/// Main project list view showing all scanning projects
struct ProjectListView: View {
    @EnvironmentObject var storageManager: StorageManager
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showingNewProject = false
    @State private var newProjectName = ""
    @State private var showingImporter = false
    @State private var editingProject: Project?
    @State private var renameName = ""
    @State private var importTargetProject: Project?
    @State private var searchText = ""
    @State private var projectsToDelete: [Project] = []

    private var sortedProjects: [Project] {
        storageManager.projects.sorted { $0.modifiedAt > $1.modifiedAt }.filter {
            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if storageManager.projects.isEmpty {
                    emptyState
                } else {
                    projectList
                }
            }
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.inline)
            .fieldScreen()
            .searchable(text: $searchText, prompt: "Find a project")
            .overlay { ExportProgressView(store: storageManager) }
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
                    .accessibilityLabel("Create or import")
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
            .confirmationDialog("Delete \(projectsToDelete.count) project(s)?", isPresented: Binding(
                get: { !projectsToDelete.isEmpty }, set: { if !$0 { projectsToDelete = [] } }
            ), titleVisibility: .visible) {
                Button("Delete Projects and Scans", role: .destructive) {
                    for project in projectsToDelete { storageManager.deleteProject(project) }
                    projectsToDelete = []
                }
            } message: { Text("This permanently removes their scan files. This cannot be undone.") }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 20) {
                libraryHero
                FieldEmptyState(icon: "folder.badge.plus", title: "A place for every capture",
                                message: "Group your scans by site, object, or room. Everything stays on this device.")
                VStack(spacing: 10) {
                    Button { showingNewProject = true } label: {
                        Label("Create your first project", systemImage: "plus")
                    }.buttonStyle(FieldButtonStyle(prominent: true))
                    Button { showingImporter = true } label: {
                        Label("Import OBJ or PLY", systemImage: "square.and.arrow.down")
                    }.buttonStyle(FieldButtonStyle())
                }
            }
            .padding(20).frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    private var libraryHero: some View {
        FieldHero(eyebrow: "Workspace", title: typeSize.isAccessibilitySize ? "Your projects" : "Your world.\nIn three dimensions.",
                  subtitle: "Capture, organize, and explore your spaces.", icon: "square.stack.3d.up")
    }

    // MARK: - Project List

    private var projectList: some View {
        List {
            Section {
                libraryHero.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                if typeSize.isAccessibilitySize {
                    Text("\(storageManager.projects.count) projects · \(storageManager.projects.reduce(0) { $0 + $1.scanCount }) scans · On device")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
                } else {
                HStack(spacing: 16) {
                    StatItem(label: "Projects", value: "\(storageManager.projects.count)", icon: "folder")
                    StatItem(label: "Scans", value: "\(storageManager.projects.reduce(0) { $0 + $1.scanCount })", icon: "cube")
                    StatItem(label: "Storage", value: "On device", icon: "iphone")
                }.padding(.vertical, 8)
                }
            }.listRowSeparator(.hidden)
            Section("Recently updated") {
            if sortedProjects.isEmpty {
                FieldEmptyState(icon: "magnifyingglass", title: "No matching projects", message: "Try another name or clear your search.")
            }
            ForEach(sortedProjects) { project in
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
                        projectsToDelete = [project]
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onDelete { indexSet in
                projectsToDelete = indexSet.map { sortedProjects[$0] }
            }
            }.listRowBackground(FieldStyle.surface)
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 8)
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
                guard let created = storageManager.createProject(name: "Imported Scans") else { return }
                project = created
            }

            for url in urls {
                let name = url.deletingPathExtension().lastPathComponent
                do {
                    let _ = try storageManager.importOBJFile(from: url, name: name, toProject: project)
                } catch {
                    storageManager.report(error, action: "Import \(name)")
                }
            }
            importTargetProject = nil

        case .failure(let error):
            DebugLogger.shared.error("File picker error: \(error)", category: "Import")
        }
    }

    private func exportProject(_ project: Project) {
        let store = storageManager
        store.prepareExport({ try store.exportProject(project) }) { ShareSheetPresenter.present([$0]) }
    }
}

// MARK: - Project Row

struct ProjectRow: View {
    let project: Project
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail or icon
            if !typeSize.isAccessibilitySize {
            FieldThumbnail(data: project.thumbnailData, icon: "square.stack.3d.up")
                .frame(width: 68, height: 76)
            }

            // Project info
            VStack(alignment: .leading, spacing: 7) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { projectMetadata }
                    VStack(alignment: .leading, spacing: 4) { projectMetadata }
                }

                Text(project.modifiedAt.relativeString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)

        }
        .padding(.vertical, 10)
    }

    @ViewBuilder private var projectMetadata: some View {
                    if typeSize.isAccessibilitySize {
                        Text("\(project.scanCount) scan\(project.scanCount == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                    Label("\(project.scanCount) scan\(project.scanCount == 1 ? "" : "s")", systemImage: "viewfinder")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }

                    if project.totalFileSize > 0 {
                        Text(project.formattedTotalSize)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
    }
}
