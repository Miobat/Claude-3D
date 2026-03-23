import SwiftUI

/// On-device debug log viewer for TestFlight testing.
struct DebugLogView: View {
    @ObservedObject private var logger = DebugLogger.shared
    @State private var filterLevel: String = "All"
    @State private var searchText = ""
    @State private var showingShareSheet = false
    @State private var showingClearConfirm = false

    private let levels = ["All", "INFO", "WARN", "ERROR", "DEBUG"]

    private var filteredEntries: [DebugLogger.LogEntry] {
        var result = logger.entries
        if filterLevel != "All" {
            result = result.filter { $0.level == filterLevel }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.message.localizedCaseInsensitiveContains(searchText) ||
                $0.category.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result.reversed() // newest first
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(levels, id: \.self) { level in
                        Button {
                            filterLevel = level
                        } label: {
                            Text(level)
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(filterLevel == level ? colorForLevel(level) : Color.gray.opacity(0.2))
                                .foregroundColor(filterLevel == level ? .white : .primary)
                                .cornerRadius(8)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            Divider()

            if filteredEntries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No log entries")
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List(filteredEntries) { entry in
                    LogEntryRow(entry: entry)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
                .listStyle(.plain)
            }
        }
        .searchable(text: $searchText, prompt: "Search logs...")
        .navigationTitle("Debug Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        showingShareSheet = true
                    } label: {
                        Label("Export Logs", systemImage: "square.and.arrow.up")
                    }

                    Button(role: .destructive) {
                        showingClearConfirm = true
                    } label: {
                        Label("Clear Logs", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Clear All Logs?", isPresented: $showingClearConfirm) {
            Button("Clear", role: .destructive) {
                logger.clear()
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(text: logger.exportText())
        }
    }

    private func colorForLevel(_ level: String) -> Color {
        switch level {
        case "ERROR": return .red
        case "WARN":  return .orange
        case "INFO":  return .blue
        case "DEBUG": return .gray
        default:      return .blue
        }
    }
}

// MARK: - Log Entry Row

private struct LogEntryRow: View {
    let entry: DebugLogger.LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.level)
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(levelColor.opacity(0.2))
                    .foregroundColor(levelColor)
                    .cornerRadius(3)

                Text(entry.category)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer()

                Text(entry.formattedTimestamp)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
            }

            Text(entry.message)
                .font(.caption)
                .foregroundColor(.primary)
                .lineLimit(5)
        }
        .padding(.vertical, 2)
    }

    private var levelColor: Color {
        switch entry.level {
        case "ERROR": return .red
        case "WARN":  return .orange
        case "INFO":  return .blue
        case "DEBUG": return .gray
        default:      return .primary
        }
    }
}

// MARK: - Share Sheet

private struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
