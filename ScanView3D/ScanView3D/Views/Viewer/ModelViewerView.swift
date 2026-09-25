import SwiftUI
import SceneKit
import simd

private struct MeasurePanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 200
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Full-screen 3D model viewer with measurement, processing, and visualization tools
struct ModelViewerView: View {
    @State var scan: Scan
    let project: Project
    @EnvironmentObject var storageManager: StorageManager

    // Bumped to force the SceneKit view to rebuild (e.g. after re-reconstruction).
    @State private var reloadToken = UUID()
    @State private var modelNode: SCNNode?
    @State private var isLoading = true
    @State private var loadError: String?

    // Visualization
    @State private var vizMode: VisualizationMode = .textured
    @State private var cameraProjection: CameraProjection = .perspective
    @State private var showGrid: Bool = (UserDefaults.standard.object(forKey: "showGridByDefault") as? Bool) ?? true
    @State private var showBoundingBox = false
    @State private var showJoysticks = false

    // Tools
    @State private var activeTool: ViewerTool = .orbit

    // Measuring
    @StateObject private var session = MeasurementSession()
    @StateObject private var navigation = WalkNavigation()
    @Environment(\.scenePhase) private var scenePhase
    @State private var measurementUnit: ScanSettings.MeasurementUnit = .preferred
    @State private var showingClearMeasurements = false
    @State private var measurePanelHeight: CGFloat = 200

    // Long-running work (re-reconstruction)
    @State private var isProcessing = false
    @State private var processingMessage = ""

    // Share
    @State private var showingShareSheet = false
    @State private var shareURL: URL?

    // More menu
    @State private var showingMoreMenu = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    enum ViewerTool: String, CaseIterable {
        case orbit = "Orbit"
        case measure = "Measure"
    }

    enum VisualizationMode: String, CaseIterable {
        case textured = "Textured"
        case flat = "Flat"
        case height = "Height"
        case wireframe = "Wireframe"
    }

    enum CameraProjection: String, CaseIterable {
        case perspective = "Perspective"
        case ortho = "Ortho"
        case floorPlan = "FloorPlan"

        var icon: String {
            switch self {
            case .perspective: return "triangle"
            case .ortho: return "square.dashed"
            case .floorPlan: return "house"
            }
        }
    }

