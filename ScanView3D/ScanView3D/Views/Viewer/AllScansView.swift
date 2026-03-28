import SwiftUI

/// Shows all scans across all projects in a browsable grid/list
struct AllScansView: View {
    @EnvironmentObject var storageManager: StorageManager
    @State private var viewMode: ViewMode = .list
    @State private var searchText = ""

    enum ViewMode {
        case list
        case grid
    }

    /// All scans paired with their project, sorted by date
    private var allScans: [(scan: Scan, project: Project)] {
        var results: [(Scan, Project)] = []
        for project in storageManager.projects {
            for scan in project.scans {
                results.append((scan, project))
            }
        }
        // Sort newest first
        results.sort { $0.0.createdAt > $1.0.createdAt }

        // Filter by search text
        if !searchText.isEmpty {
            results = results.filter {
                $0.0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.1.name.localizedCaseInsensitiveContains(searchText)
            }
        }

        return results
    }

    private var totalScans: Int {
        storageManager.projects.reduce(0) { $0 + $1.scanCount }
    }

    var body: some View {
        NavigationView {
            Group {
                if allScans.isEmpty && searchText.isEmpty {
                    emptyState
                } else if allScans.isEmpty {
                    noResultsState
                } else {
                    scanContent
                }
            }
            .navigationTitle("All Scans")
            .searchable(text: $searchText, prompt: "Search scans...")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation {
                            viewMode = viewMode == .list ? .grid : .list
                        }
                    } label: {
                        Image(systemName: viewMode == .list ? "square.grid.2x2" : "list.bullet")
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 60))
                .foregroundColor(.gray)

            Text("No Scans Yet")
                .font(.title2)
                .fontWeight(.bold)

            Text("Scans from all your projects will\nappear here for quick access.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.gray)
            Text("No scans matching \"\(searchText)\"")
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Scan Content

    private var scanContent: some View {
        Group {
            if viewMode == .list {
                listView
            } else {
                gridView
            }
        }
    }

    private var listView: some View {
        List {
            Section {
                Text("\(totalScans) scan\(totalScans == 1 ? "" : "s") across \(storageManager.projects.count) project\(storageManager.projects.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(allScans, id: \.scan.id) { item in
                NavigationLink(destination: ModelViewerView(scan: item.scan, project: item.project)) {
                    HStack(spacing: 12) {
                        // Thumbnail
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.blue.opacity(0.15))
                                .frame(width: 50, height: 50)

                            if let thumbData = item.scan.thumbnailData,
                               let uiImage = UIImage(data: thumbData) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 50, height: 50)
                                    .cornerRadius(8)
                            } else {
                                Image(systemName: "cube.fill")
                                    .foregroundColor(.blue)
                            }
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.scan.name)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .lineLimit(1)

                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.caption2)
                                Text(item.project.name)
                                    .font(.caption)
                            }
                            .foregroundColor(.secondary)

                            HStack(spacing: 8) {
                                if let dims = item.scan.shortDimensions {
                                    Text(dims)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Text(item.scan.formattedFileSize)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        Text(item.scan.createdAt.relativeString)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 140), spacing: 12)
            ], spacing: 12) {
                ForEach(allScans, id: \.scan.id) { item in
                    NavigationLink(destination: ModelViewerView(scan: item.scan, project: item.project)) {
                        VStack(spacing: 6) {
                            // Thumbnail
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.blue.opacity(0.1))
                                    .aspectRatio(1, contentMode: .fit)

                                if let thumbData = item.scan.thumbnailData,
                                   let uiImage = UIImage(data: thumbData) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .aspectRatio(1, contentMode: .fit)
                                        .cornerRadius(10)
                                } else {
                                    VStack(spacing: 4) {
                                        Image(systemName: "cube.fill")
                                            .font(.system(size: 30))
                                            .foregroundColor(.blue)
                                        if let dims = item.scan.shortDimensions {
                                            Text(dims)
                                                .font(.system(size: 9))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }

                            VStack(spacing: 2) {
                                Text(item.scan.name)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                    .foregroundColor(.primary)

                                Text(item.project.name)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }
}
