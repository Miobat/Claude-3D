import SwiftUI

/// Detailed view of a project showing all its scans
struct ProjectDetailView: View {
    let project: Project
    @EnvironmentObject var storageManager: StorageManager
    @State private var showingImporter = false
    @State private var renamingScan: Scan?
    @State private var renameName = ""
    @State private var movingScan: Scan?
    @State private var showingExportProject = false
    @State private var sortOrder: SortOrder = .dateNewest

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import OBJ File", systemImage: "square.and.arrow.down")
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
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "viewfinder")
                .font(.system(size: 50))
                .foregroundColor(.gray)

            Text("No Scans Yet")
                .font(.title3)
                .fontWeight(.bold)

            Text("Go to the Scanner tab to create a new scan,\nor import existing OBJ/PLY files.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showingImporter = true
            } label: {
                Label("Import File", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Scan List

    private var scanList: some View {
        List {
            // Project stats
            Section {
                HStack(spacing: 16) {
                    StatItem(label: "Scans", value: "\(liveProject.scanCount)", icon: "viewfinder")
                    StatItem(label: "Vertices", value: formatCompact(liveProject.totalVertices), icon: "circle.fill")
                    StatItem(label: "Faces", value: formatCompact(liveProject.totalFaces), icon: "triangle.fill")
                    StatItem(label: "Size", value: liveProject.formattedTotalSize, icon: "internaldrive")
                }
                .padding(.vertical, 4)
            }

            // Scans
            Section("Scans (\(liveProject.scanCount))") {
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

                            Button {
                                let _ = storageManager.duplicateScan(scan, from: liveProject, to: liveProject)
                            } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                        }

                        Button {
                            shareScan(scan)
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        Button(role: .destructive) {
                            storageManager.deleteScan(scan, from: liveProject)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let scan = sortedScans[index]
                        storageManager.deleteScan(scan, from: liveProject)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                let name = url.deletingPathExtension().lastPathComponent
                do {
                    let _ = try storageManager.importOBJFile(from: url, name: name, toProject: liveProject)
                } catch {
                    print("Import error: \(error)")
                }
            }
        case .failure(let error):
            print("File picker error: \(error)")
        }
    }

    private func shareScan(_ scan: Scan) {
        if let url = storageManager.exportScan(scan, from: liveProject) {
            let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                rootVC.present(activityVC, animated: true)
            }
        }
    }

    private func exportEntireProject() {
        if let url = storageManager.exportProject(liveProject) {
            let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                rootVC.present(activityVC, animated: true)
            }
        }
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

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail or icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 56, height: 56)

                if let thumbData = scan.thumbnailData,
                   let uiImage = UIImage(data: thumbData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .cornerRadius(8)
                } else {
                    Image(systemName: scan.hasColor ? "paintpalette.fill" : "cube.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.blue)
                }
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(scan.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let dims = scan.shortDimensions {
                        Text(dims)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(3)
                    }

                    Text(scan.formattedFileSize)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    if scan.vertexCount > 0 {
                        Label(formatCompactInline(scan.vertexCount) + " verts", systemImage: "circle.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if scan.faceCount > 0 {
                        Label(formatCompactInline(scan.faceCount) + " faces", systemImage: "triangle.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Date
            VStack(alignment: .trailing, spacing: 2) {
                Text(scan.createdAt.relativeString)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if scan.hasColor {
                    Image(systemName: "paintpalette")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.vertical, 2)
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

// MARK: - Stat Item

struct StatItem: View {
    let label: String
    let value: String
    var icon: String = ""

    var body: some View {
        VStack(spacing: 4) {
            if !icon.isEmpty {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundColor(.accentColor)
            }
            Text(value)
                .font(.subheadline)
                .fontWeight(.bold)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Move to Project Sheet

struct MoveToProjectSheet: View {
    let scan: Scan
    let sourceProject: Project
    let storageManager: StorageManager
    let onDismiss: () -> Void

    var body: some View {
        NavigationView {
            List {
                Section("Move \"\(scan.name)\" to:") {
                    ForEach(storageManager.projects.filter { $0.id != sourceProject.id }) { project in
                        Button {
                            storageManager.moveScan(scan, from: sourceProject, to: project)
                            onDismiss()
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
        }
    }
}