    var body: some View {
        ZStack {
            SceneKitViewRepresentable(
                scan: scan,
                project: project,
                storageManager: storageManager,
                modelNode: $modelNode,
                isLoading: $isLoading,
                loadError: $loadError,
                showGrid: $showGrid,
                showBoundingBox: $showBoundingBox,
                vizMode: $vizMode,
                activeTool: $activeTool,
                session: session,
                navigation: navigation
            )
            .id(reloadToken)
            .ignoresSafeArea(edges: .bottom)

            if isLoading { loadingOverlay }
            if let error = loadError { errorOverlay(error) }

            if isProcessing {
                processingOverlay
            }

            if !isLoading && loadError == nil && !isProcessing {
                GeometryReader { geometry in
                let compact = geometry.size.width > geometry.size.height
                VStack {
                    if !scan.hasKnownScale || scan.scaleStatus == .estimatedFromBounds {
                        Label(scan.scaleDescription, systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.white)
                            .padding(12).fieldPanel().padding(.horizontal, 12)
                            .accessibilityIdentifier("scaleWarning")
                    }
                    // Top row: height legend (left), view buttons (right)
                    if !(compact && activeTool == .measure) {
                    HStack(alignment: .top) {
                        if scan.hasKnownScale, vizMode == .height, let node = modelNode {
                            heightLegend(for: node)
                        }
                        Spacer()
                        Group {
                            if compact { HStack(spacing: 8) { cameraControls } }
                            else { VStack(spacing: 12) { cameraControls } }
                        }
                        .padding(.trailing, 12)
                        .padding(.top, 8)
                    }
                    }

                    Spacer(minLength: 0)

                    if navigation.enabled {
                        HStack(spacing: 10) {
                            Image(systemName: "figure.walk")
                            Text(navigation.message).font(.caption).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button("Exit") { navigation.enabled = false }
                                .font(.caption.weight(.semibold)).frame(minWidth: 44, minHeight: 44)
                        }
                        .padding(.horizontal, 12).fieldPanel().padding(.horizontal, 12)
                        .accessibilityIdentifier("walkStatus")
                    }
                    if showJoysticks || navigation.isWalking { joystickOverlay }

                    // Bottom toolbar: More | Process | Measure | Share
                    if compact && activeTool == .measure {
                        HStack {
                            Spacer(minLength: 0)
                            bottomToolbar(compact: true)
                                .frame(width: min(360, geometry.size.width * 0.46))
                        }
                    } else {
                        bottomToolbar(compact: compact)
                            .frame(width: geometry.size.width)
                    }
                }
                .environment(\.colorScheme, .dark)
                }
            }
        }
        .navigationTitle(scan.name)
        .overlay { ExportProgressView(store: storageManager) }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FieldStyle.viewport, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    if scan.hasKnownScale, let node = modelNode {
                        // boundingBox is in the node's own space; include its scale
                        // (High-Quality models carry a metric scale correction).
                        let (minB, maxB) = SceneKitViewRepresentable.worldBounds(of: node)
                        Section("Dimensions") {
                            Text("Width: \(measurementUnit.format(meters: maxB.x - minB.x))")
                            Text("Height: \(measurementUnit.format(meters: maxB.y - minB.y))")
                            Text("Depth: \(measurementUnit.format(meters: maxB.z - minB.z))")
                        }
                    }
                    Section("Scan Info") {
                        Text(scan.scaleDescription)
                        if let provenance = scan.coordinateProvenance {
                            Text(provenance.localDatum)
                            if let rms = provenance.alignmentRMSErrorMetres {
                                Text(String(format: "Camera fit RMS: %.3f m (not field accuracy)", rms))
                            }
                        }
                        Text("Vertices: \(scan.vertexCount.formatted())")
                        Text("Faces: \(scan.faceCount.formatted())")
                        Text("Size: \(scan.formattedFileSize)")
                        Text("Created: \(scan.createdAt.formattedString)")
                        if scan.northAligned == true {
                            Text("Compass alignment requested (−Z ≈ north)")
                        }
                        if let lat = scan.latitude, let lon = scan.longitude {
                            Text(String(format: "Approximate phone GPS: %.6f, %.6f", lat, lon))
                            if let acc = scan.locationAccuracy {
                                Text(String(format: "GPS accuracy: ±%.0f m", acc))
                            }
                            if let time = scan.locationTimestamp { Text("Observed: \(time.formatted())") }
                            if let altitude = scan.altitude, let accuracy = scan.verticalLocationAccuracy {
                                Text(String(format: "Phone altitude: %.1f m (±%.1f m)", altitude, accuracy))
                            }
                            Text("Not survey control. GPS does not georeference the local model.")
                        }
                    }
                } label: {
                    Image(systemName: "info.circle")
                }.accessibilityLabel("Model information and coordinate reference")
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        .onAppear {
            #if DEBUG && targetEnvironment(simulator)
            if DesignPreview.screen == "measure" { activeTool = .measure }
            if DesignPreview.screen == "joysticks" { showJoysticks = true }
            if DesignPreview.screen == "walk" { navigation.enabled = true }
            #endif
            session.unit = measurementUnit
            session.load(storageManager.loadMeasurements(for: scan, in: project))
            let store = storageManager, currentScan = scan, currentProject = project
            session.onSave = { list in try store.saveMeasurements(list, for: currentScan, in: currentProject) }
        }
        .onChange(of: activeTool) { _, tool in
            session.isActive = (tool == .measure)
            if tool == .measure { navigation.enabled = false }
        }
        .onChange(of: navigation.enabled) { _, enabled in
            stopNavigationInputs()
            navigation.isWalking = false
            if enabled {
                activeTool = .orbit
                cameraProjection = .perspective
                navigation.message = "Tap the scanned ground to start · Eye height 1.8 m"
            }
        }
        .onChange(of: showJoysticks) { _, _ in stopNavigationInputs() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stopNavigationInputs() }
        }
        .onDisappear {
            stopNavigationInputs()
            navigation.enabled = false
        }
        .confirmationDialog("Delete all measurements on this scan?", isPresented: $showingClearMeasurements,
                            titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { session.clearAll() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Scans with triangles (not point clouds) can be exported as CAD meshes.
    private var hasMesh: Bool {
        scan.faceCount > 0 || (scan.fileName as NSString).pathExtension.lowercased() == "usdz"
    }

    // MARK: - Height legend

    private func heightLegend(for node: SCNNode) -> some View {
        let (minB, maxB) = SceneKitViewRepresentable.worldBounds(of: node)
        let range = maxB.y - minB.y
        let step = SceneKitViewRepresentable.Coordinator.contourStep(for: range)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Height").font(.caption2).fontWeight(.bold)
            HStack(spacing: 6) {
                LinearGradient(colors: [Color(red: 0.9, green: 0.2, blue: 0.1), Color(red: 0.95, green: 0.85, blue: 0.1),
                                        Color(red: 0.2, green: 0.8, blue: 0.2), Color(red: 0, green: 0.7, blue: 0.9),
                                        Color(red: 0.1, green: 0.2, blue: 0.8)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: 10, height: 90)
                    .cornerRadius(3)
                VStack(alignment: .leading) {
                    Text("+" + measurementUnit.format(meters: range))
                    Spacer()
                    Text("lowest")
                }
                .font(.caption2)
                .frame(height: 90)
            }
            Text("Lines every " + measurementUnit.format(meters: step)).font(.caption2)
        }
        .padding(8)
        .fieldPanel()
        .foregroundColor(.white)
        .padding(.leading, 12)
        .padding(.top, 8)
    }

    // MARK: - Measuring Panel

    private var measurePanel: some View {
        VStack(spacing: 8) {
            // Tools
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ScanMeasurement.Kind.allCases, id: \.self) { kind in
                        let selected = session.tool == kind
                        Button { session.tool = kind } label: {
                            Label(kind.rawValue, systemImage: kind.icon)
                                .font(.caption)
                                .fontWeight(.medium)
                                .padding(.horizontal, 10)
                                .frame(minHeight: 44)
                                .background(selected ? Color.yellow : Color.white.opacity(0.15))
                                .foregroundColor(selected ? .black : .white)
                                .cornerRadius(8)
                        }.accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 12)
            }.fixedSize(horizontal: false, vertical: true)

            Text(session.status)
                .font(.caption)
                .foregroundColor(session.message == nil ? .white : .yellow)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)

            // Actions: Undo · Add point · Done · Snap
            HStack(spacing: 14) {
                Button { session.undo() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.title3).frame(minWidth: 44, minHeight: 44)
                }
                .disabled(session.draftPoints.isEmpty && session.measurements.isEmpty)
                .accessibilityLabel("Undo")

                Button { session.placeAtCrosshair() } label: {
                    ZStack {
                        Circle().fill(Color.yellow).frame(width: 58, height: 58)
                        Image(systemName: "plus").font(.system(size: 26, weight: .bold)).foregroundColor(.black)
                    }
                }
                .accessibilityLabel("Add point at crosshair")

                if session.tool.autoCompleteCount == nil {
                    Button("Done") { session.finish() }
                        .font(.headline)
                        .disabled(!session.canFinish)
                }

                Button { session.snappingEnabled.toggle() } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "scope").font(.system(size: 22))
                        Text(session.snappingEnabled ? "Snap on" : "Snap off").font(.caption2)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .opacity(session.snappingEnabled ? 1 : 0.55)
                }
                .accessibilityLabel("Snap to geometry")
                .accessibilityValue(session.snappingEnabled ? "On" : "Off")
            }
            .foregroundColor(.white)

            // Saved measurements (tap to select, then delete)
            if !session.measurements.isEmpty {
                HStack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(session.measurements) { m in
                                let selected = session.selectedID == m.id
                                Button {
                                    session.selectedID = selected ? nil : m.id
                                } label: {
                                    Label(m.summary(unit: measurementUnit), systemImage: m.kind.icon)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 8)
                                        .frame(minHeight: 44)
                                        .background(selected ? Color.orange : Color.black.opacity(0.7))
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                    if session.selectedID != nil {
                        Button { session.deleteSelected() } label: {
                            Image(systemName: "trash.circle.fill").font(.system(size: 26)).foregroundColor(.red).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Delete selected measurement")
                    } else {
                        Button { showingClearMeasurements = true } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 26)).foregroundColor(.red).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Delete all measurements")
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .fieldPanel()
        .padding(.horizontal, 8)
    }

    // MARK: - Processing Overlay

    private var processingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text(processingMessage)
                .font(.headline)
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.6))
    }

    // MARK: - Loading/Error Overlays

    private var loadingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView().tint(FieldStyle.mint).controlSize(.large)
            Text("Opening your scan").font(.headline).foregroundStyle(.white)
            Text("Preparing geometry and materials").font(.subheadline).foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FieldStyle.viewport)
    }

    private func errorOverlay(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundColor(.orange)
            Text("Unable to open this scan").font(.title2.weight(.semibold)).foregroundStyle(.white)
            Text(error).font(.body).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            Button {
                loadError = nil
                isLoading = true
                modelNode = nil
                reloadToken = UUID()
            } label: { Label("Try again", systemImage: "arrow.clockwise") }
            .buttonStyle(FieldButtonStyle(prominent: true)).frame(maxWidth: 280)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FieldStyle.viewport)
    }

    // MARK: - Joystick Overlay

    private var joystickOverlay: some View {
        HStack {
            VirtualJoystick(label: "Move") { dx, dy in
                NotificationCenter.default.post(name: .joystickMove, object: nil, userInfo: ["dx": dx, "dy": dy])
            }
            .frame(width: 120, height: 120)
            .padding(.leading, 20)

            Spacer()

            if !navigation.enabled {
                VerticalPanSlider { value in
                    NotificationCenter.default.post(name: .joystickElevate, object: nil, userInfo: ["dy": value])
                }
            } else {
                Image(systemName: "figure.walk").foregroundStyle(FieldStyle.mint)
                    .frame(width: 44, height: 100).accessibilityLabel("Height locked to 1.8 metres")
            }

            Spacer()

            VirtualJoystick(label: "Look") { dx, dy in
                NotificationCenter.default.post(name: .joystickLook, object: nil, userInfo: ["dx": dx, "dy": dy])
            }
            .frame(width: 120, height: 120)
            .padding(.trailing, 20)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder private var cameraControls: some View {
                            // Camera view presets
                            Menu {
                                Button { setCameraView(.top) } label: { Label("Top", systemImage: "arrow.down.to.line") }
                                Button { setCameraView(.front) } label: { Label("Front", systemImage: "arrow.right.to.line") }
                                Button { setCameraView(.side) } label: { Label("Side", systemImage: "arrow.left.to.line") }
                            } label: {
                                FieldIcon(symbol: "camera.viewfinder")
                            }

                            .accessibilityLabel("Camera view: top, front, or side")

                            // Projection toggle
                            Menu {
                                ForEach(CameraProjection.allCases, id: \.self) { proj in
                                    Button {
                                        cameraProjection = proj
                                        applyCameraProjection(proj)
                                    } label: {
                                        Label(proj.rawValue, systemImage: proj.icon)
                                    }
                                }
                            } label: {
                                FieldIcon(symbol: cameraProjection.icon)
                            }
                            .accessibilityLabel("Projection: \(cameraProjection.rawValue)")
                            Menu {
                                Toggle("Ground grid", isOn: $showGrid)
                                Toggle("Bounding box", isOn: $showBoundingBox)
                                Toggle("Navigation joysticks", isOn: $showJoysticks)
                            } label: { FieldIcon(symbol: "square.3.layers.3d") }
                            .accessibilityLabel("Visible layers and controls")
                            Button {
                                NotificationCenter.default.post(name: .resetCameraView, object: nil)
                            } label: { FieldIcon(symbol: "arrow.counterclockwise") }
                            .accessibilityLabel("Fit model in view")
    }

    // MARK: - Bottom Toolbar

    private func bottomToolbar(compact: Bool) -> some View {
        VStack(spacing: 8) {
            if activeTool == .measure {
                ScrollView {
                    measurePanel.background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: MeasurePanelHeightKey.self, value: proxy.size.height)
                        }
                    }
                }
                .frame(height: min(measurePanelHeight, compact ? 200 : 260))
                .onPreferenceChange(MeasurePanelHeightKey.self) { measurePanelHeight = max(44, $0) }
            }

            if activeTool != .measure && !compact {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(VisualizationMode.allCases, id: \.self) { mode in
                            Button {
                                vizMode = mode
                                applyVisualizationMode(mode)
                            } label: {
                                Text(mode.rawValue).font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 16).frame(minHeight: 44)
                                    .foregroundStyle(vizMode == mode ? FieldStyle.ink : .white)
                                    .background(vizMode == mode ? FieldStyle.mint : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 13))
                            }.buttonStyle(.plain)
                            .accessibilityAddTraits(vizMode == mode ? .isSelected : [])
                        }
                    }.padding(6)
                }.fixedSize(horizontal: false, vertical: true).fieldPanel().padding(.horizontal, 12)
            }

            Group {
                if typeSize.isAccessibilitySize {
                    ScrollView(.horizontal) { actionDock(compact: compact) }
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    actionDock(compact: compact)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .frame(maxWidth: 660).frame(maxWidth: .infinity)
        .confirmationDialog("More Options", isPresented: $showingMoreMenu) {
            Button("Share Top-Down Image (with scale)") { captureFloorplanImage() }.disabled(!scan.hasKnownScale)
            if hasMesh {
                Button("Export for CAD (OBJ, Z up)") {
                    let record = scan, destination = project, store = storageManager
                    store.prepareExport({ try store.exportZUpOBJ(record, from: destination) }) { ShareSheetPresenter.present([$0]) }
                }
                Button("Export STL (millimetres, Z up)") {
                    let record = scan, destination = project, store = storageManager
                    store.prepareExport({ try store.exportSTL(record, from: destination) }) { ShareSheetPresenter.present([$0]) }
                }
            }
            if scan.hasKnownScale, !session.measurements.isEmpty {
                Button("Export Measurements (CSV)") {
                    if let url = storageManager.exportMeasurementsCSV(session.measurements, scanName: scan.name,
                                                                      unit: measurementUnit) {
                        ShareSheetPresenter.present([url])
                    }
                }
            }
            if storageManager.splatBundleURL(for: scan, in: project) != nil {
                Button("Send Splat Bundle (.zip)") { sendSplatBundle() }
            }
            #if !targetEnvironment(simulator)
            if storageManager.captureFolderURL(for: scan, in: project) != nil {
                Button("Re-reconstruct (Best Quality)") { reReconstruct() }
            }
            #endif
            Button("Cancel", role: .cancel) {}
        }
    }

    private func actionDock(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if compact && activeTool != .measure {
                Menu {
                    ForEach(VisualizationMode.allCases, id: \.self) { mode in
                        Button(mode.rawValue) { vizMode = mode; applyVisualizationMode(mode) }
                    }
                } label: { viewerAction(vizMode.rawValue, icon: "cube") }
                .accessibilityLabel("Rendering style")
            }
            mainViewerActions
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var mainViewerActions: some View {
                Button { showingMoreMenu = true } label: {
                    viewerAction("Tools", icon: "slider.horizontal.3")
                }
                Button { navigation.enabled.toggle() } label: {
                    viewerAction(navigation.enabled ? "Exit Walk" : "Walk", icon: "figure.walk", selected: navigation.enabled)
                }
                .disabled(!scan.hasKnownScale)
                .accessibilityHint("Choose a ground point, then explore at 1.8 metres eye height")
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        activeTool = activeTool == .measure ? .orbit : .measure
                    }
                } label: {
                    viewerAction(activeTool == .measure ? "Done" : "Measure", icon: "ruler",
                                 selected: activeTool == .measure)
                }
                .disabled(!scan.hasKnownScale)
                .opacity(scan.hasKnownScale ? 1 : 0.45)
                .accessibilityHint(scan.hasKnownScale ? "Measure distances and areas" : "Requires verified model scale")
                Button { exportAndShare() } label: {
                    viewerAction("Share", icon: "square.and.arrow.up", selected: true)
                }
    }

    private func viewerAction(_ title: String, icon: String, selected: Bool = false) -> some View {
        VStack(spacing: 6) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: icon).font(.system(size: 18, weight: .medium))
            }
            Text(title).font(.caption.weight(.semibold))
                .fixedSize(horizontal: typeSize.isAccessibilitySize, vertical: true)
        }
        .padding(.horizontal, typeSize.isAccessibilitySize ? 18 : 4)
        .frame(minWidth: typeSize.isAccessibilitySize ? 150 : 0, maxWidth: .infinity)
        .frame(minHeight: 64)
        .foregroundStyle(selected ? FieldStyle.ink : .white)
        .background(selected ? FieldStyle.mint : FieldStyle.panel,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private func stopNavigationInputs() {
        NotificationCenter.default.post(name: .stopViewerNavigation, object: nil)
    }

    /// Re-share the Splat bundle zip that was saved with this scan.
    private func sendSplatBundle() {
        guard let url = storageManager.splatBundleURL(for: scan, in: project) else { return }
        shareURL = url
        showingShareSheet = true
    }

    #if !targetEnvironment(simulator)
    /// Re-run on-device photogrammetry from the kept photos at Best effort.
    private func reReconstruct() {
        guard let photos = storageManager.captureFolderURL(for: scan, in: project) else { return }
        isProcessing = true
        processingMessage = "Reconstructing… 0%"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).usdz")
        let lidarExtent = scan.boundingBoxMin.flatMap { mn in
            scan.boundingBoxMax.map { mx in length(mx - mn) }
        }
        Task {
            do {
                let photoPositions = try await PhotogrammetryProcessor.reconstruct(
                    inputFolder: photos, outputUSDZ: outputURL, quality: .best
                ) { fraction in
                    DispatchQueue.main.async { self.processingMessage = "Reconstructing… \(Int(fraction * 100))%" }
                }
                let alignment = ScannerView.alignmentTransform(
                    photoPositions: photoPositions,
                    arkitPositions: PoseFile.cameraPositions(forPhotoFolder: photos),
                    modelURL: outputURL, lidarExtent: lidarExtent)
                // Reuse the tidy frame chosen when the scan was first saved.
                var transform = alignment?.transform
                if let a = alignment, a.poseBased, let frame = scan.sceneFrameMatrix {
                    transform = frame * a.transform
                }
                try storageManager.replacePhotogrammetryModel(
                    scanID: scan.id, in: project, newModelURL: outputURL, modelTransform: transform,
                    provenance: ScannerView.photoProvenance(alignment, frame: scan.sceneFrameMatrix)
                )
                try? FileManager.default.removeItem(at: outputURL)
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.processingMessage = ""
                    // Refresh the local scan copy (new model + metric scale) and
                    // force the SceneKit view to rebuild from the updated file.
                    if let updated = self.storageManager.projects
                        .first(where: { $0.id == self.project.id })?
                        .scans.first(where: { $0.id == self.scan.id }) {
                        self.scan = updated
                    }
                    // Old measurements remain with the previous model for recovery.
                    // Bind future saves to the NEW filename, not the onAppear snapshot.
                    self.session.load([])
                    self.session.selectedID = nil
                    let store = self.storageManager, currentScan = self.scan, currentProject = self.project
                    self.session.onSave = { list in try store.saveMeasurements(list, for: currentScan, in: currentProject) }
                    self.modelNode = nil
                    self.reloadToken = UUID()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.processingMessage = ""
                    self.loadError = PhotogrammetryProcessor.friendlyMessage(for: error)
                }
            }
        }
    }
    #endif

    // MARK: - Camera View Presets

    enum CameraView { case top, front, side }

    private func setCameraView(_ view: CameraView) {
        NotificationCenter.default.post(
            name: .setCameraView,
            object: nil,
            userInfo: ["view": view.rawString]
        )
    }

    private func applyCameraProjection(_ projection: CameraProjection) {
        NotificationCenter.default.post(
            name: .setCameraProjection,
            object: nil,
            userInfo: ["projection": projection.rawValue]
        )
    }

    private func applyVisualizationMode(_ mode: VisualizationMode) {
        NotificationCenter.default.post(
            name: .setVisualizationMode,
            object: nil,
            userInfo: ["mode": mode.rawValue]
        )
    }

    // MARK: - Floorplan Capture

    /// Switch to a top-down orthographic view, then snapshot and share it.
    private func captureFloorplanImage() {
        cameraProjection = .floorPlan
        NotificationCenter.default.post(name: .captureTopDownImage, object: nil)
    }

    // MARK: - Helpers

    private func exportAndShare() {
        let record = scan, destination = project, store = storageManager
        store.prepareExport({ try store.exportScan(record, from: destination) }) { ShareSheetPresenter.present([$0]) }
    }
}

