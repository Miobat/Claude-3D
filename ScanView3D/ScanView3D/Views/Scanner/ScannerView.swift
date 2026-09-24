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

            VStack(spacing: 0) {
                topStatusBar
                if scanner.isScanning, let warning = scanner.trackingWarning {
                    trackingBanner(warning)
                }
                Spacer()
                if scanner.isScanning {
                    scanCapacityGauge
                    scanningInfoBar
                } else {
                    prescanControls
                }
                bottomControls
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
        }
        .onDisappear {
            scanner.stopPreview()
        }
        .onChange(of: settings) { _, newValue in
            newValue.save()
        }
        .sheet(isPresented: $showingSaveDialog) {
            saveDialogSheet
                .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $showingSavedScan) {
            if let scan = savedScan, let project = savedProject {
                NavigationView {
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

    // MARK: - Top Status Bar

    private var topStatusBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(scanner.scanProgress)
                    .font(.caption)
                    .fontWeight(.medium)

                if scanner.isScanning {
                    HStack(spacing: 12) {
                        if scanner.depthPointCount > 0 {
                            Label("\(scanner.depthPointCount.formatted()) pts", systemImage: "aqi.medium")
                        } else {
                            Label("\(scanner.vertexCount.formatted())", systemImage: "circle.fill")
                            Label("\(scanner.faceCount.formatted())", systemImage: "triangle.fill")
                        }
                        if usesPhotos {
                            Label("\(scanner.highResFrameCount) photos", systemImage: "photo.stack")
                        } else if scanner.capturedFrameCount > 0 {
                            Label("\(scanner.capturedFrameCount)", systemImage: "camera.fill")
                        }
                    }
                    .font(.caption2)
                }
            }
            .foregroundColor(.white)

            Spacer()

            #if targetEnvironment(simulator)
            Text("SIMULATOR")
                .font(.caption2)
                .fontWeight(.bold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange)
                .cornerRadius(4)
                .foregroundColor(.white)
            #else
            if scanner.isScanning {
                Button {
                    showMeshOverlay.toggle()
                } label: {
                    Image(systemName: showMeshOverlay ? "square.grid.3x3.fill" : "square.grid.3x3")
                        .foregroundColor(.white)
                        .padding(8)
                }
                .accessibilityLabel(showMeshOverlay ? "Hide mesh overlay" : "Show mesh overlay")
            }
            #endif
        }
        .padding(.horizontal, AppConstants.Layout.padding)
        .padding(.top, 8)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.6), Color.clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
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
            .font(.system(size: 9))
            .foregroundColor(.gray)
        }
        .padding(.horizontal, AppConstants.Layout.padding)
        .padding(.bottom, 4)
    }

    private var capacityColor: Color {
        if scanner.scanCapacityPercent > 80 { return .red }
        if scanner.scanCapacityPercent > 60 { return .orange }
        return .green
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
        VStack(spacing: 12) {
            // 1. Mode
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ForEach(ScanSettings.CaptureMode.allCases, id: \.self) { mode in
                        let disabled = (mode == .highQuality && !highQualitySupported)
                        let selected = settings.captureMode == mode
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { settings.captureMode = mode }
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: mode.icon).font(.system(size: 16))
                                Text(mode.shortName).font(.system(size: 11, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(selected ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.1)))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
                            .opacity(disabled ? 0.4 : 1.0)
                        }
                        .disabled(disabled)
                        .foregroundColor(selected ? .white : .gray)
                    }
                }
                Text(settings.captureMode.description)
                    .font(.caption2).foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 2. Range
            sliderRow(title: "Range", value: String(format: "%.1f m", settings.rangeValue),
                      hint: "Only keeps surfaces within this distance of where you walk.") {
                Slider(value: $settings.rangeValue, in: 0.3...5.0, step: 0.1)
            }

            // 3. Detail (Fast / Point Cloud)
            if settings.captureMode.usesDetail {
                sliderRow(title: "Detail", value: String(format: "%.0f mm", settings.detailMM),
                          hint: "Smaller = finer and bigger files. 20 mm is good for large areas.") {
                    Slider(value: $settings.detailMM, in: 5...20, step: 1)
                }
            }

            // 4. Mesh filter (Fast)
            if settings.captureMode.usesMeshMode {
                VStack(spacing: 4) {
                    Picker("Keep", selection: $settings.meshMode) {
                        ForEach(ScanSettings.MeshMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(settings.meshMode.description)
                        .font(.caption2).foregroundColor(.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // 5. Photo resolution (High Quality / Splat)
            if settings.captureMode.usesPhotos {
                Toggle(isOn: $settings.highResPhotos) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(settings.highResPhotos ? "12 MP photos" : "Standard photos")
                            .font(.caption).foregroundColor(.white)
                        Text(settings.highResPhotos
                             ? "Sharpest detail. Uses about 1 GB of storage per scan."
                             : "1920×1440 photos. Faster and smaller.")
                            .font(.caption2).foregroundColor(.gray)
                    }
                }
                .tint(.green)
            }

            // 6. Colour (Fast / Point Cloud)
            if settings.captureMode.usesColorToggle {
                Toggle(isOn: $settings.captureTexture) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(settings.captureTexture ? "Photo colour" : "No colour (grey)")
                            .font(.caption).foregroundColor(.white)
                        Text(settings.captureTexture
                             ? "Colours the scan from the camera."
                             : "Clean grey model for measuring and CAD. Faster.")
                            .font(.caption2).foregroundColor(.gray)
                    }
                }
                .tint(.green)
            }
        }
        .padding(.horizontal, AppConstants.Layout.padding)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.75)))
        .padding(.horizontal, 12)
    }

    private func sliderRow<S: View>(title: String, value: String, hint: String,
                                    @ViewBuilder slider: () -> S) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.caption).fontWeight(.semibold).foregroundColor(.white)
                Spacer()
                Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(.white)
            }
            slider()
            Text(hint)
                .font(.caption2).foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Scanning Info Bar

    private var scanningInfoBar: some View {
        HStack(spacing: 10) {
            chip(settings.captureMode.shortName, icon: settings.captureMode.icon, color: .accentColor)
            chip(String(format: "%.1f m", settings.rangeValue), icon: "scope", color: .cyan)
            if settings.captureMode.usesMeshMode && settings.meshMode != .free {
                chip(settings.meshMode.rawValue, icon: settings.meshMode.icon, color: .purple)
            }
            if usesPhotos {
                chip("\(scanner.highResFrameCount)", icon: "photo.stack",
                     color: scanner.photoLimitReached ? .orange : .green)
            }
        }
        .padding(.bottom, 8)
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
        HStack(spacing: 40) {
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
                        Text("Stop").font(.caption2)
                    }
                    .foregroundColor(.white)
                }

                Button {
                    scanner.resetScanning()
                    scanner.startPreview()
                } label: {
                    controlLabel("Reset", icon: "arrow.counterclockwise.circle.fill")
                }
            } else {
                Button {
                    scanner.startScanning(
                        captureTexture: settings.captureTexture,
                        meshMode: settings.meshMode,
                        rangeMeters: settings.rangeValue,
                        captureMode: settings.captureMode,
                        detailMM: settings.detailMM,
                        highResPhotos: settings.highResPhotos
                    )
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle().strokeBorder(Color.white, lineWidth: 4).frame(width: 64, height: 64)
                            Circle().fill(Color.red).frame(width: 52, height: 52)
                        }
                        Text("Start Scan").font(.caption2)
                    }
                    .foregroundColor(.white)
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 30)
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
            Text(title).font(.caption2)
        }
        .foregroundColor(.white)
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

    private func stopAndPrepareSave() {
        scanner.stopScanning()
        scanName = Scan.autoName()
        if selectedProject == nil {
            selectedProject = storageManager.projects.sorted(by: { $0.modifiedAt > $1.modifiedAt }).first
        }
        pendingMesh = nil
        isPreparingMesh = true
        showingSaveDialog = true
        scanner.buildCombinedMesh { mesh in
            pendingMesh = mesh
            isPreparingMesh = false
        }
    }

    /// Photos are enough on their own for High Quality / Splat; the others need geometry.
    private var hasSomethingToSave: Bool {
        usesPhotos ? scanner.highResFrameCount > 0 : pendingMesh != nil
    }

    private var saveDialogSheet: some View {
        NavigationView {
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
                        LabeledContent("Photos", value: "\(scanner.highResFrameCount)")
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
            .navigationTitle("Save Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingCancelOptions = true }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveScan() }
                        .disabled(scanName.isEmpty || selectedProject == nil || isSaving
                                  || isPreparingMesh || !hasSomethingToSave)
                }
            }
            .confirmationDialog("Not saving yet?", isPresented: $showingCancelOptions, titleVisibility: .visible) {
                Button("Continue Scanning") {
                    showingSaveDialog = false
                    pendingMesh = nil
                    scanner.continueScanning()
                }
                Button("Discard Scan", role: .destructive) {
                    showingSaveDialog = false
                    pendingMesh = nil
                    scanner.resetScanning()
                    scanner.startPreview()
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

    // MARK: - Actions

    private func saveScan() {
        guard let project = selectedProject else {
            errorMessage = "No project selected"
            showingError = true
            return
        }

        switch settings.captureMode {
        case .highQuality:
            #if !targetEnvironment(simulator)
            if let inputFolder = scanner.getPhotogrammetryInputURL(), PhotogrammetryProcessor.isSupported {
                runPhotogrammetrySave(project: project, inputFolder: inputFolder)
            }
            #endif
            break
        case .pointCloud:
            if let cloud = pendingMesh { savePointCloudFlow(project: project, cloud: cloud) }
        case .splatExport:
            if let folder = scanner.getCaptureFolderURL() { runSplatExport(project: project, folder: folder) }
        case .fast:
            saveMeshFlow(project: project)
        }
    }

    /// Hide the save sheet, open the saved scan, and get the camera ready again.
    private func finishSave(scan: Scan, project: Project) {
        isSaving = false
        savingProgress = ""
        showingSaveDialog = false
        pendingMesh = nil
        scanner.resetScanning()
        scanner.startPreview()
        savedScan = scan
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

                DispatchQueue.main.async { self.savingProgress = "Saving file..." }
                let scan = try storageManager.saveScan(meshData: meshData, name: name, toProject: project,
                                                       format: format, baked: baked)
                DispatchQueue.main.async { finishSave(scan: scan, project: project) }
            } catch {
                DispatchQueue.main.async { failSave("Failed to save: \(error.localizedDescription)") }
            }
        }
    }

    /// Splat (Desktop): write transforms.json + points3D.ply + README into the
    /// captured-photo folder, zip it, and present the share sheet for the computer.
    private func runSplatExport(project: Project, folder: URL) {
        let poses = scanner.capturedPoses
        guard !poses.isEmpty else {
            failSave("No photos captured. Move slowly around the subject, then save.")
            return
        }
        isSaving = true
        savingProgress = "Packaging for desktop…"
        let cloud = pendingMesh
        let name = scanName

        DispatchQueue.global(qos: .userInitiated).async {
            SplatExporter.writeBundle(imageFolder: folder, poses: poses, pointCloud: cloud)
            let zipURL = SplatExporter.zip(folder: folder)

            // Keep an in-app record so the scan shows up in Projects, with the zip
            // stored next to it so it can be re-sent later.
            let record = cloud.flatMap { try? storageManager.savePointCloud(meshData: $0, name: name, toProject: project) }
            if let zipURL = zipURL, let record = record {
                storageManager.attachSplatBundle(zipURL: zipURL, toScan: record.id, in: project)
            }

            DispatchQueue.main.async {
                isSaving = false
                savingProgress = ""
                showingSaveDialog = false
                pendingMesh = nil
                scanner.resetScanning()
                scanner.startPreview()
                if let zipURL = zipURL {
                    // Let the sheet finish closing before presenting the share sheet.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        presentShareSheet(url: zipURL)
                    }
                } else {
                    errorMessage = "Could not package the splat bundle."
                    showingError = true
                }
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
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var points = MeshProcessor.voxelDownsamplePoints(cloud, leafSize: detailMeters)
                if grey { points = MeshProcessor.makeUniformGrey(points) }
                let scan = try storageManager.savePointCloud(meshData: points, name: name, toProject: project)
                DispatchQueue.main.async { finishSave(scan: scan, project: project) }
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
        let lidarExtent = ScannerView.metricExtent(of: pendingMesh)
        let quality: PhotogrammetryProcessor.Quality = settings.reconstructQuality == .draft ? .draft : .best
        let name = scanName

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

                let transform = ScannerView.alignmentTransform(
                    photoPositions: photoPositions,
                    arkitPositions: PoseFile.cameraPositions(forPhotoFolder: inputFolder),
                    modelURL: outputURL, lidarExtent: lidarExtent)
                let scan = try storageManager.importProcessedModel(
                    modelURL: outputURL,
                    name: name,
                    toProject: project,
                    modelTransform: transform,
                    photosFolder: inputFolder
                )
                try? FileManager.default.removeItem(at: outputURL)
                DispatchQueue.main.async { finishSave(scan: scan, project: project) }
            } catch {
                DispatchQueue.main.async { failSave(PhotogrammetryProcessor.friendlyMessage(for: error)) }
            }
        }
    }
    #endif
}

// MARK: - Photogrammetry Metric Scale

extension ScannerView {
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
                                   modelURL: URL, lidarExtent: Float?) -> simd_float4x4? {
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
                    return f.transform
                }
                DebugLogger.shared.warn("Pose alignment rejected (spread \(spread), rms \(f.rms)); using size match", category: "Photogrammetry")
            }
        }
        if let s = metricScale(forModel: modelURL, lidarExtent: lidarExtent) {
            return simd_float4x4(diagonal: SIMD4<Float>(s, s, s, 1))
        }
        return nil
    }
}

// MARK: - Simulator Scan View

#if targetEnvironment(simulator)

struct SimulatorScanView: View {
    @ObservedObject var scanner: MockLiDARScanner
    @State private var animationPhase: Double = 0

    var body: some View {
        ZStack {
            Color(uiColor: UIColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1.0))

            if scanner.isScanning {
                scanningAnimation
            } else if scanner.vertexCount > 0 {
                completionView
            } else {
                idleView
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                animationPhase = 1
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

            Text("Simulator Mode")
                .font(.headline)
                .foregroundColor(.white)

            Text("Tap Start Scan to generate\na sample room mesh")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
    }
}

#endif
