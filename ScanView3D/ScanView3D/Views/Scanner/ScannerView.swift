import SwiftUI
import SceneKit
import simd
#if !targetEnvironment(simulator)
import ARKit
#endif

/// Main scanning interface with AR camera view and controls
struct ScannerView: View {
    #if targetEnvironment(simulator)
    @StateObject private var scanner = MockLiDARScanner()
    #else
    @StateObject private var scanner = LiDARScanner()
    #endif
    @StateObject private var location = LocationProvider()
    @StateObject private var recovery = CaptureRecovery()
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeDraft: CaptureDraft?
    @State private var recoveredDraft = false
    @State private var recoveredPoses: [CapturedPose] = []
    @State private var captureLocation: CaptureLocation?
    @State private var showingRecovery = false
    @State private var showingResetConfirmation = false
    @State private var draftToDiscard: CaptureDraft?
    @State private var checkpointInFlight = false
    @State private var preparationToken = UUID()
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    @EnvironmentObject var storageManager: StorageManager
    @State private var settings = ScanSettings.load()

    // Save flow
    @State private var showingSaveDialog = false
    @State private var showingCancelOptions = false
    @State private var scanName = ""
    @State private var selectedProject: Project?
    @State private var showingNewProjectDialog = false
    @State private var newProjectName = ""
    @State private var exportFormat: StorageManager.ExportFormat = .obj
    @State private var processingLevel: MeshProcessor.ProcessingLevel = .standard
    @State private var isSaving = false
    @State private var savingProgress = ""
    /// The combined scan, built once in the background when the user taps Stop.
    @State private var pendingMesh: MeshData?
    @State private var isPreparingMesh = false

    @State private var showingCaptureSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showMeshOverlay = true
    @State private var savedScan: Scan?
    @State private var savedProject: Project?
    @State private var showingSavedScan = false

