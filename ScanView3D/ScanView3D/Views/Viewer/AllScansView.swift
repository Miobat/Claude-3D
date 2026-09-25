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
                        FieldHero(eyebrow: "Scan library", title: "Every detail.\nReady to explore.",
                                  subtitle: "Your captures, together in one view.", icon: "cube.transparent")
                    }
                    HStack {
                        Text(searchText.isEmpty ? "Latest captures" : "Search results").font(.headline)
                        Spacer()
                        Text("\(allScans.count) scans").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if allScans.isEmpty {
                        FieldEmptyState(icon: searchText.isEmpty ? "viewfinder" : "magnifyingglass",
                                        title: searchText.isEmpty ? "Your next perspective starts here" : "No matching scans",
                                        message: searchText.isEmpty ? "Open Scan to capture something new, or import a model from Projects." : "Search by scan or project name.")
                    } else if showsGrid {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 280 : 155), spacing: 14)], spacing: 14) {
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
                                    VStack(alignment: .leading, spacing: 10) {
                                        ScanRow(scan: item.scan)
                                        Label(item.project.name, systemImage: "folder")
                                            .font(.caption).foregroundStyle(.secondary)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsGrid.toggle() } label: {
                        Image(systemName: showsGrid ? "list.bullet" : "square.grid.2x2")
                    }
                    .accessibilityLabel(showsGrid ? "Show scans as a list" : "Show scans as a grid")
                }
            }
        }
    }

    private func scanCard(_ scan: Scan, project: Project) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldThumbnail(data: scan.thumbnailData)
                .aspectRatio(1.2, contentMode: .fit)
                .padding(8)
            VStack(alignment: .leading, spacing: 8) {
                Text(scan.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                Text(project.name).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 5) {
                    Text((scan.fileName as NSString).pathExtension.uppercased())
                        .font(.caption2.weight(.bold)).foregroundStyle(FieldStyle.accent)
                    Spacer(minLength: 0)
                    Text(scan.formattedFileSize).font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 16)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fieldCard()
        .accessibilityElement(children: .combine)
    }
}
