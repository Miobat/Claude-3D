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

    var body: some View {
        ZStack {
            #if targetEnvironment(simulator)
            // Simulated scanning view
            SimulatorScanView(scanner: scanner)
                .ignoresSafeArea()
            #else
            // AR Camera View
            ARScannerViewRepresentable(scanner: scanner, showMeshOverlay: $showMeshOverlay)
                .ignoresSafeArea()
            #endif

            // Scanning overlay UI
            VStack {
                // Top status bar
                topStatusBar

                Spacer()

                // Bottom controls
                bottomControls
            }

            #if !targetEnvironment(simulator)
            // LiDAR unavailable overlay (only on real device)
            if !LiDARScanner.isLiDARAvailable {
                lidarUnavailableView
            }
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
            // Scan info
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
                    }
                }
            }
            .foregroundColor(.white)

            Spacer()

            #if targetEnvironment(simulator)
            // Simulator badge
            Text("SIMULATOR")
                .font(.caption2)
                .fontWeight(.bold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange)
                .cornerRadius(4)
                .foregroundColor(.white)
            #endif

            // Mesh toggle
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

                // Settings button
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

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: 16) {
            // Main action buttons
            HStack(spacing: 40) {
                if scanner.isScanning {
                    // Pause/Resume
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

                    // Stop & Save
                    Button {
                        scanner.stopScanning()
                        scanName = "Scan \(Date().formattedString)"
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

                    // Reset
                    Button {
                        scanner.resetScanning()
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
                    // Start scanning button
                    Button {
                        scanner.startScanning(
                            detail: settings.meshDetail,
                            captureTexture: settings.captureTexture
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
                }

                Section("Save to Project") {
                    if storageManager.projects.isEmpty {
                        Button("Create New Project") {
                            showingNewProjectDialog = true
                        }
                    } else {
                        Picker("Project", selection: $selectedProject) {
                            Text("Select a project").tag(nil as Project?)
                            ForEach(storageManager.projects) { project in
                                Text(project.name).tag(project as Project?)
                            }
                        }

                        Button("Create New Project") {
                            showingNewProjectDialog = true
                        }
                    }
                }

                if let meshData = scanner.getCombinedMeshData() {
                    Section("Scan Info") {
                        LabeledContent("Vertices", value: meshData.vertexCount.formatted())
                        LabeledContent("Faces", value: meshData.faceCount.formatted())
                        let dims = meshData.dimensions
                        LabeledContent("Size", value: String(format: "%.2f × %.2f × %.2f m", dims.x, dims.y, dims.z))
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
        guard let project = selectedProject,
              let meshData = scanner.getCombinedMeshData() else {
            errorMessage = "No scan data or project selected"
            showingError = true
            return
        }

        isSaving = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let _ = try storageManager.saveScan(
                    meshData: meshData,
                    name: scanName,
                    toProject: project
                )

                DispatchQueue.main.async {
                    isSaving = false
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

/// Animated simulated scanning view for the iOS Simulator
struct SimulatorScanView: View {
    @ObservedObject var scanner: MockLiDARScanner
    @State private var animationPhase: Double = 0

    var body: some View {
        ZStack {
            // Dark background simulating camera feed
            Color(uiColor: UIColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1.0))

            if scanner.isScanning {
                // Animated scanning visualization
                scanningAnimation
            } else if scanner.vertexCount > 0 {
                // Show completion state
                completionView
            } else {
                // Idle state
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
            // Grid overlay
            GeometryReader { geo in
                Canvas { context, size in
                    let gridSpacing: CGFloat = 30
                    let offset = CGFloat(animationPhase) * gridSpacing

                    // Horizontal lines
                    for y in stride(from: -gridSpacing + offset.truncatingRemainder(dividingBy: gridSpacing), through: size.height, by: gridSpacing) {
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(path, with: .color(.cyan.opacity(0.15)), lineWidth: 0.5)
                    }

                    // Vertical lines
                    for x in stride(from: 0, through: size.width, by: gridSpacing) {
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(path, with: .color(.cyan.opacity(0.15)), lineWidth: 0.5)
                    }

                    // Scanning sweep line
                    let sweepY = CGFloat(animationPhase) * size.height
                    var sweepPath = Path()
                    sweepPath.move(to: CGPoint(x: 0, y: sweepY))
                    sweepPath.addLine(to: CGPoint(x: size.width, y: sweepY))
                    context.stroke(sweepPath, with: .color(.cyan.opacity(0.6)), lineWidth: 2)
                }
            }

            // Center crosshair
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
