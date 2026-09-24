import SwiftUI
import SceneKit
import simd

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
    @State private var measurementUnit: ScanSettings.MeasurementUnit = .preferred
    @State private var showingClearMeasurements = false

    // Long-running work (re-reconstruction)
    @State private var isProcessing = false
    @State private var processingMessage = ""

    // Share
    @State private var showingShareSheet = false
    @State private var shareURL: URL?

    // More menu
    @State private var showingMoreMenu = false

    enum ViewerTool: String, CaseIterable {
        case orbit = "Orbit"
        case measure = "Measure"
    }

    enum VisualizationMode: String, CaseIterable {
        case textured = "Textured"
        case flat = "Flat"
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
                session: session
            )
            .id(reloadToken)
            .ignoresSafeArea(edges: .bottom)

            if isLoading { loadingOverlay }
            if let error = loadError { errorOverlay(error) }

            if isProcessing {
                processingOverlay
            }

            if !isLoading && loadError == nil && !isProcessing {
                VStack {
                    // Top-right buttons
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            // Camera view presets
                            Menu {
                                Button { setCameraView(.top) } label: { Label("Top", systemImage: "arrow.down.to.line") }
                                Button { setCameraView(.front) } label: { Label("Front", systemImage: "arrow.right.to.line") }
                                Button { setCameraView(.side) } label: { Label("Side", systemImage: "arrow.left.to.line") }
                            } label: {
                                Image(systemName: "camera.viewfinder")
                                    .font(.system(size: 18))
                                    .foregroundColor(.white)
                                    .frame(width: 40, height: 40)
                                    .background(Color.black.opacity(0.5))
                                    .clipShape(Circle())
                            }

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
                                Image(systemName: cameraProjection.icon)
                                    .font(.system(size: 18))
                                    .foregroundColor(.white)
                                    .frame(width: 40, height: 40)
                                    .background(Color.black.opacity(0.5))
                                    .clipShape(Circle())
                            }
                        }
                        .padding(.trailing, 12)
                        .padding(.top, 8)
                    }

                    Spacer()

                    if showJoysticks { joystickOverlay }

                    // Bottom toolbar: More | Process | Measure | Share
                    bottomToolbar
                }
            }
        }
        .navigationTitle(scan.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    if let node = modelNode {
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
                        Text("Vertices: \(scan.vertexCount.formatted())")
                        Text("Faces: \(scan.faceCount.formatted())")
                        Text("Size: \(scan.formattedFileSize)")
                        Text("Created: \(scan.createdAt.formattedString)")
                    }
                } label: {
                    Image(systemName: "info.circle")
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        .onAppear {
            session.unit = measurementUnit
            session.load(storageManager.loadMeasurements(for: scan, in: project))
            let store = storageManager, currentScan = scan, currentProject = project
            session.onSave = { list in store.saveMeasurements(list, for: currentScan, in: currentProject) }
        }
        .onChange(of: activeTool) { _, tool in
            session.isActive = (tool == .measure)
        }
        .confirmationDialog("Delete all measurements on this scan?", isPresented: $showingClearMeasurements,
                            titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { session.clearAll() }
            Button("Cancel", role: .cancel) {}
        }
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
                                .padding(.vertical, 6)
                                .background(selected ? Color.yellow : Color.white.opacity(0.15))
                                .foregroundColor(selected ? .black : .white)
                                .cornerRadius(8)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }

            Text(session.status)
                .font(.caption)
                .foregroundColor(session.message == nil ? .white : .yellow)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)

            // Actions: Undo · Add point · Done · Snap
            HStack(spacing: 22) {
                Button { session.undo() } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill").font(.system(size: 30))
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
                        Text(session.snappingEnabled ? "Snap on" : "Snap off").font(.system(size: 9))
                    }
                    .opacity(session.snappingEnabled ? 1 : 0.45)
                }
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
                                        .padding(.vertical, 4)
                                        .background(selected ? Color.orange : Color.black.opacity(0.7))
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }
                    if session.selectedID != nil {
                        Button { session.deleteSelected() } label: {
                            Image(systemName: "trash.circle.fill").font(.system(size: 26)).foregroundColor(.red)
                        }
                        .accessibilityLabel("Delete selected measurement")
                    } else {
                        Button { showingClearMeasurements = true } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 26)).foregroundColor(.red)
                        }
                        .accessibilityLabel("Delete all measurements")
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.6)))
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
            ProgressView().scaleEffect(1.5)
            Text("Loading model...").font(.headline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    private func errorOverlay(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundColor(.orange)
            Text("Failed to Load Model").font(.headline)
            Text(error).font(.body).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
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

            VirtualJoystick(label: "Look") { dx, dy in
                NotificationCenter.default.post(name: .joystickLook, object: nil, userInfo: ["dx": dx, "dy": dy])
            }
            .frame(width: 120, height: 120)
            .padding(.trailing, 20)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Bottom Toolbar (More | Process | Measure | Share)

    private var bottomToolbar: some View {
        VStack(spacing: 8) {
            if activeTool == .measure {
                measurePanel
            }

            // Visualization mode selector (hidden while measuring to keep it simple)
            if activeTool != .measure {
            HStack(spacing: 8) {
                ForEach(VisualizationMode.allCases, id: \.self) { mode in
                    Button {
                        vizMode = mode
                        applyVisualizationMode(mode)
                    } label: {
                        Text(mode.rawValue)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(vizMode == mode ? Color.accentColor : Color.white.opacity(0.15))
                            .foregroundColor(vizMode == mode ? .white : .gray)
                            .cornerRadius(8)
                    }
                }

                Divider().frame(height: 20)

                // Display toggles
                Button { showGrid.toggle() } label: {
                    Image(systemName: "grid")
                        .foregroundColor(showGrid ? .accentColor : .gray)
                        .font(.system(size: 16))
                }
                Button { showBoundingBox.toggle() } label: {
                    Image(systemName: "cube.transparent")
                        .foregroundColor(showBoundingBox ? .accentColor : .gray)
                        .font(.system(size: 16))
                }
                Button {
                    withAnimation { showJoysticks.toggle() }
                } label: {
                    Image(systemName: "gamecontroller.fill")
                        .foregroundColor(showJoysticks ? .accentColor : .gray)
                        .font(.system(size: 16))
                }
                Button {
                    NotificationCenter.default.post(name: .resetCameraView, object: nil)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundColor(.gray)
                        .font(.system(size: 16))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(10)
            .padding(.horizontal, 8)
            }

            // Main action buttons
            HStack(spacing: 0) {
                // More
                Button {
                    showingMoreMenu = true
                } label: {
                    Text("More")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .foregroundColor(.white)
                .background(Color(white: 0.25))
                .cornerRadius(12)


                Spacer().frame(width: 8)

                // Measure
                Button {
                    activeTool = activeTool == .measure ? .orbit : .measure
                } label: {
                    Text("Measure")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .foregroundColor(activeTool == .measure ? .black : .white)
                .background(activeTool == .measure ? Color.yellow : Color(white: 0.25))
                .cornerRadius(12)

                Spacer().frame(width: 8)

                // Share
                Button {
                    exportAndShare()
                } label: {
                    Text("Share")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .foregroundColor(.white)
                .background(Color.accentColor)
                .cornerRadius(12)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .confirmationDialog("More Options", isPresented: $showingMoreMenu) {
            Button("Share Top-Down Image") { captureFloorplanImage() }
            if !session.measurements.isEmpty {
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
                let transform = ScannerView.alignmentTransform(
                    photoPositions: photoPositions,
                    arkitPositions: PoseFile.cameraPositions(forPhotoFolder: photos),
                    modelURL: outputURL, lidarExtent: lidarExtent)
                try storageManager.replacePhotogrammetryModel(
                    scanID: scan.id, in: project, newModelURL: outputURL, modelTransform: transform
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
                    // The new model has a different scale; old measurements no longer apply.
                    self.session.clearAll()
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
        // Textured OBJs come back as one .zip (obj + mtl + texture), others as the file itself.
        guard let url = storageManager.exportScan(scan, from: project) else { return }
        ShareSheetPresenter.present([url])
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

            Text(label).font(.system(size: 8, weight: .medium)).foregroundColor(.white.opacity(0.4))
                .offset(y: joystickRadius + 10)
        }
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

extension Notification.Name {
    static let resetCameraView = Notification.Name("resetCameraView")
    static let joystickMove = Notification.Name("joystickMove")
    static let joystickLook = Notification.Name("joystickLook")
    static let setCameraView = Notification.Name("setCameraView")
    static let setCameraProjection = Notification.Name("setCameraProjection")
    static let setVisualizationMode = Notification.Name("setVisualizationMode")
    static let captureTopDownImage = Notification.Name("captureTopDownImage")
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

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