// Helper extension for camera view
extension ModelViewerView.CameraView {
    var rawString: String {
        switch self {
        case .top: return "top"
        case .front: return "front"
        case .side: return "side"
        }
    }
}

// MARK: - Virtual Joystick

struct VirtualJoystick: View {
    let label: String
    let onMove: (CGFloat, CGFloat) -> Void

    @State private var knobOffset: CGSize = .zero
    @State private var isDragging = false
    @GestureState private var dragOffset: CGSize = .zero

    private let joystickRadius: CGFloat = 50
    private let knobRadius: CGFloat = 22

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.3))
                .frame(width: joystickRadius * 2, height: joystickRadius * 2)
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1.5))

            ForEach(0..<4) { i in
                let angle = Double(i) * .pi / 2
                Circle().fill(Color.white.opacity(0.15)).frame(width: 6, height: 6)
                    .offset(x: cos(angle) * (joystickRadius - 12), y: sin(angle) * (joystickRadius - 12))
            }

            Circle()
                .fill(Color.white.opacity(isDragging ? 0.8 : 0.5))
                .frame(width: knobRadius * 2, height: knobRadius * 2)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                .offset(effectiveOffset)
                .gesture(
                    DragGesture()
                        .updating($dragOffset) { value, state, _ in state = value.translation }
                        .onChanged { value in
                            isDragging = true
                            let clamped = clampToRadius(value.translation)
                            onMove(clamped.width / joystickRadius, clamped.height / joystickRadius)
                        }
                        .onEnded { _ in isDragging = false; knobOffset = .zero; onMove(0, 0) }
                )

            Text(label).font(.caption2.weight(.medium)).foregroundColor(.white.opacity(0.7))
                .offset(y: joystickRadius + 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) joystick")
        .onChange(of: dragOffset) { _, offset in
            if offset == .zero { isDragging = false; onMove(0, 0) }
        }
        .onDisappear { isDragging = false; onMove(0, 0) }
    }

    private var effectiveOffset: CGSize { isDragging ? clampToRadius(dragOffset) : .zero }

    private func clampToRadius(_ offset: CGSize) -> CGSize {
        let distance = sqrt(offset.width * offset.width + offset.height * offset.height)
        let maxDist = joystickRadius - knobRadius
        if distance > maxDist {
            let scale = maxDist / distance
            return CGSize(width: offset.width * scale, height: offset.height * scale)
        }
        return offset
    }
}