    var body: some View {
        ZStack {
            #if targetEnvironment(simulator)
            SimulatorScanView(scanner: scanner)
                .ignoresSafeArea()
            #else
            ARScannerViewRepresentable(scanner: scanner, showMeshOverlay: $showMeshOverlay)
                .ignoresSafeArea()
            #endif

            GeometryReader { geometry in
                Group {
                    if geometry.size.width > geometry.size.height {
                        HStack(alignment: .top, spacing: 0) {
                            VStack(spacing: 8) {
                                topStatusBar
                                statusMessages
                                Spacer(minLength: 0)
                            }
                            VStack(spacing: 8) {
                                if scanner.isScanning {
                                    Spacer(minLength: 0)
                                    captureDashboard
                                } else {
                                    ScrollView { prescanControls }
                                        .scrollIndicators(.hidden)
                                        .disabled(activeDraft != nil || isPreparingMesh || isSaving || scanner.isFinalizing)
                                }
                                bottomControls
                            }
                            .frame(width: min(400, geometry.size.width * 0.48))
                        }
                    } else {
                        VStack(spacing: 10) {
                            topStatusBar
                            statusMessages
                            Spacer(minLength: 8)
                            if scanner.isScanning {
                                captureDashboard
                            } else {
                                ScrollView { prescanControls }
                                    .scrollIndicators(.hidden)
                                    .frame(maxHeight: min(370, geometry.size.height * 0.62))
                                    .disabled(activeDraft != nil || isPreparingMesh || isSaving || scanner.isFinalizing)
                            }
                            bottomControls
                        }
                        .frame(maxWidth: 600).frame(maxWidth: .infinity)
                    }
                }
                .environment(\.colorScheme, .dark)
            }

            #if !targetEnvironment(simulator)
            if !LiDARScanner.isLiDARAvailable {
                lidarUnavailableView
            }
            #endif
        }
        .onAppear {
            if settings.captureMode == .highQuality && !highQualitySupported {
                settings.captureMode = .fast
            }
            scanner.startPreview()
            recovery.refresh()
            #if DEBUG && targetEnvironment(simulator)
            if DesignPreview.screen == "capture-settings" { showingCaptureSettings = true }
            #endif
            if activeDraft != nil, !scanner.isScanning { showingSaveDialog = true }
        }
        .onDisappear {
            suspendCapture()
            scanner.stopPreview()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { suspendCapture() }
            if phase == .active, activeDraft != nil, !scanner.isScanning { showingSaveDialog = true }
        }
        .onChange(of: scanner.needsRecoveryCheckpoint) { _, needed in
            if needed { suspendCapture() }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            checkpointWhileCapturing()
        }
        .onChange(of: settings) { _, newValue in
            newValue.save()
        }
        .sheet(isPresented: $showingSaveDialog) {
            saveDialogSheet
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showingRecovery) { recoverySheet }
        .sheet(isPresented: $showingCaptureSettings) { captureSettingsSheet }
        .confirmationDialog("Discard this capture?", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
            Button("Discard Capture", role: .destructive) { discardCurrentCapture() }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showingSavedScan) {
            if let scan = savedScan, let project = savedProject {
                NavigationStack {
                    ModelViewerView(scan: scan, project: project)
                        .environmentObject(storageManager)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showingSavedScan = false }
                            }
                        }
                }
            }
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .onChange(of: scanner.scanError) { _, error in
            if let error = error {
                errorMessage = error
                showingError = true
            }
        }
    }

    @ViewBuilder private var statusMessages: some View {
        if settings.alignToNorth, scanner.isScanning {
            Text(location.status).font(.caption).foregroundStyle(.white).padding(10).fieldPanel()
        }
        if !scanner.isScanning, !recovery.drafts.isEmpty {
            Button("Unfinished captures (\(recovery.drafts.count))") { showingRecovery = true }
                .buttonStyle(.bordered).tint(FieldStyle.mint).padding(.horizontal, 20)
                .disabled(isPreparingMesh || isSaving || scanner.isFinalizing)
        }
        if scanner.isScanning, let warning = scanner.trackingWarning ?? scanner.captureHint {
            trackingBanner(warning)
        }
    }

    private var captureDashboard: some View {
        VStack(spacing: 8) {
            scanCapacityGauge
            scanningInfoBar
        }
        .padding(.top, 12).fieldPanel().padding(.horizontal, 16)
    }

    // MARK: - Top Status Bar

    private var topStatusBar: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                if scanner.isScanning || !typeSize.isAccessibilitySize {
                HStack(spacing: 8) {
                    Circle().fill(scanner.isScanning ? (scanner.isPaused ? Color.orange : FieldStyle.mint) : Color.white.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(scanner.isScanning ? (scanner.isPaused ? "PAUSED" : "CAPTURING") : "SCANVIEW 3D")
                        .font(.caption.weight(.bold)).tracking(2)
                }.foregroundStyle(FieldStyle.mint)
                }
                Text(scanner.isScanning ? scanner.scanProgress : (typeSize.isAccessibilitySize ? "Ready to scan" : "Capture your world"))
                    .font(scanner.isScanning ? .subheadline.weight(.medium) : (typeSize.isAccessibilitySize ? .headline : .title2.weight(.semibold)))
                    .foregroundStyle(.white)
                if scanner.isScanning {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { captureCounts }
                        VStack(alignment: .leading, spacing: 4) { captureCounts }
                    }.font(.caption).foregroundStyle(.white.opacity(0.8)).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            #if targetEnvironment(simulator)
            if !typeSize.isAccessibilitySize {
            Text("SIM").font(.caption2.weight(.bold))
                .padding(8).background(.white.opacity(0.12), in: Capsule()).foregroundStyle(.white)
            }
            #else
            if scanner.isScanning {
                Button { showMeshOverlay.toggle() } label: {
                    FieldIcon(symbol: "square.grid.3x3", selected: showMeshOverlay)
                }
                .accessibilityLabel(showMeshOverlay ? "Hide mesh overlay" : "Show mesh overlay")
            }
            #endif
        }
        .padding(18).fieldPanel().padding(.horizontal, 16).padding(.top, 8)
    }

    @ViewBuilder private var captureCounts: some View {
        if scanner.depthPointCount > 0 {
            Label("\(scanner.depthPointCount.formatted()) points", systemImage: "aqi.medium")
        } else {
            Label("\(scanner.vertexCount.formatted()) vertices", systemImage: "circle.dotted")
            Label("\(scanner.faceCount.formatted()) faces", systemImage: "triangle")
        }
        if usesPhotos { Label("\(scanner.highResFrameCount) photos", systemImage: "photo.stack") }
    }

    private func trackingBanner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.yellow))
            .padding(.top, 6)
            .transition(.opacity)
    }

    private var usesPhotos: Bool {
        settings.captureMode == .highQuality || settings.captureMode == .splatExport
    }

    // MARK: - Scan Capacity Gauge

    private var scanCapacityGauge: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(capacityColor)
                        .frame(width: geo.size.width * min(scanner.scanCapacityPercent / 100.0, 1.0), height: 6)
                }
            }
            .frame(height: 6)

            HStack {
                Text(String(format: "%.0f MB est.", scanner.estimatedFileSizeMB))
                Spacer()
                Text(scanner.scanCapacityPercent > 80
                     ? "Memory nearly full"
                     : String(format: "%.0f%% memory used", scanner.scanCapacityPercent))
                    .foregroundColor(scanner.scanCapacityPercent > 80 ? .orange : .gray)
            }
            .font(.caption2)
            .foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, AppConstants.Layout.padding)
        .padding(.bottom, 4)
    }

    private var capacityColor: Color {
        if scanner.scanCapacityPercent > 80 { return .red }
        if scanner.scanCapacityPercent > 60 { return .orange }
        return FieldStyle.mint
    }

    // MARK: - Pre-Scan Controls

    private var highQualitySupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return PhotogrammetryProcessor.isSupported
        #endif
    }

    private var prescanControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Capture mode").font(.headline)
                Spacer()
                Image(systemName: settings.captureMode.icon).foregroundStyle(FieldStyle.mint)
            }
            LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(ScanSettings.CaptureMode.allCases, id: \.self) { mode in
                    let unavailable = mode == .highQuality && !highQualitySupported
                    let selected = settings.captureMode == mode
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { settings.captureMode = mode }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: mode.icon).font(.system(size: 18))
                            Text(mode.shortName).font(.subheadline.weight(.semibold))
                            Spacer(minLength: 0)
                            if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                        }
                        .padding(.horizontal, 12).frame(minHeight: 48)
                        .foregroundStyle(selected ? FieldStyle.ink : .white)
                        .background(selected ? FieldStyle.mint : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                        .opacity(unavailable ? 0.4 : 1)
                    }
                    .buttonStyle(.plain).disabled(unavailable)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityHint(unavailable ? "Not supported on this device" : mode.description)
                }
            }
            Text(settings.captureMode.description).font(.caption).foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(.white.opacity(0.12))
            Button { showingCaptureSettings = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(FieldStyle.mint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scan settings").font(.subheadline.weight(.semibold))
                        Text(String(format: "%.1f m range", settings.rangeValue) + (settings.captureMode.usesDetail ? String(format: " · %.0f mm detail", settings.detailMM) : " · Photo capture"))
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }.frame(minHeight: 48).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .foregroundStyle(.white).padding(18).fieldPanel().padding(.horizontal, 16)
    }

    private var captureSettingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Label(settings.captureMode.rawValue, systemImage: settings.captureMode.icon).font(.headline)
                    Text(settings.captureMode.description).font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Capture range", value: String(format: "%.1f m", settings.rangeValue))
                    Slider(value: $settings.rangeValue, in: 0.3...5.0, step: 0.1)
                        .accessibilityLabel("Capture range in metres")
                } header: { Text("Range") } footer: {
                    Text("Keeps surfaces within this distance of your walking path.")
                }
                if settings.captureMode.usesDetail {
                    Section {
                        LabeledContent("Point spacing", value: String(format: "%.0f mm", settings.detailMM))
                        Slider(value: $settings.detailMM, in: 5...20, step: 1)
                            .accessibilityLabel("Point spacing in millimetres")
                    } header: { Text("Detail") } footer: {
                        Text("Smaller spacing makes larger files. Sampling density is not measurement accuracy.")
                    }
                }
                if settings.captureMode.usesMeshMode {
                    Section("Surfaces") {
                        Picker("Keep", selection: $settings.meshMode) {
                            ForEach(ScanSettings.MeshMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                        }
                        Text(settings.meshMode.description).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if settings.captureMode.usesPhotos {
                    Section {
                        Toggle("12 MP photos", isOn: $settings.highResPhotos)
                    } footer: { Text("Higher resolution captures finer photo detail and may use about 1 GB per scan.") }
                }
                if settings.captureMode.usesColorToggle {
                    Section { Toggle("Capture photo color", isOn: $settings.captureTexture) } footer: {
                        Text("Turn off for a simpler grey model and faster processing.")
                    }
                }
                Section {
                    Toggle("Align to north + GPS", isOn: $settings.alignToNorth)
                } header: { Text("Orientation") } footer: {
                    Text(settings.alignToNorth
                         ? "Requests compass alignment and approximate phone GPS. Not survey control."
                         : "The scan is levelled and aligned with the walls.")
                }
            }
            .fieldScreen().navigationTitle("Scan settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { showingCaptureSettings = false }.fontWeight(.semibold)
            }}
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: - Scanning Info Bar

    private var scanningInfoBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
            chip(settings.captureMode.shortName, icon: settings.captureMode.icon, color: FieldStyle.mint)
            chip(String(format: "%.1f m", settings.rangeValue), icon: "scope", color: .cyan)
            if settings.captureMode.usesMeshMode && settings.meshMode != .free {
                chip(settings.meshMode.rawValue, icon: settings.meshMode.icon, color: .purple)
            }
            if usesPhotos {
                chip("\(scanner.highResFrameCount)", icon: "photo.stack",
                     color: scanner.photoLimitReached ? .orange : .green)
            }
        }
        .padding(.horizontal, 20)
        }.fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
    }

    private func chip(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption2).fontWeight(.medium)
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.2)))
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        HStack(spacing: typeSize.isAccessibilitySize ? 8 : 28) {
            if scanner.isScanning {
                Button {
                    if scanner.isPaused { scanner.resumeScanning() } else { scanner.pauseScanning() }
                } label: {
                    controlLabel(scanner.isPaused ? "Resume" : "Pause",
                                 icon: scanner.isPaused ? "play.circle.fill" : "pause.circle.fill")
                }

                Button {
                    stopAndPrepareSave()
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle().fill(Color.red).frame(width: 64, height: 64)
                            RoundedRectangle(cornerRadius: 6).fill(Color.white).frame(width: 24, height: 24)
                        }
                        Text("Finish").font(.subheadline.weight(.semibold))
                    }
                    .foregroundColor(.white)
                }

                Button {
                    showingResetConfirmation = true
                } label: {
                    controlLabel("Reset", icon: "arrow.counterclockwise.circle.fill")
                }
            } else {
                Button {
                    guard activeDraft == nil else { showingSaveDialog = true; return }
                    captureLocation = nil
                    recoveredDraft = false
                    recoveredPoses = []
                    scanName = Scan.autoName()
                    scanner.startScanning(
                        captureTexture: settings.captureTexture,
                        meshMode: settings.meshMode,
                        rangeMeters: settings.rangeValue,
                        captureMode: settings.captureMode,
                        detailMM: settings.detailMM,
                        highResPhotos: settings.highResPhotos,
                        alignToNorth: settings.alignToNorth
                    )
                    guard scanner.isScanning else { return }
                    if settings.alignToNorth { location.requestFix() } else { location.stop() }
                    do {
                        activeDraft = try recovery.begin(name: scanName, settings: settings, photos: scanner.getCaptureFolderURL())
                    } catch {
                        scanner.pauseScanning()
                        errorMessage = "Could not start recovery storage. Capture paused: \(error.localizedDescription)"
                        showingError = true
                    }
                } label: {
                    HStack(spacing: 12) {
                        if !typeSize.isAccessibilitySize {
                        Image(systemName: activeDraft == nil ? "viewfinder" : "square.and.arrow.down")
                            .font(.title2)
                        }
                        Text(activeDraft == nil ? "Start scan" : "Review capture").font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        if !typeSize.isAccessibilitySize {
                        Spacer()
                        Image(systemName: "arrow.right").font(.body.weight(.semibold))
                        }
                    }
                    .foregroundStyle(FieldStyle.ink).padding(.horizontal, 22)
                    .frame(minHeight: 58).frame(maxWidth: .infinity)
                    .background(FieldStyle.mint, in: RoundedRectangle(cornerRadius: 19))
                }
            }
        }
        .disabled(scanner.isFinalizing || isPreparingMesh || isSaving)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .padding(.horizontal, AppConstants.Layout.padding)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Color.clear, Color.black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private func controlLabel(_ title: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 36))
            Text(title).font(.caption.weight(.medium))
        }
        .foregroundColor(.white)
        .frame(minWidth: 64, minHeight: 64)
    }

    // MARK: - LiDAR Unavailable

    #if !targetEnvironment(simulator)
    private var lidarUnavailableView: some View {
        VStack(spacing: 20) {
            Image(systemName: "sensor.fill")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            Text("LiDAR Not Available")
                .font(.title2)
                .fontWeight(.bold)
            Text("This device does not have a LiDAR sensor.\nLiDAR is available on iPhone 12 Pro and newer Pro models.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
    #endif

    // MARK: - Save Dialog

    private func stopAndPrepareSave(present: Bool = true) {
        guard !isPreparingMesh, !isSaving else { return }
        let token = UUID()
        preparationToken = token
        captureLocation = settings.alignToNorth ? location.finishCapture() : nil
        if scanName.isEmpty { scanName = Scan.autoName() }
        if selectedProject == nil {
            selectedProject = storageManager.projects.sorted(by: { $0.modifiedAt > $1.modifiedAt }).first
        }
        pendingMesh = nil
        isPreparingMesh = true
        showingSaveDialog = present
        scanner.stopScanning {
            scanner.buildCombinedMesh { mesh in
                guard preparationToken == token else { return }
                pendingMesh = mesh
                if var draft = activeDraft {
                    draft.name = scanName
                    draft.location = captureLocation
                    draft.checkpointAt = Date()
                    if mesh != nil { draft.geometryCheckpointAt = draft.checkpointAt }
                    draft.isFinalized = true
                    activeDraft = draft
                    recovery.checkpoint(draft, mesh: mesh) { result in
                        guard preparationToken == token else { return }
                        isPreparingMesh = false
                        endBackgroundCheckpoint()
                        if case .failure(let error) = result {
                            failSave("Checkpoint failed; capture remains in memory. \(error.localizedDescription)")
                        }
                    }
                } else {
                    isPreparingMesh = false
                    endBackgroundCheckpoint()
                }
            }
        }
    }

    /// High Quality needs photos; desktop Splat additionally needs a point cloud.
    private var hasSomethingToSave: Bool {
        switch settings.captureMode {
        case .highQuality: return photoCount > 0
        case .splatExport: return photoCount > 0 && !(pendingMesh?.vertices.isEmpty ?? true)
        default: return !(pendingMesh?.vertices.isEmpty ?? true)
        }
    }

    private var saveDialogSheet: some View {
        NavigationStack {
            Form {
                Section("Scan Name") {
                    TextField("Enter scan name", text: $scanName)
                        .textInputAutocapitalization(.words)
                }

                Section("Save to Project") {
                    if !storageManager.projects.isEmpty {
                        Picker("Project", selection: $selectedProject) {
                            Text("Select a project").tag(nil as Project?)
                            ForEach(storageManager.projects.sorted(by: { $0.modifiedAt > $1.modifiedAt })) { project in
                                Text("\(project.name) (\(project.scanCount))").tag(project as Project?)
                            }
                        }
                    }
                    Button("Create New Project") { showingNewProjectDialog = true }
                }

                switch settings.captureMode {
                case .highQuality:
                    Section {
                        Picker("Effort", selection: $settings.reconstructQuality) {
                            ForEach(ScanSettings.ReconstructQuality.allCases, id: \.self) { q in
                                Text(q.rawValue).tag(q)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(settings.reconstructQuality.description)
                            .font(.caption).foregroundColor(.secondary)
                    } header: {
                        Text("Photoreal Model")
                    } footer: {
                        Text("Builds a textured 3D model from your photos on the phone. This can take a few minutes.")
                    }
                case .pointCloud:
                    Section {
                        Label("Coloured point cloud (PLY)", systemImage: "aqi.medium")
                    } header: {
                        Text("Output")
                    } footer: {
                        Text(String(format: "Points are thinned to one per %.0f mm.", settings.detailMM))
                    }
                case .splatExport:
                    Section {
                        Label("Photos + camera positions + point cloud (.zip)", systemImage: "square.and.arrow.up.on.square")
                    } header: {
                        Text("Output")
                    } footer: {
                        Text("After saving you can send the .zip to your computer. You can also re-send it later from the scan's More menu.")
                    }
                case .fast:
                    Section {
                        Picker("Clean-up", selection: $processingLevel) {
                            ForEach(MeshProcessor.ProcessingLevel.allCases, id: \.self) { level in
                                Text(level.rawValue).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(processingLevel.description)
                            .font(.caption).foregroundColor(.secondary)
                        Picker("File type", selection: $exportFormat) {
                            Text("OBJ").tag(StorageManager.ExportFormat.obj)
                            Text("PLY").tag(StorageManager.ExportFormat.ply)
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Mesh")
                    } footer: {
                        Text(exportFormat == .obj
                             ? "OBJ keeps the photo texture. Works in most 3D and CAD apps."
                             : "PLY stores colour per point. Good for MeshLab and CloudCompare.")
                    }
                }

                Section("Scan Info") {
                    if isPreparingMesh {
                        HStack {
                            ProgressView().padding(.trailing, 8)
                            Text("Preparing scan…").foregroundColor(.secondary)
                        }
                    } else if let mesh = pendingMesh {
                        let unit = ScanSettings.MeasurementUnit.preferred
                        let dims = mesh.dimensions
                        LabeledContent("Size", value: "\(unit.format(meters: dims.x)) × \(unit.format(meters: dims.y)) × \(unit.format(meters: dims.z))")
                        LabeledContent("Points", value: mesh.vertexCount.formatted())
                        if mesh.faceCount > 0 {
                            LabeledContent("Triangles", value: mesh.faceCount.formatted())
                        }
                    } else if !usesPhotos {
                        Text("No scan data was captured. Move the phone slowly over surfaces, then try again.")
                            .foregroundColor(.secondary)
                    }
                    if usesPhotos {
                        LabeledContent("Photos", value: "\(photoCount)")
                        if settings.captureMode == .splatExport, pendingMesh?.vertices.isEmpty ?? true {
                            Text("Desktop export needs a point-cloud checkpoint. Your photos are preserved; use Keep for Later.")
                                .foregroundColor(.secondary)
                        }
                    } else if settings.captureTexture {
                        LabeledContent("Colour frames", value: "\(scanner.capturedFrameCount)")
                    }
                }

                if isSaving {
                    Section {
                        HStack {
                            ProgressView().padding(.trailing, 8)
                            Text(savingProgress.isEmpty ? "Saving..." : savingProgress)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .fieldScreen()
            .navigationTitle("Save capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingCancelOptions = true }
                        .disabled(isSaving || isPreparingMesh || scanner.isFinalizing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveScan() }
                        .disabled(scanName.isEmpty || selectedProject == nil || isSaving
                                  || isPreparingMesh || !hasSomethingToSave)
                }
            }
            .confirmationDialog("Not saving yet?", isPresented: $showingCancelOptions, titleVisibility: .visible) {
                if !recoveredDraft, !scanner.needsRecoveryCheckpoint {
                    Button("Continue Scanning") {
                        showingSaveDialog = false
                        pendingMesh = nil
                        scanner.continueScanning()
                        if settings.alignToNorth { location.requestFix() }
                    }
                }
                Button("Keep for Later") { keepForLater() }
                Button("Discard Scan", role: .destructive) {
                    discardCurrentCapture()
                }
                Button("Keep Editing", role: .cancel) {}
            }
            .alert("New Project", isPresented: $showingNewProjectDialog) {
                TextField("Project name", text: $newProjectName)
                Button("Create") {
                    if !newProjectName.isEmpty {
                        selectedProject = storageManager.createProject(name: newProjectName)
                        newProjectName = ""
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Recoverable captures

    private var capturePhotoFolder: URL? {
        if recoveredDraft, let draft = activeDraft { return recovery.photoFolder(for: draft) }
        return scanner.getCaptureFolderURL()
    }

    private var photoCount: Int { recoveredDraft ? recoveredPoses.count : scanner.highResFrameCount }

    private var recoverySheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("Recover the last completed checkpoint and saved photos. Recovery never resumes the old tracking session; finish saving, then start a new scan.")
                        .font(.callout)
                    if let warning = recovery.warning { Text(warning).foregroundStyle(.orange) }
                }
                ForEach(recovery.drafts) { draft in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(draft.name).font(.headline)
                        Text("Checkpoint: \(draft.checkpointAt.formatted())").font(.caption)
                        if let date = draft.geometryCheckpointAt {
                            Text("Geometry: \(date.formatted())").font(.caption)
                        } else { Text("No geometry checkpoint yet").font(.caption) }
                        Text(draft.settings.captureMode.rawValue).font(.caption)
                        HStack {
                            Button("Recover") { restoreDraft(draft) }
                            Spacer()
                            Button("Discard", role: .destructive) { draftToDiscard = draft }
                        }
                        .buttonStyle(.bordered)
                        .disabled(activeDraft != nil || isPreparingMesh)
                    }
                }
                if activeDraft != nil { Text("Finish or keep the current capture before opening another.") }
            }
            .navigationTitle("Unfinished captures")
            .fieldScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { showingRecovery = false } }
            .confirmationDialog("Permanently discard this unfinished capture?", isPresented: Binding(
                get: { draftToDiscard != nil }, set: { if !$0 { draftToDiscard = nil } }
            ), titleVisibility: .visible) {
                Button("Discard Capture", role: .destructive) {
                    if let draft = draftToDiscard { recovery.discard(draft) }
                    draftToDiscard = nil
                }
                Button("Cancel", role: .cancel) { draftToDiscard = nil }
            }
        }
    }

    private func restoreDraft(_ draft: CaptureDraft) {
        guard activeDraft == nil, !isPreparingMesh else { return }
        isPreparingMesh = true
        recovery.load(draft) { result in
            isPreparingMesh = false
            do {
                let (loaded, mesh) = try result.get()
                let poses = try recovery.photoFolder(for: loaded).map { try PoseFile.read(forPhotoFolder: $0) } ?? []
                activeDraft = loaded
                recoveredDraft = true
                recoveredPoses = poses
                captureLocation = loaded.location
                settings = loaded.settings
                scanName = loaded.name
                pendingMesh = mesh
                selectedProject = storageManager.projects.sorted { $0.modifiedAt > $1.modifiedAt }.first
                showingRecovery = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showingSaveDialog = true }
            } catch {
                failSave("Could not recover this checkpoint. Its files are preserved. \(error.localizedDescription)")
            }
        }
    }

    private func checkpointWhileCapturing() {
        guard scanner.isScanning, !scanner.isPaused, !scanner.isFinalizing,
              !checkpointInFlight, !isPreparingMesh, let current = activeDraft else { return }
        checkpointInFlight = true
        let token = preparationToken
        scanner.buildCombinedMesh { mesh in
            guard preparationToken == token, activeDraft?.id == current.id, scanner.isScanning else {
                checkpointInFlight = false
                return
            }
            var draft = current
            draft.checkpointAt = Date()
            if mesh != nil { draft.geometryCheckpointAt = draft.checkpointAt }
            draft.isFinalized = false
            draft.location = settings.alignToNorth ? location.currentFix() : nil
            activeDraft = draft
            recovery.checkpoint(draft, mesh: mesh) { result in
                checkpointInFlight = false
                if case .failure(let error) = result {
                    scanner.scanError = "Automatic checkpoint failed. Stop and save soon. \(error.localizedDescription)"
                }
            }
        }
    }

    private func suspendCapture() {
        guard scanner.isScanning, !isPreparingMesh, !isSaving else { return }
        scanner.needsRecoveryCheckpoint = true
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish scan checkpoint") {
                endBackgroundCheckpoint()
            }
        }
        stopAndPrepareSave(present: false)
    }

    private func endBackgroundCheckpoint() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func keepForLater() {
        guard var draft = activeDraft else {
            failSave("No durable checkpoint exists yet. Save the scan before leaving it.")
            return
        }
        isPreparingMesh = true
        draft.name = scanName
        draft.location = captureLocation
        draft.checkpointAt = Date()
        draft.isFinalized = true
        recovery.checkpoint(draft, mesh: pendingMesh) { result in
            isPreparingMesh = false
            switch result {
            case .success:
                preparationToken = UUID()
                scanner.resetScanning(keepPhotos: true)
                activeDraft = nil
                recoveredDraft = false
                recoveredPoses = []
                pendingMesh = nil
                showingSaveDialog = false
                location.stop()
            case .failure(let error): failSave("Could not keep capture: \(error.localizedDescription)")
            }
        }
    }

    private func completeRecovery() {
        preparationToken = UUID()
        if let draft = activeDraft {
            scanner.resetScanning(keepPhotos: true)
            recovery.discard(draft)
        }
        activeDraft = nil
        recoveredDraft = false
        recoveredPoses = []
        location.stop()
    }

    private func discardCurrentCapture() {
        preparationToken = UUID()
        isPreparingMesh = true
        scanner.stopScanning {
            completeRecovery()
            scanner.resetScanning()
            pendingMesh = nil
            showingSaveDialog = false
            isPreparingMesh = false
            endBackgroundCheckpoint()
        }
    }

    // MARK: - Actions

    private func saveScan() {
        guard let project = selectedProject else {
            errorMessage = "No project selected"
            showingError = true
            return
        }

        switch settings.captureMode {
        case .highQuality:
            guard highQualitySupported, let inputFolder = capturePhotoFolder else {
                failSave("Photo reconstruction is unavailable on this device, or its source folder is missing. The checkpoint has been kept.")
                return
            }
            #if !targetEnvironment(simulator)
            runPhotogrammetrySave(project: project, inputFolder: inputFolder)
            #endif
            break
        case .pointCloud:
            if let cloud = pendingMesh { savePointCloudFlow(project: project, cloud: cloud) }
        case .splatExport:
            if let folder = capturePhotoFolder { runSplatExport(project: project, folder: folder) }
        case .fast:
            saveMeshFlow(project: project)
        }
    }

    /// Hide the save sheet, record where/how the scan was aligned, open the
    /// saved scan, and get the camera ready again.
    private func finishSave(scan: Scan, project: Project, extra: ((inout Scan) -> Void)? = nil) {
        let north = settings.alignToNorth
        let fix = north ? captureLocation : nil
        let change: (inout Scan) -> Void = { s in
            s.recordLocation(fix, compassRequested: north)
            extra?(&s)
        }
        var updated = scan
        change(&updated)
        do { try storageManager.updateScan(scan.id, in: project, change) }
        catch {
            failSave("The model was saved, but its details could not be saved. Capture data is still available. \(error.localizedDescription)")
            return
        }

        isSaving = false
        savingProgress = ""
        showingSaveDialog = false
        pendingMesh = nil
        completeRecovery()
        scanner.resetScanning()
        scanner.startPreview()
        savedScan = updated
        savedProject = project
        showingSavedScan = true
    }

    private func failSave(_ message: String) {
        isSaving = false
        savingProgress = ""
        errorMessage = message
        showingError = true
    }

    private func saveMeshFlow(project: Project) {
        // Room Shell mode prefers clean detected planes; otherwise use the mesh.
        guard let rawMesh = (settings.meshMode == .area ? scanner.getPlaneBasedMeshData() : nil) ?? pendingMesh else {
            failSave("No scan data available")
            return
        }

        isSaving = true
        savingProgress = "Processing mesh..."
        let detailMeters = max(0.001, settings.detailMM / 1000.0)
        let wantColor = settings.captureTexture
        let level = processingLevel
        let format = exportFormat
        let name = scanName
        let north = settings.alignToNorth

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var meshData = MeshProcessor.postProcess(rawMesh, level: level)

                // DETAIL slider: simplify to about one vertex per chosen spacing, so
                // a coarse setting (e.g. 20 mm) gives a much lighter mesh.
                if detailMeters > 0.005 {
                    meshData = MeshProcessor.clusterVertices(meshData, cellSize: detailMeters)
                }
                if !wantColor {
                    meshData = MeshProcessor.makeUniformGrey(meshData)
                }

                var baked: BakedTexture?
                if format == .obj && wantColor {
                    DispatchQueue.main.async { self.savingProgress = "Baking texture..." }
                    baked = scanner.bakeTexture(meshData: meshData)
                }

                // Level and square up AFTER baking (baking needs the camera-space positions).
                let frame = SceneFrame.compute(from: meshData, keepHeading: north)
                meshData = meshData.transformed(by: frame)

                DispatchQueue.main.async { self.savingProgress = "Saving file..." }
                let scan = try storageManager.saveScan(meshData: meshData, name: name, toProject: project,
                                                       format: format, baked: baked)
                DispatchQueue.main.async { finishSave(scan: scan, project: project) { $0.recordCaptureFrame(frame) } }
            } catch {
                DispatchQueue.main.async { failSave("Failed to save: \(error.localizedDescription)") }
            }
        }
    }

    /// Splat (Desktop): write transforms.json + points3D.ply + README into the
    /// captured-photo folder, zip it, and present the share sheet for the computer.
    private func runSplatExport(project: Project, folder: URL) {
        let poses = recoveredDraft ? recoveredPoses : scanner.capturedPoses
        let fix = captureLocation
        guard !poses.isEmpty else {
            failSave("No photos captured. Move slowly around the subject, then save.")
            return
        }
        isSaving = true
        savingProgress = "Packaging for desktop…"
        guard let cloud = pendingMesh, !cloud.vertices.isEmpty else {
            failSave("No point cloud is available. Continue scanning before saving. Your photos have been kept.")
            return
        }
        let name = scanName
        let north = settings.alignToNorth

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Keep ARKit's frame in the bundle so geometry matches its poses.
                try SplatExporter.writeBundle(imageFolder: folder, poses: poses, pointCloud: cloud)
                guard let zipURL = SplatExporter.zip(folder: folder) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let frame = SceneFrame.compute(from: cloud, keepHeading: north)
                let levelled = cloud.transformed(by: frame)
                let record = try storageManager.savePointCloud(meshData: levelled, name: name, toProject: project, splatBundle: zipURL)
                try storageManager.updateScan(record.id, in: project) {
                    $0.recordLocation(fix, compassRequested: north)
                    $0.recordCaptureFrame(frame)
                }

                DispatchQueue.main.async {
                    isSaving = false
                    savingProgress = ""
                    showingSaveDialog = false
                    pendingMesh = nil
                    completeRecovery()
                    scanner.resetScanning()
                    scanner.startPreview()
                    // Let the sheet finish closing before presenting the share sheet.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        presentShareSheet(url: zipURL)
                    }
                }
            } catch {
                DispatchQueue.main.async { failSave("Could not save the splat bundle. Capture data has been kept. \(error.localizedDescription)") }
            }
        }
    }

    /// Present the iOS share sheet (AirDrop / Files / Mail / …) for a file.
    private func presentShareSheet(url: URL) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene.windows.first?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        activity.popoverPresentationController?.sourceView = top.view
        activity.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        top.present(activity, animated: true)
    }

    /// Save the scan's coloured world-space points as a point cloud.
    private func savePointCloudFlow(project: Project, cloud: MeshData) {
        isSaving = true
        savingProgress = "Saving point cloud…"
        let detailMeters = max(0.001, settings.detailMM / 1000.0)
        let grey = !settings.captureTexture
        let name = scanName
        let north = settings.alignToNorth
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var points = MeshProcessor.voxelDownsamplePoints(cloud, leafSize: detailMeters)
                if grey { points = MeshProcessor.makeUniformGrey(points) }
                let frame = SceneFrame.compute(from: points, keepHeading: north)
                points = points.transformed(by: frame)
                let scan = try storageManager.savePointCloud(meshData: points, name: name, toProject: project)
                DispatchQueue.main.async { finishSave(scan: scan, project: project) { $0.recordCaptureFrame(frame) } }
            } catch {
                DispatchQueue.main.async { failSave("Failed to save point cloud: \(error.localizedDescription)") }
            }
        }
    }

    #if !targetEnvironment(simulator)
    /// Run on-device photogrammetry on the captured photos, then save the USDZ.
    private func runPhotogrammetrySave(project: Project, inputFolder: URL) {
        isSaving = true
        savingProgress = "Reconstructing… 0%"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).usdz")
        // Metric reference from the LiDAR mesh captured in the same session.
        let lidarMesh = pendingMesh
        let lidarExtent = ScannerView.metricExtent(of: lidarMesh)
        let quality: PhotogrammetryProcessor.Quality = settings.reconstructQuality == .draft ? .draft : .best
        let name = scanName
        let north = settings.alignToNorth

        Task {
            do {
                let photoPositions = try await PhotogrammetryProcessor.reconstruct(
                    inputFolder: inputFolder,
                    outputUSDZ: outputURL,
                    quality: quality
                ) { fraction in
                    DispatchQueue.main.async {
                        self.savingProgress = "Reconstructing… \(Int(fraction * 100))%"
                    }
                }

                let alignment = ScannerView.alignmentTransform(
                    photoPositions: photoPositions,
                    arkitPositions: PoseFile.cameraPositions(forPhotoFolder: inputFolder),
                    modelURL: outputURL, lidarExtent: lidarExtent)
                // When aligned to ARKit's world, also level/square it like other scans.
                var transform = alignment?.transform
                var frame: simd_float4x4?
                if let a = alignment, a.poseBased, let lidar = lidarMesh {
                    let f = SceneFrame.compute(from: lidar, keepHeading: north)
                    frame = f
                    transform = f * a.transform
                }
                let scan = try storageManager.importProcessedModel(
                    modelURL: outputURL,
                    name: name,
                    toProject: project,
                    modelTransform: transform,
                    photosFolder: inputFolder
                )
                try? FileManager.default.removeItem(at: outputURL)
                let sceneFrame = frame.map(StorageManager.array(of:))
                DispatchQueue.main.async {
                    finishSave(scan: scan, project: project) { s in
                        s.sceneFrame = sceneFrame
                        s.coordinateProvenance = ScannerView.photoProvenance(alignment, frame: frame)
                    }
                }
            } catch {
                DispatchQueue.main.async { failSave(PhotogrammetryProcessor.friendlyMessage(for: error)) }
            }
        }
    }
    #endif
}

