import SwiftUI

/// Detailed view of a project showing all its scans
struct ProjectDetailView: View {
    let project: Project
    @EnvironmentObject var storageManager: StorageManager
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showingImporter = false
    @State private var renamingScan: Scan?
    @State private var renameName = ""
    @State private var movingScan: Scan?
    @State private var sortOrder: SortOrder = .dateNewest
    @State private var scansToDelete: [Scan] = []

    enum SortOrder: String, CaseIterable {
        case dateNewest = "Newest First"
        case dateOldest = "Oldest First"
        case nameAZ = "Name A-Z"
        case nameZA = "Name Z-A"
        case sizeLargest = "Largest First"
    }

    // Get the live project from storage manager
    private var liveProject: Project {
        storageManager.projects.first { $0.id == project.id } ?? project
    }

    private var sortedScans: [Scan] {
        switch sortOrder {
        case .dateNewest:
            return liveProject.scans.sorted { $0.createdAt > $1.createdAt }
        case .dateOldest:
            return liveProject.scans.sorted { $0.createdAt < $1.createdAt }
        case .nameAZ:
            return liveProject.scans.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameZA:
            return liveProject.scans.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .sizeLargest:
            return liveProject.scans.sorted { $0.fileSize > $1.fileSize }
        }
    }

    var body: some View {
        Group {
            if liveProject.scans.isEmpty {
                emptyState
            } else {
                scanList
            }
        }
        .navigationTitle(liveProject.name)
        .navigationBarTitleDisplayMode(.inline)
        .fieldScreen()
        .overlay { ExportProgressView(store: storageManager) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import OBJ or PLY", systemImage: "square.and.arrow.down")
                    }

                    if !liveProject.scans.isEmpty {
                        Divider()

                        Menu("Sort By") {
                            ForEach(SortOrder.allCases, id: \.self) { order in
                                Button {
                                    sortOrder = order
                                } label: {
                                    HStack {
                                        Text(order.rawValue)
                                        if sortOrder == order {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }

                        Divider()

                        Button {
                            exportEntireProject()
                        } label: {
                            Label("Export All Scans", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Project actions and sorting")
            }
        }
        .alert("Rename Scan", isPresented: Binding(
            get: { renamingScan != nil },
            set: { if !$0 { renamingScan = nil } }
        )) {
            TextField("Scan name", text: $renameName)
            Button("Rename") {
                if let scan = renamingScan, !renameName.isEmpty {
                    storageManager.renameScan(scan, in: liveProject, newName: renameName)
                    renamingScan = nil
                    renameName = ""
                }
            }
            Button("Cancel", role: .cancel) {
                renamingScan = nil
                renameName = ""
            }
        }
        .sheet(isPresented: Binding(
            get: { movingScan != nil },
            set: { if !$0 { movingScan = nil } }
        )) {
            if let scan = movingScan {
                MoveToProjectSheet(
                    scan: scan,
                    sourceProject: liveProject,
                    storageManager: storageManager,
                    onDismiss: { movingScan = nil }
                )
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.init(filenameExtension: "obj")!, .init(filenameExtension: "ply")!],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .confirmationDialog("Delete \(scansToDelete.count) scan(s)?", isPresented: Binding(
            get: { !scansToDelete.isEmpty }, set: { if !$0 { scansToDelete = [] } }
        ), titleVisibility: .visible) {
            Button("Delete Scans", role: .destructive) {
                for scan in scansToDelete { storageManager.deleteScan(scan, from: liveProject) }
                scansToDelete = []
            }
        } message: { Text("This permanently removes the selected scan files. This cannot be undone.") }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 20) {
                FieldEmptyState(icon: "viewfinder", title: "Ready for your first scan",
                                message: "Open Scan to capture a room, object or terrain. Choose this project when saving, or bring in an existing model below.")
                Button { showingImporter = true } label: {
                    Label("Import OBJ or PLY", systemImage: "square.and.arrow.down")
                }.buttonStyle(FieldButtonStyle(prominent: true))
            }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
    }

    // MARK: - Scan List

    private var scanList: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    if typeSize.isAccessibilitySize {
                        Text("Project overview")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(FieldStyle.accent)
                        Text("\(liveProject.scanCount) capture\(liveProject.scanCount == 1 ? "" : "s") · \(liveProject.formattedTotalSize) in model files")
                            .font(.subheadline).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label("Project overview", systemImage: "folder")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(FieldStyle.accent)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2), alignment: .leading, spacing: 16) {
                            StatItem(label: "Captures", value: "\(liveProject.scanCount)")
                            StatItem(label: "Model files", value: liveProject.formattedTotalSize)
                        }
                    }
                    Divider().overlay(FieldStyle.line)
                    Text("\(formatCompact(liveProject.totalVertices)) vertices · \(formatCompact(liveProject.totalFaces)) faces")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20).fieldCard()
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }.listRowSeparator(.hidden)

            Section {
                ForEach(sortedScans) { scan in
                    NavigationLink(destination: ModelViewerView(scan: scan, project: liveProject)) {
                        ScanRow(scan: scan)
                    }
                    .contextMenu {
                        Button {
                            renameName = scan.name
                            renamingScan = scan
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }

                        if storageManager.projects.count > 1 {
                            Button {
                                movingScan = scan
                            } label: {
                                Label("Move to Project...", systemImage: "folder")
                            }

                        }

                        Button {
                            let _ = storageManager.duplicateScan(scan, from: liveProject, to: liveProject)
                        } label: { Label("Duplicate", systemImage: "plus.square.on.square") }

                        Button {
                            shareScan(scan)
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        Button(role: .destructive) {
                            scansToDelete = [scan]
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete { indexSet in
                    scansToDelete = indexSet.map { sortedScans[$0] }
                }
            } header: {
                Group {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) { Text("Captures"); sortMenu }
                    } else {
                        HStack { Text("Captures"); Spacer(); sortMenu }
                    }
                }
                .textCase(nil)
            }
            .listRowBackground(FieldStyle.surface)
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 8)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort scans", selection: $sortOrder) {
                ForEach(SortOrder.allCases, id: \.self) { order in Text(order.rawValue).tag(order) }
            }
        } label: {
            Label(sortOrder.rawValue, systemImage: "arrow.up.arrow.down")
                .font(.caption.weight(.medium)).foregroundStyle(FieldStyle.accent)
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Sort scans")
        .accessibilityValue(sortOrder.rawValue)
    }