// MARK: - Supporting Types

/// Spring-centred rate control: drag up/down to elevate, release to stop.
/// Small visual track, but a full 44-point-wide touch target.
private struct VerticalPanSlider: View {
    var onMove: (CGFloat) -> Void
    @GestureState private var offset: CGFloat = 0

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "chevron.up").font(.caption2)
            ZStack {
                Capsule().fill(.white.opacity(0.18)).frame(width: 5, height: 62)
                Capsule().fill(FieldStyle.mint).frame(width: 26, height: 16).offset(y: offset)
            }.frame(width: 44, height: 70).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($offset) { value, state, _ in state = min(26, max(-26, value.translation.height)) }
                    .onChanged { value in onMove(-min(26, max(-26, value.translation.height)) / 26) }
                    .onEnded { _ in onMove(0) })
            Image(systemName: "chevron.down").font(.caption2)
        }
        .foregroundStyle(.white.opacity(0.8))
        .frame(width: 44, height: 100)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pan vertically")
        .accessibilityHint("Slide up or down; release to stop. Two-finger pan is also available.")
        .onChange(of: offset) { _, value in if value == 0 { onMove(0) } }
        .onDisappear { onMove(0) }
    }
}

extension Notification.Name {
    static let resetCameraView = Notification.Name("resetCameraView")
    static let joystickMove = Notification.Name("joystickMove")
    static let joystickLook = Notification.Name("joystickLook")
    static let joystickElevate = Notification.Name("joystickElevate")
    static let stopViewerNavigation = Notification.Name("stopViewerNavigation")
    static let setCameraView = Notification.Name("setCameraView")
    static let setCameraProjection = Notification.Name("setCameraProjection")
    static let setVisualizationMode = Notification.Name("setVisualizationMode")
    static let captureTopDownImage = Notification.Name("captureTopDownImage")
}

