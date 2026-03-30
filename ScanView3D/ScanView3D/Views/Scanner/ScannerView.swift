import SwiftUI
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
    @State private var showingSaveDialog = false
    @State private var scanName = ""
    @State private var selectedProject: Project?
    @State private var showingNewProjectDialog = false
    @State private var newProjectName = ""
    @State private var showingSettings = false
    @State private var showingExportOptions = false
    @State private var settings = ScanSettings()
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var isSaving = false
    @State private var showMeshOverlay = true
    @State private var exportFormat: StorageManager.ExportFormat = .obj
    @State private var processingLevel: MeshProcessor.ProcessingLevel = .standard
    @State private var savingProgress = ""

    var body: some View {
        ZStack {
            #if targetEnvironment(simulator)
            SimulatorScanView(scanner: scanner)
                .ignoresSafeArea()
            #else
            // AR Camera View - always shown for preview
            ARScannerViewRepresentable(scanner: scanner, showMeshOverlay: $showMeshOverlay)
                .ignoresSafeArea()
            #endif

            // Scanning overlay UI
            VStack(spacing: 0) {
                topStatusBar

                Spacer()

                // Memory/capacity gauge during scanning
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
            // Start camera preview immediately so user sees the camera feed
            #if !targetEnvironment(simulator)
            scanner.startPreview()
            #endif
        }
        .onDisappear {
            #if !targetEnvironment(simulator)
            scanner.stopPreview()
            #endif
        }
        .sheet(isPresented: $showingSaveDialog) {
            saveDialogSheet
        }
        .sheet(isPresented: $showingSettings) {
            settingsSheet
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
                        Label("\(scanner.vertexCount.formatted())", systemImage: "circle.fill")
                            .font(.caption2)
                        Label("\(scanner.faceCount.formatted())", systemImage: "triangle.fill")
                            .font(.caption2)
                        if scanner.capturedFrameCount > 0 {
                            Label("\(scanner.capturedFrameCount)", systemImage: "camera.fill")
                                .font(.caption2)
                        }
                        if scanner.detectedPlaneCount > 0 {
                            Label("\(scanner.detectedPlaneCount)", systemImage: "square.stack.3d.up")
                                .font(.caption2)
                        }
                    }
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
            #endif

            if scanner.isScanning {
                #if !targetEnvironment(simulator)
                Button {
                    showMeshOverlay.toggle()
                } label: {
                    Image(systemName: showMeshOverlay ? "square.grid.3x3.fill" : "square.grid.3x3")
                        .foregroundColor(.white)
                        .padding(8)
                }
                #endif

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(.white)
                        .padding(8)
                }
            }
        }
        .padding(.horizontal, AppConstants.Layout.padding)
        .padding(.top, 8)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.6), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    // MARK: - Scan Capacity Gauge

    private var scanCapacityGauge: some View {
        VStack(spacing: 4) {
            // Progress bar
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
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                Spacer()
                if scanner.scanCapacityPercent > 80 {
                    Text("Memory pressure high")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                } else {
                    Text(String(format: "%.0f%% capacity", scanner.scanCapacityPercent))
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                }
            }
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

    private var prescanControls: some View {
        VStack(spacing: 10) {
            // Range slider (continuous)
            VStack(spacing: 4) {
                HStack {
                    Text("RANGE")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.cyan)
                    Spacer()
                    Text(String(format: "%.1f m", settings.rangeValue))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.cyan)
                }
                Slider(value: $settings.rangeValue, in: 0.3...5.0, step: 0.1)
                    .tint(.cyan)
            }

            // Confidence selector
            VStack(spacing: 4) {
                HStack {
                    Text("CONFIDENCE")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                    Spacer()
                }
                Picker("", selection: $settings.confidenceLevel) {
                    Text("Low").tag(0)
                    Text("Medium").tag(1)
                    Text("High").tag(2)
                }
                .pickerStyle(.segmented)
            }

            // Mesh mode
            VStack(spacing: 4) {
                HStack {
                    Text("MESH MODE")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.purple)
                    Spacer()
                }
                HStack(spacing: 6) {
                    ForEach(ScanSettings.MeshMode.allCases, id: \.self) { mode in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                settings.meshMode = mode
                            }
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: mode.icon)
                                    .font(.system(size: 14))
                                Text(mode.rawValue)
                                    .font(.system(size: 8, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(settings.meshMode == mode ? Color.purple.opacity(0.3) : Color.white.opacity(0.1))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(settings.meshMode == mode ? Color.purple : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .foregroundColor(settings.meshMode == mode ? .white : .gray)
                    }
                }
            }

            // Photo texture toggle
            HStack {
                Image(systemName: "camera.fill")
                    .foregroundColor(settings.captureTexture ? .green : .gray)
                    .font(.caption)
                Text("Photo Texture")
                    .font(.caption)
                    .foregroundColor(.white)
                Spacer()
                Toggle("", isOn: $settings.captureTexture)
                    .labelsHidden()
                    .tint(.green)
            }
        }
        .padding(.horizontal, AppConstants.Layout.padding)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.75))
        )
        .padding(.horizontal, 12)
    }

    // MARK: - Scanning Info Bar

    private var scanningInfoBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Image(systemName: "scope")
                    .font(.caption2)
                Text(String(format: "%.1fm", settings.rangeValue))
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .foregroundColor(.cyan)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.cyan.opacity(0.2)))

            HStack(spacing: 4) {
                Image(systemName: settings.scanQuality.icon)
                    .font(.caption2)
                Text(settings.scanQuality.rawValue)
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .foregroundColor(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.orange.opacity(0.2)))

            // Mesh mode badge (only show if not Free)
            if settings.meshMode != .free {
                HStack(spacing: 4) {
                    Image(systemName: settings.meshMode.icon)
                        .font(.caption2)
                    Text(settings.meshMode.rawValue)
                        .font(.caption2)
                        .fontWeight(.medium)
                }
                .foregroundColor(.purple)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.purple.opacity(0.2)))
            }

            if settings.captureTexture {
                HStack(spacing: 4) {
                    Image(systemName: "camera.fill")
                        .font(.caption2)
                    Text("\(scanner.capturedFrameCount)")
                        .font(.caption2)
                        .fontWeight(.medium)
                }
                .foregroundColor(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.green.opacity(0.2)))
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 40) {
                if scanner.isScanning {
                    Button {
                        if scanner.isPaused {
                            scanner.resumeScanning()
                        } else {
                            scanner.pauseScanning()
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: scanner.isPaused ? "play.circle.fill" : "pause.circle.fill")
                                .font(.system(size: 36))
                            Text(scanner.isPaused ? "Resume" : "Pause")
                                .font(.caption2)
                        }
                        .foregroundColor(.white)
                    }

                    Button {
                        scanner.stopScanning()
                        scanName = Scan.autoName()
                        if selectedProject == nil {
                            selectedProject = storageManager.projects
                                .sorted(by: { $0.modifiedAt > $1.modifiedAt })
                                .first
                        }
                        showingSaveDialog = true
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 64, height: 64)
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.white)
                                    .frame(width: 24, height: 24)
                            }
                            Text("Stop")
                                .font(.caption2)
                        }
                        .foregroundColor(.white)
                    }

                    Button {
                        scanner.resetScanning()
                        // Restart preview after reset
                        #if !targetEnvironment(simulator)
                        scanner.startPreview()
                        #endif
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                                .font(.system(size: 36))
                            Text("Reset")
                                .font(.caption2)
                        }
                        .foregroundColor(.white)
                    }
                } else {
                    Button {
                        scanner.startScanning(
                            detail: settings.meshDetail,
                            captureTexture: settings.captureTexture,
                            range: settings.scanRange,
                            quality: settings.scanQuality,
                            meshMode: settings.meshMode,
                            rangeMeters: settings.rangeValue,
                            confidenceLevel: settings.confidenceLevel
                        )
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Circle()
                                    .strokeBorder(Color.white, lineWidth: 4)
                                    .frame(width: 64, height: 64)
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 52, height: 52)
                            }
                            Text("Start Scan")
                                .font(.caption2)
                        }
                        .foregroundColor(.white)
                    }
                }
            }
        }
        .padding(.bottom, 30)
        .padding(.horizontal, AppConstants.Layout.padding)
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
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

    private var saveDialogSheet: some View {
        NavigationView {
            Form {
                Section("Scan Name") {
                    TextField("Enter scan name", text: $scanName)
                        .textInputAutocapitalization(.words)
                }

                Section("Save to Project") {
                    if storageManager.projects.isEmpty {
                        Button("Create New Project") {
                            showingNewProjectDialog = true
                        }
                    } else {
                        Picker("Project", selection: $selectedProject) {
                            Text("Select a project").tag(nil as Project?)
                            ForEach(storageManager.projects.sorted(by: { $0.modifiedAt > $1.modifiedAt })) { project in
                                HStack {
                                    Text(project.name)
                                    Text("(\(project.scanCount) scans)")
                                        .foregroundColor(.secondary)
                                }
                                .tag(project as Project?)
                            }
                        }

                        Button("Create New Project") {
                            showingNewProjectDialog = true
                        }
                    }
                }

                Section("Post-Processing") {
                    Picker("Quality", selection: $processingLevel) {
                        Text("Quick").tag(MeshProcessor.ProcessingLevel.quick)
                        Text("Standard").tag(MeshProcessor.ProcessingLevel.standard)
                        Text("High").tag(MeshProcessor.ProcessingLevel.high)
                        Text("Fusion").tag(MeshProcessor.ProcessingLevel.fusion)
                    }

                    Text(processingLevel.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Export Format") {
                    Picker("Format", selection: $exportFormat) {
                        Text("OBJ (Standard)").tag(StorageManager.ExportFormat.obj)
                        Text("PLY (Vertex Colors)").tag(StorageManager.ExportFormat.ply)
                    }
                    .pickerStyle(.segmented)
                }

                if let meshData = scanner.getCombinedMeshData() {
                    Section("Scan Info") {
                        LabeledContent("Vertices", value: meshData.vertexCount.formatted())
                        LabeledContent("Faces", value: meshData.faceCount.formatted())
                        let dims = meshData.dimensions
                        LabeledContent("Size", value: String(format: "%.2f x %.2f x %.2f m", dims.x, dims.y, dims.z))
                        if !meshData.colors.isEmpty {
                            LabeledContent("Color Data", value: "Yes")
                        }
                        LabeledContent("Photo Frames", value: "\(scanner.capturedFrameCount)")
                        LabeledContent("Range", value: settings.scanRange.rawValue)
                        LabeledContent("Quality", value: settings.scanQuality.rawValue)
                        LabeledContent("Est. File Size", value: String(format: "%.1f MB", scanner.estimatedFileSizeMB))
                    }
                }

                if isSaving {
                    Section {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 8)
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
                    Button("Cancel") {
                        showingSaveDialog = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveScan()
                    }
                    .disabled(scanName.isEmpty || selectedProject == nil || isSaving)
                }
            }
            .alert("New Project", isPresented: $showingNewProjectDialog) {
                TextField("Project name", text: $newProjectName)
                Button("Create") {
                    if !newProjectName.isEmpty {
                        let project = storageManager.createProject(name: newProjectName)
                        selectedProject = project
                        newProjectName = ""
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Settings Sheet

    private var settingsSheet: some View {
        NavigationView {
            Form {
                Section("Scan Quality") {
                    Picker("Mesh Detail", selection: $settings.meshDetail) {
                        ForEach(ScanSettings.MeshDetail.allCases, id: \.self) { detail in
                            VStack(alignment: .leading) {
                                Text(detail.rawValue)
                                Text(detail.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .tag(detail)
                        }
                    }
                }

                Section("Capture") {
                    Toggle("Capture Texture/Color", isOn: $settings.captureTexture)
                }

                Section("Units") {
                    Picker("Measurement Unit", selection: $settings.unit) {
                        ForEach(ScanSettings.MeasurementUnit.allCases, id: \.self) { unit in
                            Text("\(unit.rawValue) (\(unit.abbreviation))").tag(unit)
                        }
                    }
                }
            }
            .navigationTitle("Scan Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showingSettings = false
                    }
                }
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

        // For Area mode, try plane-based reconstruction first
        let rawMeshData: MeshData?
        #if !targetEnvironment(simulator)
        if settings.meshMode == .area, let planeData = scanner.getPlaneBasedMeshData() {
            rawMeshData = planeData
        } else {
            rawMeshData = scanner.getCombinedMeshData()
        }
        #else
        rawMeshData = scanner.getCombinedMeshData()
        #endif

        guard let rawMesh = rawMeshData else {
            errorMessage = "No scan data available"
            showingError = true
            return
        }

        isSaving = true
        savingProgress = "Processing mesh..."

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let meshData = MeshProcessor.postProcess(rawMesh, level: processingLevel)

                DispatchQueue.main.async { self.savingProgress = "Building texture..." }

                // Build texture atlas for OBJ if we have camera data
                var textureAtlas: TextureAtlasResult?
                if exportFormat == .obj && settings.captureTexture {
                    textureAtlas = scanner.buildTextureAtlas(meshData: meshData)
                }

                DispatchQueue.main.async { self.savingProgress = "Saving file..." }

                let _ = try storageManager.saveScan(
                    meshData: meshData,
                    name: scanName,
                    toProject: project,
                    format: exportFormat,
                    textureAtlas: textureAtlas
                )

                DispatchQueue.main.async {
                    isSaving = false
                    savingProgress = ""
                    showingSaveDialog = false
                    scanner.resetScanning()
                }
            } catch {
                DispatchQueue.main.async {
                    isSaving = false
                    errorMessage = "Failed to save: \(error.localizedDescription)"
                    showingError = true
                }
            }
        }
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