    // MARK: - Actions

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            storageManager.importFiles(urls, to: liveProject)
        case .failure(let error):
            DebugLogger.shared.error("File picker error: \(error)", category: "Import")
        }
    }

    private func shareScan(_ scan: Scan) {
        let project = liveProject, store = storageManager
        store.prepareExport({ try store.exportScan(scan, from: project) }) { ShareSheetPresenter.present([$0]) }
    }

    private func exportEntireProject() {
        let project = liveProject, store = storageManager
        store.prepareExport({ try store.exportProject(project) }) { ShareSheetPresenter.present([$0]) }
    }

    private func formatCompact(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

// MARK: - Scan Row

struct ScanRow: View {
    let scan: Scan
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if !typeSize.isAccessibilitySize {
                FieldThumbnail(data: scan.thumbnailData, icon: ScanLibraryKind.icon(for: scan))
                    .frame(width: 70, height: 82)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(scan.name)
                    .font(.headline)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .foregroundStyle(.primary)
                Text("\(ScanLibraryKind.title(for: scan)) · \(scan.formattedFileSize)")
                    .font(.caption.weight(.medium)).foregroundStyle(FieldStyle.accent)
                    .fixedSize(horizontal: false, vertical: true)
                if !scan.hasKnownScale {
                    Label("Scale unverified", systemImage: "ruler")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let dims = scan.shortDimensions {
                    Text(dims).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if scan.vertexCount > 0 {
                    Text(formatCompactInline(scan.vertexCount) + (scan.faceCount > 0 ? " vertices · \(formatCompactInline(scan.faceCount)) faces" : " points"))
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func formatCompactInline(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.0fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

/// Presentation-only labels; a scan's stored capture and coordinate metadata
/// remain authoritative. A PLY containing faces is a mesh, not a point cloud.
enum ScanLibraryKind {
    static func title(for scan: Scan) -> String {
        if scan.terrainCapture != nil { return "Terrain" }
        if scan.splatBundleName != nil { return "Splat source" }
        if scan.faceCount == 0, (scan.fileName as NSString).pathExtension.lowercased() == "ply" { return "Point cloud" }
        if scan.hasTexture { return "Textured mesh" }
        return scan.faceCount > 0 ? "Mesh" : "3D model"
    }
    static func icon(for scan: Scan) -> String {
        if scan.terrainCapture != nil { return "mountain.2" }
        if scan.faceCount == 0, (scan.fileName as NSString).pathExtension.lowercased() == "ply" { return "circle.grid.3x3" }
        return "cube.transparent"
    }
}

// MARK: - Stat Item

struct StatItem: View {
    let label: String
    let value: String
    var icon: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !icon.isEmpty {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundColor(.accentColor)
            }
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Move to Project Sheet

struct MoveToProjectSheet: View {
    let scan: Scan
    let sourceProject: Project
    let storageManager: StorageManager
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Move \"\(scan.name)\" to:") {
                    ForEach(storageManager.projects.filter { $0.id != sourceProject.id }) { project in
                        Button {
                            if storageManager.moveScan(scan, from: sourceProject, to: project) {
                                onDismiss()
                            }
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.accentColor)
                                VStack(alignment: .leading) {
                                    Text(project.name)
                                        .foregroundColor(.primary)
                                    Text("\(project.scanCount) scan\(project.scanCount == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Move Scan")
            .fieldScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
        }
    }
}
