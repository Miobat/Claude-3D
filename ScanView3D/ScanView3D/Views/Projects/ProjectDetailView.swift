import SwiftUI

/// Detailed view of a project showing all its scans
struct ProjectDetailView: View {
    let project: Project
    @EnvironmentObject var storageManager: StorageManager
    @State private var showingImporter = false
    @State private var renamingScan: Scan?
    @State private var renameName = ""

    // Get the live project from storage manager
    private var liveProject: Project {
        storageManager.projects.first { $0.id == project.id } ?? project
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
                Button {
                    showingImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
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
                    renameScan(scan, to: renameName)
                    renamingScan = nil
                    renameName = ""
                }
            }
            Button("Cancel", role: .cancel) {
                renamingScan = nil
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

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "viewfinder")
                .font(.system(size: 50))
                .foregroundColor(.gray)

            Text("No Scans Yet")
                .font(.title3)
                .fontWeight(.bold)

            Text("Go to the Scanner tab to create a new scan,\nor import an existing OBJ file.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showingImporter = true
            } label: {
                Label("Import OBJ File", systemImage: "square.and.arrow.down")
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
                HStack(spacing: 20) {
                    StatItem(label: "Scans", value: "\(liveProject.scanCount)")
                    StatItem(label: "Vertices", value: liveProject.totalVertices.formatted())
                    StatItem(label: "Faces", value: liveProject.totalFaces.formatted())
                }
                .padding(.vertical, 4)
            }

            // Scans
            Section("Scans") {
                ForEach(liveProject.scans) { scan in
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

                        Button {
                            shareScan(scan)
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }

                        Button(role: .destructive) {
                            storageManager.deleteScan(scan, from: liveProject)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        storageManager.deleteScan(liveProject.scans[index], from: liveProject)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let name = url.deletingPathExtension().lastPathComponent
            do {
                let _ = try storageManager.importOBJFile(from: url, name: name, toProject: liveProject)
            } catch {
                print("Import error: \(error)")
            }
        case .failure(let error):
            print("File picker error: \(error)")
        }
    }

    private func renameScan(_ scan: Scan, to newName: String) {
        if var updatedProject = storageManager.projects.first(where: { $0.id == project.id }) {
            if let scanIndex = updatedProject.scans.firstIndex(where: { $0.id == scan.id }) {
                updatedProject.scans[scanIndex].name = newName
                storageManager.updateProject(updatedProject)
            }
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
}

// MARK: - Scan Row

struct ScanRow: View {
    let scan: Scan

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: scan.hasColor ? "paintpalette.fill" : "cube.fill")
                    .foregroundColor(.blue)
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(scan.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    if scan.vertexCount > 0 {
                        Text("\(scan.vertexCount.formatted()) verts")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if scan.faceCount > 0 {
                        Text("\(scan.faceCount.formatted()) faces")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text(scan.formattedFileSize)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Date
            Text(scan.createdAt.relativeString)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Stat Item

struct StatItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
                .fontWeight(.bold)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