// MARK: - Photogrammetry Metric Scale

extension ScannerView {
    struct PhotoAlignment {
        let transform: simd_float4x4
        let poseBased: Bool
        let rms: Float?
        let cameraCount: Int
    }

    static func photoProvenance(_ alignment: PhotoAlignment?, frame: simd_float4x4?) -> CoordinateProvenance {
        let poseBased = alignment?.poseBased == true
        return CoordinateProvenance(sourceKind: "photogrammetry",
            scaleStatus: poseBased ? .cameraPoseAligned : (alignment == nil ? .unknown : .estimatedFromBounds),
            alignmentMethod: poseBased ? "camera similarity fit" : (alignment == nil ? "none" : "bounding-box size estimate"),
            alignmentRMSErrorMetres: alignment?.rms.map(Double.init), matchedCameraCount: alignment?.cameraCount,
            captureToLocal: poseBased ? StorageManager.array(of: frame ?? matrix_identity_float4x4).map(Double.init) : nil,
            localDatum: poseBased && frame != nil ? "Local levelled low surface; not a surveyed elevation datum" : "Capture/model-local origin; not a surveyed elevation datum")
    }
    /// Diagonal length (metres) of a LiDAR mesh's bounding box, or nil if unusable.
    static func metricExtent(of mesh: MeshData?) -> Float? {
        guard let mesh = mesh, mesh.vertexCount > 0 else { return nil }
        let d = length(mesh.boundingBoxMax - mesh.boundingBoxMin)
        return (d.isFinite && d > 0.01) ? d : nil
    }

