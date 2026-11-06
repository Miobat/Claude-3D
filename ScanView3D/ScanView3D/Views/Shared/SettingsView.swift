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
                    brandHeader
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section("Preferences") {
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

                    Toggle(isOn: $showGridByDefault) {
                        HStack(spacing: 12) {
                            preferenceIcon("square.grid.3x3")
                            Text("Show grid by default")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
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
                        HStack(spacing: 12) {
                            preferenceIcon("waveform.path.ecg")
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Debug Log")
                                Text("Review and share diagnostics")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }.listRowBackground(FieldStyle.surface)

                // About
                Section("About") {
                    infoRow("Version", value: versionLabel)

                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text("LiDAR")
                            Spacer()
                            lidarStatus
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("LiDAR")
                            lidarStatus
                        }
                    }
                    .accessibilityElement(children: .combine)
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

    private var brandHeader: some View {
        HStack(spacing: 14) {
            if !typeSize.isAccessibilitySize { TinyScannerMark(size: 44) }
            VStack(alignment: .leading, spacing: 4) {
                Text(AppConstants.appName).font(.headline).foregroundStyle(.white)
                Text("by \(AppConstants.companyName)")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.72))
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(20)
        .fieldPanel()
        .accessibilityElement(children: .combine)
    }

    private var lidarStatus: some View {
        Group {
            #if targetEnvironment(simulator)
            Label("Simulated", systemImage: "desktopcomputer")
                .foregroundStyle(.orange)
            #else
            if LiDARScanner.isLiDARAvailable {
                Label("Available", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Not available", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            #endif
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func preferenceIcon(_ symbol: String) -> some View {
        if !typeSize.isAccessibilitySize {
            Image(systemName: symbol).font(.body.weight(.medium))
                .foregroundStyle(FieldStyle.accent)
                .frame(width: 34, height: 34)
                .background(FieldStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
        }
    }

    /// Stacked at accessibility sizes: neither the name nor its current value is squeezed.
    private func preferenceLabel(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            preferenceIcon(symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(Color(uiColor: .label))
                Text(value).font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
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
        }.monospacedDigit().accessibilityElement(children: .combine)
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
