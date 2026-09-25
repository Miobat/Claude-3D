import SwiftUI

/// Main app view with tab navigation
struct ContentView: View {
    @StateObject private var storageManager: StorageManager
    @State private var selectedTab = 0

    init(storageManager: StorageManager? = nil, initialTab: Int = 0) {
        _storageManager = StateObject(wrappedValue: storageManager ?? StorageManager())
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Scanner Tab
            ScannerView()
                .tabItem {
                    Label("Scan", systemImage: "viewfinder")
                }
                .tag(0)

            // Projects Tab
            ProjectListView()
                .tabItem {
                    Label("Projects", systemImage: "folder.fill")
                }
                .tag(1)

            // All Scans / Viewer Tab
            AllScansView()
                .tabItem {
                    Label("All Scans", systemImage: "cube.fill")
                }
                .tag(2)

            // Settings Tab
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(3)
        }
        .environmentObject(storageManager)
        .tint(FieldStyle.accent)
        .safeAreaInset(edge: .top) {
            if storageManager.isLibraryReadOnly {
                Label("Library needs recovery — saving is disabled. Existing files are preserved.", systemImage: "exclamationmark.shield")
                    .font(.callout)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.orange.opacity(0.2))
            }
        }
        .alert("Storage needs attention", isPresented: Binding(
            get: { storageManager.storageError != nil },
            set: { if !$0 { storageManager.storageError = nil } }
        )) {
            Button("OK", role: .cancel) { storageManager.storageError = nil }
        } message: {
            Text(storageManager.storageError ?? "The operation could not be saved.")
        }
    }
}