    /// Diagonal (m) of a model file's bounding box.
    static func modelDiagonal(_ url: URL) -> Float? {
        guard let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) else { return nil }
        let (mn, mx) = scene.rootNode.flattenedClone().boundingBox
        let d = simd_distance(SIMD3<Float>(Float(mn.x), Float(mn.y), Float(mn.z)),
                              SIMD3<Float>(Float(mx.x), Float(mx.y), Float(mx.z)))
        return d.isFinite && d > 0.0001 ? d : nil
    }

    /// Uniform scale that makes a photogrammetry model match the LiDAR size
    /// (fallback when camera poses can't be used).
    static func metricScale(forModel url: URL, lidarExtent: Float?) -> Float? {
        guard let lidar = lidarExtent, let modelDiag = modelDiagonal(url) else { return nil }
        let s = lidar / modelDiag
        return (s > 0.02 && s < 50) ? s : nil
    }

    /// Transform that puts a photogrammetry model into the scan's real-world
    /// space. Best case: match the camera positions Apple's reconstruction
    /// estimated to the positions ARKit measured for the same photos. That gives
    /// true metric scale, gravity-up and the same placement as the LiDAR scan.
    /// Falls back to a size-only correction if that isn't reliable.
    static func alignmentTransform(photoPositions: [Int: SIMD3<Float>], arkitPositions: [Int: SIMD3<Float>],
                                   modelURL: URL, lidarExtent: Float?) -> PhotoAlignment? {
        let ids = photoPositions.keys.filter { arkitPositions[$0] != nil }.sorted()
        if ids.count >= 6 {
            var src = ids.compactMap { photoPositions[$0] }
            var dst = ids.compactMap { arkitPositions[$0] }
            var fit = GeometryMath.similarity(from: src, to: dst)
            // Drop the worst 20 % of cameras (odd estimates) and refit.
            if let f = fit, src.count >= 10 {
                let residuals = zip(src, dst).map { s, d -> Float in
                    let w = f.transform * SIMD4<Float>(s.x, s.y, s.z, 1)
                    return simd_distance(SIMD3<Float>(w.x, w.y, w.z), d)
                }
                let cutoff = residuals.sorted()[Int(Double(residuals.count) * 0.8)]
                let keep = residuals.indices.filter { residuals[$0] <= cutoff }
                src = keep.map { src[$0] }
                dst = keep.map { dst[$0] }
                fit = GeometryMath.similarity(from: src, to: dst) ?? fit
            }
            if let f = fit {
                let centre = dst.reduce(SIMD3<Float>(0, 0, 0), +) / Float(dst.count)
                let spread = (dst.map { simd_distance_squared($0, centre) }.reduce(0, +) / Float(dst.count)).squareRoot()
                var sane = spread > 0.15 && f.rms < max(0.05, spread * 0.15) && f.scale > 0.01 && f.scale < 100
                if sane, let lidar = lidarExtent, let diag = modelDiagonal(modelURL) {
                    let ratio = diag * f.scale / lidar
                    sane = ratio > 0.5 && ratio < 2.0
                }
                if sane {
                    DebugLogger.shared.info("HQ model aligned by \(src.count) cameras, scale \(f.scale), rms \(f.rms) m", category: "Photogrammetry")
                    return PhotoAlignment(transform: f.transform, poseBased: true, rms: f.rms, cameraCount: src.count)
                }
                DebugLogger.shared.warn("Pose alignment rejected (spread \(spread), rms \(f.rms)); using size match", category: "Photogrammetry")
            }
        }
        if let s = metricScale(forModel: modelURL, lidarExtent: lidarExtent) {
            return PhotoAlignment(transform: simd_float4x4(diagonal: SIMD4<Float>(s, s, s, 1)), poseBased: false, rms: nil, cameraCount: 0)
        }
        return nil
    }
}

