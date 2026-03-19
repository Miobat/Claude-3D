import SwiftUI

/// App-level settings view
struct SettingsView: View {
    @AppStorage("meshDetail") private var meshDetail = "Medium"
    @AppStorage("captureTexture") private var captureTexture = true
    @AppStorage("measurementUnit") private var measurementUnit = "Meters"
    @AppStorage("autoSave") private var autoSave = true
    @AppStorage("showGridByDefault") private var showGridByDefault = true

    @EnvironmentObject var storageManager: StorageManager

    @State private var showingClearConfirm = false
    @State private var storageUsed: String = "Calculating..."

    var body: some View {
        NavigationView {
            Form {
                // Scanning settings
                Section("Scanning") {
                    Picker("Mesh Detail", selection: $meshDetail) {
                        ForEach(ScanSettings.MeshDetail.allCases, id: \.rawValue) { detail in
                            Text(detail.rawValue).tag(detail.rawValue)
                        }
                    }

                    Toggle("Capture Texture/Color", isOn: $captureTexture)
                    Toggle("Auto-save Scans", isOn: $autoSave)
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

                    Button(role: .destructive) {
                        showingClearConfirm = true
                    } label: {
                        Text("Delete All Data")
                    }
                }

                // About
                Section("About") {
                    LabeledContent("App", value: AppConstants.appName)
                    LabeledContent("Version", value: "1.0.0")

                    HStack {
                        Text("LiDAR")
                        Spacer()
                        if LiDARScanner.isLiDARAvailable {
                            Label("Available", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.subheadline)
                        } else {
                            Label("Not Available", systemImage: "xmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
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
