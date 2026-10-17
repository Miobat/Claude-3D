import SwiftUI

/// App-level settings view
struct SettingsView: View {
    // Scan options (mode, range, detail, colour) live on the scan screen itself.
    @AppStorage(ScanSettings.MeasurementUnit.storageKey) private var measurementUnit = ScanSettings.MeasurementUnit.meters.rawValue
    @AppStorage("showGridByDefault") private var showGridByDefault = true
    @AppStorage("appAppearance") private var appearance = "system"
    @Environment(\.dynamicTypeSize) private var typeSize

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
                    FieldHero(eyebrow: AppConstants.brandName, title: "Your workspace.",
                              subtitle: "Preferences for the way you capture.", icon: "slider.horizontal.3")
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section("Appearance") {
                    Menu {
                        Picker("Color scheme", selection: $appearance) {
                            Text("System").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }
                    } label: {
                        preferenceLabel("Color scheme", value: appearance.capitalized, symbol: "circle.lefthalf.filled")
                    }
                    .accessibilityLabel("Color scheme").accessibilityValue(appearance.capitalized)
                }.listRowBackground(FieldStyle.surface)
                // Viewer settings
                Section("Viewer") {
                    Menu {
                        Picker("Measurement unit", selection: $measurementUnit) {
                            ForEach(ScanSettings.MeasurementUnit.allCases, id: \.rawValue) { unit in
                                Text("\(unit.rawValue) (\(unit.abbreviation))").tag(unit.rawValue)
                            }
                        }
                    } label: {
                        preferenceLabel("Measurement unit", value: measurementUnit, symbol: "ruler")
                    }
                    .accessibilityLabel("Measurement unit").accessibilityValue(measurementUnit)

                    Toggle("Show grid by default", isOn: $showGridByDefault)
                }.listRowBackground(FieldStyle.surface)

                // Storage
                Section("Storage") {
                    infoRow("Projects", value: "\(storageManager.projects.count)")
                    infoRow("Total scans", value: "\(storageManager.projects.reduce(0) { $0 + $1.scanCount })")
                    infoRow("Storage used", value: storageUsed)

                }.listRowBackground(FieldStyle.surface)

                // Debug
                Section("Support & diagnostics") {
                    NavigationLink {
                        DebugLogView()
                    } label: {
                        HStack {
                            Image(systemName: "ladybug.fill")
                                .foregroundStyle(FieldStyle.accent)
                            Text("Debug Log")
                            Spacer()
                            Text("\(DebugLogger.shared.entries.count)")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }
                }.listRowBackground(FieldStyle.surface)

                // About
                Section("About") {
                    infoRow("App", value: AppConstants.appName)
                    infoRow("By", value: AppConstants.companyName)
                    infoRow("Version", value: versionLabel)

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
                }.listRowBackground(FieldStyle.surface)
                Section {
                    Label("Stored on this device", systemImage: "internaldrive")
                    Text("Model exports are not full backups: source photos and measurements are not included. Keep the app installed to preserve your library.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Your files") }
                    .listRowBackground(FieldStyle.surface)
                Section {
                    Button("Delete all projects and scans", role: .destructive) { showingClearConfirm = true }
                } footer: { Text("Permanent removal. This action cannot be undone.") }
                    .listRowBackground(FieldStyle.surface)
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

    /// Stacked at accessibility sizes: neither the name nor its current value is squeezed.
    private func preferenceLabel(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: symbol).font(.body.weight(.medium))
                    .foregroundStyle(FieldStyle.accent)
                    .frame(width: 36, height: 36)
                    .background(FieldStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).foregroundStyle(.primary)
                Text(value).font(.subheadline).foregroundStyle(FieldStyle.accent)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
                .foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.vertical, 4).contentShape(Rectangle())
    }

    private func infoRow(_ title: String, value: String) -> some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                    Text(value).foregroundStyle(.secondary)
                }.fixedSize(horizontal: false, vertical: true)
            } else {
                LabeledContent(title, value: value)
            }
        }.accessibilityElement(children: .combine)
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