// MARK: - Simulator Scan View

#if targetEnvironment(simulator)

struct SimulatorScanView: View {
    @ObservedObject var scanner: MockLiDARScanner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var heightClass
    @State private var animationPhase: Double = 0

    var body: some View {
        ZStack {
            Color(uiColor: UIColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1.0))

            if scanner.isScanning {
                scanningAnimation
            } else if scanner.vertexCount > 0 {
                completionView
            } else if !typeSize.isAccessibilitySize && heightClass != .compact {
                idleView
            }
        }
        .onAppear {
            if !reduceMotion {
                withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) { animationPhase = 1 }
            }
        }
    }

    private var scanningAnimation: some View {
        ZStack {
            GeometryReader { geo in
                Canvas { context, size in
                    let gridSpacing: CGFloat = 30
                    let offset = CGFloat(animationPhase) * gridSpacing

                    for y in stride(from: -gridSpacing + offset.truncatingRemainder(dividingBy: gridSpacing), through: size.height, by: gridSpacing) {
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(path, with: .color(.cyan.opacity(0.15)), lineWidth: 0.5)
                    }

                    for x in stride(from: 0, through: size.width, by: gridSpacing) {
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(path, with: .color(.cyan.opacity(0.15)), lineWidth: 0.5)
                    }

                    let sweepY = CGFloat(animationPhase) * size.height
                    var sweepPath = Path()
                    sweepPath.move(to: CGPoint(x: 0, y: sweepY))
                    sweepPath.addLine(to: CGPoint(x: size.width, y: sweepY))
                    context.stroke(sweepPath, with: .color(.cyan.opacity(0.6)), lineWidth: 2)
                }
            }

            VStack(spacing: 8) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 80))
                    .foregroundColor(.cyan.opacity(0.5))

                Text("Simulated LiDAR Scan")
                    .font(.caption)
                    .foregroundColor(.cyan.opacity(0.7))
            }
        }
    }

    private var completionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("Scan Complete")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            Text("\(scanner.vertexCount.formatted()) vertices captured")
                .font(.subheadline)
                .foregroundColor(.gray)
        }
    }

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sensor.fill")
                .font(.system(size: 50))
                .foregroundColor(.cyan.opacity(0.5))

            Text("Camera preview")
                .font(.headline)
                .foregroundColor(.white)

            Text("Simulator · sample capture")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 200)
    }
}

#endif
