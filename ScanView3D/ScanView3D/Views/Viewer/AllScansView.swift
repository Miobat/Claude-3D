import SwiftUI

/// A visual library with a compact list alternative for large collections.
struct AllScansView: View {
    @EnvironmentObject var storageManager: StorageManager
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("scanLibraryGrid") private var showsGrid = true
    @State private var searchText = ""

    private var allScans: [(scan: Scan, project: Project)] {
        storageManager.projects.flatMap { project in
            project.scans.map { (scan: $0, project: project) }
        }.filter {
            searchText.isEmpty || $0.scan.name.localizedCaseInsensitiveContains(searchText)
                || $0.project.name.localizedCaseInsensitiveContains(searchText)
        }.sorted { $0.scan.createdAt > $1.scan.createdAt }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if searchText.isEmpty {
                        librarySummary
                    }
                    if !searchText.isEmpty {
                        Text("\(allScans.count) matching scan\(allScans.count == 1 ? "" : "s")")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                    if allScans.isEmpty {
                        FieldEmptyState(icon: searchText.isEmpty ? "viewfinder" : "magnifyingglass",
                                        title: searchText.isEmpty ? "Your capture library" : "No matching scans",
                                        message: searchText.isEmpty ? "Capture from the Scan tab, or import a model from Projects. All your saved scans appear here." : "Try a scan name, a project name, or clear your search.")
                            .fieldCard()
                    } else if showsGrid && !typeSize.isAccessibilitySize {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 16)], spacing: 16) {
                            ForEach(allScans, id: \.scan.id) { item in
                                NavigationLink {
                                    ModelViewerView(scan: item.scan, project: item.project)
                                } label: { scanCard(item.scan, project: item.project) }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(allScans, id: \.scan.id) { item in
                                NavigationLink {
                                    ModelViewerView(scan: item.scan, project: item.project)
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Label(item.project.name, systemImage: "folder")
                                            .font(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        ScanRow(scan: item.scan)
                                    }.padding(16).fieldCard()
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }
            .fieldScreen()
            .navigationTitle("All Scans")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Find a scan or project")
            .toolbar {
                if !typeSize.isAccessibilitySize {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showsGrid.toggle() } label: {
                            Image(systemName: showsGrid ? "list.bullet" : "square.grid.2x2")
                        }
                        .accessibilityLabel(showsGrid ? "Show scans as a list" : "Show scans as a grid")
                    }
                }
            }
        }
    }

    private var librarySummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if !typeSize.isAccessibilitySize {
                    Image(systemName: "square.stack.3d.up")
                        .font(.title3.weight(.medium)).foregroundStyle(FieldStyle.accent)
                        .accessibilityHidden(true)
                }
                Text("Your captures").font(.title2.weight(.semibold)).tracking(-0.4)
            }
            Text("\(allScans.count) scan\(allScans.count == 1 ? "" : "s") · Newest first")
                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func scanCard(_ scan: Scan, project: Project) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldThumbnail(data: scan.thumbnailData, icon: ScanLibraryKind.icon(for: scan))
                .aspectRatio(1.2, contentMode: .fit)
                .padding(8)
            VStack(alignment: .leading, spacing: 7) {
                Text(ScanLibraryKind.title(for: scan).uppercased())
                    .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(FieldStyle.accent)
                Text(scan.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                Text(project.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Divider().overlay(FieldStyle.line).padding(.vertical, 3)
                HStack(spacing: 5) {
                    Text((scan.fileName as NSString).pathExtension.uppercased())
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(scan.formattedFileSize).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 16)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fieldCard()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this scan in the 3D viewer")
    }
}
