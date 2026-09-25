import SwiftUI

/// App-level settings view
struct SettingsView: View {
    // Scan options (mode, range, detail, colour) live on the scan screen itself.
    @AppStorage(ScanSettings.MeasurementUnit.storageKey) private var measurementUnit = ScanSettings.MeasurementUnit.meters.rawValue
    @AppStorage("showGridByDefault") private var showGridByDefault = true
    @AppStorage("appAppearance") private var appearance = "system"

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }

    @EnvironmentObject var storageManager: StorageManager

    @State private var showingClearConfirm = false
    @State private var storageUsed: String = "Calculating..."

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FieldHero(eyebrow: "ScanView 3D", title: "Make it yours.",
                              subtitle: "Your workspace. Your preferences.", icon: "slider.horizontal.3")
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section("Appearance") {
                    Picker("Color scheme", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }
                // Viewer settings
                Section("Viewer") {
                    Picker("Measurement Unit", selection: $measurementUnit) {
                        ForEach(ScanSettings.MeasurementUnit.allCases, id: \.rawValue) { unit in
                            Text("\(unit.rawValue) (\(unit.abbreviation))").tag(unit.rawValue)
                        }
                    }

                    Toggle("Show Grid by Default", isOn: $showGridByDefault)
                }

                // Storage
                Section("Storage") {
                    LabeledContent("Projects", value: "\(storageManager.projects.count)")
                    LabeledContent("Total Scans", value: "\(storageManager.projects.reduce(0) { $0 + $1.scanCount })")
                    LabeledContent("Storage Used", value: storageUsed)

                }

                // Debug
                Section("Support & diagnostics") {
                    NavigationLink {
                        DebugLogView()
                    } label: {
                        HStack {
                            Image(systemName: "ladybug.fill")
                                .foregroundColor(.orange)
                            Text("Debug Log")
                            Spacer()
                            Text("\(DebugLogger.shared.entries.count)")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }
                }

                // About
                Section("About") {
                    LabeledContent("App", value: AppConstants.appName)
                    LabeledContent("Version", value: versionLabel)

                    HStack {
                        Text("LiDAR")
                        Spacer()
                        #if targetEnvironment(simulator)
                        Label("Simulated", systemImage: "desktopcomputer")
                            .foregroundColor(.orange)
                            .font(.subheadline)
                        #else
                        if LiDARScanner.isLiDARAvailable {
                            Label("Available", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.subheadline)
                        } else {
                            Label("Not Available", systemImage: "xmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.subheadline)
                        }
                        #endif
                    }
                }
                Section {
                    Label("Stored on this device", systemImage: "internaldrive")
                    Text("Model exports are not full backups: source photos and measurements are not included. Keep the app installed to preserve your library.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Your files") }
                Section {
                    Button("Delete all projects and scans", role: .destructive) { showingClearConfirm = true }
                } footer: { Text("Permanent removal. This action cannot be undone.") }
            }
            .fieldScreen()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                calculateStorageUsage()
            }
            .alert("Delete All Data", isPresented: $showingClearConfirm) {
                Button("Delete", role: .destructive) {
                    clearAllData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all projects and scan files. This cannot be undone.")
            }
        }
    }

    private func calculateStorageUsage() {
        DispatchQueue.global(qos: .utility).async {
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let size = directorySize(url: documentsDir)
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB, .useGB]
            formatter.countStyle = .file

            DispatchQueue.main.async {
                storageUsed = formatter.string(fromByteCount: Int64(size))
            }
        }
    }

    private func directorySize(url: URL) -> UInt64 {
        let fileManager = FileManager.default
        var totalSize: UInt64 = 0

        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            while let fileURL = enumerator.nextObject() as? URL {
                if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += UInt64(fileSize)
                }
            }
        }

        return totalSize
    }

    private func clearAllData() {
        for project in storageManager.projects {
            storageManager.deleteProject(project)
        }
        calculateStorageUsage()
    }
}