/// Adds a scale bar to a top-down orthographic snapshot.
enum FloorPlanImage {
    static func addScaleBar(to image: UIImage, metresPerPoint: Float, unit: ScanSettings.MeasurementUnit) -> UIImage {
        guard metresPerPoint > 0, metresPerPoint.isFinite else { return image }
        let size = image.size
        // Largest "nice" length (1, 2 or 5 × 10^n m) that fits ~30 % of the width.
        let wanted = Float(size.width) * 0.3 * metresPerPoint
        var nice: Float = 0.001
        for exp in -3...5 {
            for m in [1, 2, 5] as [Float] {
                let v = m * powf(10, Float(exp))
                if v <= wanted { nice = v }
            }
        }
        let barLength = CGFloat(nice / metresPerPoint)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            image.draw(at: .zero)
            let margin: CGFloat = 20
            let label = unit.format(meters: nice) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 14), .foregroundColor: UIColor.black]
            let labelSize = label.size(withAttributes: attrs)
            let box = CGRect(x: margin, y: size.height - margin - 44,
                             width: max(barLength, labelSize.width) + 24, height: 44)
            UIColor.white.withAlphaComponent(0.9).setFill()
            UIBezierPath(roundedRect: box, cornerRadius: 8).fill()
            let barY = box.maxY - 12
            let bar = UIBezierPath()
            bar.move(to: CGPoint(x: box.minX + 12, y: barY - 6))
            bar.addLine(to: CGPoint(x: box.minX + 12, y: barY))
            bar.addLine(to: CGPoint(x: box.minX + 12 + barLength, y: barY))
            bar.addLine(to: CGPoint(x: box.minX + 12 + barLength, y: barY - 6))
            bar.lineWidth = 3
            UIColor.black.setStroke()
            bar.stroke()
            label.draw(at: CGPoint(x: box.minX + 12, y: box.minY + 5), withAttributes: attrs)
        }
    }
}

/// Presents the system share sheet from whatever is currently on screen.
enum ShareSheetPresenter {
    static func present(_ items: [Any]) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard !items.isEmpty,
              let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene.windows.first?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = top.view
        activity.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 80, width: 0, height: 0)
        top.present(activity, animated: true)
    }
}

struct ExportProgressView: View {
    @ObservedObject var store: StorageManager
    var body: some View {
        if store.isExporting {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large).tint(FieldStyle.accent)
                    Text(store.exportMessage).font(.headline).multilineTextAlignment(.center)
                    Text("Includes units and coordinate metadata. Not a project backup.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Cancel export") { store.cancelExport() }.buttonStyle(FieldButtonStyle())
                }
                .padding(24).fieldCard().frame(maxWidth: 420).padding(24)
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
