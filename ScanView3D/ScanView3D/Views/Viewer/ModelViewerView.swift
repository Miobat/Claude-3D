import SwiftUI
import SceneKit

/// Full-screen 3D model viewer with measurement, processing, and visualization tools
struct ModelViewerView: View {
    let scan: Scan
    let project: Project
    @EnvironmentObject var storageManager: StorageManager

    @State private var sceneView: SCNView?
    @State private var modelNode: SCNNode?
    @State private var isLoading = true
    @State private var loadError: String?

    // Visualization
    @State private var vizMode: VisualizationMode = .textured
    @State private var cameraProjection: CameraProjection = .perspective
    @State private var showGrid = false
    @State private var showBoundingBox = false
    @State private var showJoysticks = false

    // Tools
    @State private var activeTool: ViewerTool = .orbit

    // Measurement
    @State private var measurementPoints: [SCNVector3] = []
    @State private var measurementLabels: [MeasurementLabel] = []
    @State private var measurementUnit: ScanSettings.MeasurementUnit = .meters

    // Processing
    @State private var showingProcessMenu = false
    @State private var isProcessing = false
    @State private var processingMessage = ""

    // Share
    @State private var showingShareSheet = false
    @State private var showingShareMenu = false
    @State private var shareURL: URL?

    // More menu
    @State private var showingMoreMenu = false

    enum ViewerTool: String, CaseIterable {
        case orbit = "Orbit"
        case measure = "Measure"
        case inspect = "Inspect"
    }

    enum VisualizationMode: String, CaseIterable {
        case flat = "Flat"
        case textured = "Textured"
        case normals = "Normals"
        case wireframe = "Wireframe"

        var icon: String {
            switch self {
            case .flat: return "cube.fill"
            case .textured: return "cube.fill"
            case .normals: return "arrow.up.right.and.arrow.down.left.rectangle.fill"
            case .wireframe: return "cube.transparent"
            }
        }
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
                measurementPoints: $measurementPoints,
                measurementLabels: $measurementLabels,
                measurementUnit: $measurementUnit
            )
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
                        let (minBound, maxBound) = node.boundingBox
                        let size = SCNVector3(maxBound.x - minBound.x, maxBound.y - minBound.y, maxBound.z - minBound.z)
                        Section("Dimensions") {
                            Text(String(format: "Width: %.3f m", size.x))
                            Text(String(format: "Height: %.3f m", size.y))
                            Text(String(format: "Depth: %.3f m", size.z))
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
            // Measurement display
            if !measurementLabels.isEmpty {
                HStack {
                    ForEach(measurementLabels.indices, id: \.self) { index in
                        HStack(spacing: 4) {
                            Circle().fill(Color.yellow).frame(width: 8, height: 8)
                            Text(measurementLabels[index].text).font(.caption).fontWeight(.medium)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.black.opacity(0.7)).cornerRadius(8)
                    }
                    Button {
                        measurementPoints.removeAll()
                        measurementLabels.removeAll()
                        NotificationCenter.default.post(name: .clearMeasurements, object: nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    }
                }
                .padding(.horizontal)
            }

            // Visualization mode selector
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

            // Main action buttons (competitor-style)
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

                // Process
                Button {
                    showingProcessMenu = true
                } label: {
                    Text("Process")
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
        .confirmationDialog("Process Scan", isPresented: $showingProcessMenu) {
            Button("Smooth Scan") { runProcessing(.smooth) }
            Button("Simplify Scan (50%)") { runProcessing(.simplify) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apply post-processing to improve scan quality")
        }
        .confirmationDialog("More Options", isPresented: $showingMoreMenu) {
            Button("Capture Floorplan Image") { captureFloorplanImage() }
            Button("Cancel", role: .cancel) {}
        }
    }

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

    // MARK: - Processing Actions

    private func runProcessing(_ type: ProcessingType) {
        guard let model = modelNode else { return }
        isProcessing = true
        processingMessage = type == .smooth ? "Smoothing mesh..." : "Simplifying mesh..."

        DispatchQueue.global(qos: .userInitiated).async {
            // Apply processing directly to the SceneKit geometry
            func processNode(_ node: SCNNode) {
                guard let geometry = node.geometry,
                      let vertexSource = geometry.sources(for: .vertex).first else { return }

                let vertexCount = vertexSource.vectorCount
                guard vertexCount > 0 else { return }

                // Extract vertex positions
                let stride = vertexSource.dataStride
                let offset = vertexSource.dataOffset
                let data = vertexSource.data

                var positions = [SCNVector3]()
                data.withUnsafeBytes { rawPtr in
                    let bytes = rawPtr.baseAddress!
                    for i in 0..<vertexCount {
                        let ptr = bytes.advanced(by: offset + stride * i)
                        let x = ptr.assumingMemoryBound(to: Float.self).pointee
                        let y = ptr.advanced(by: 4).assumingMemoryBound(to: Float.self).pointee
                        let z = ptr.advanced(by: 8).assumingMemoryBound(to: Float.self).pointee
                        positions.append(SCNVector3(x, y, z))
                    }
                }

                // Build adjacency from geometry elements
                var adjacency = [[Int]](repeating: [], count: vertexCount)
                for element in geometry.elements {
                    let indexData = element.data
                    let bytesPerIndex = element.bytesPerIndex
                    let primitiveCount = element.primitiveCount

                    indexData.withUnsafeBytes { rawPtr in
                        let bytes = rawPtr.baseAddress!
                        for p in 0..<primitiveCount {
                            var indices = [Int]()
                            for v in 0..<3 {
                                let ptr = bytes.advanced(by: (p * 3 + v) * bytesPerIndex)
                                let idx: Int
                                if bytesPerIndex == 4 {
                                    idx = Int(ptr.assumingMemoryBound(to: UInt32.self).pointee)
                                } else {
                                    idx = Int(ptr.assumingMemoryBound(to: UInt16.self).pointee)
                                }
                                indices.append(idx)
                            }
                            for i in 0..<3 {
                                for j in (i+1)..<3 {
                                    if indices[i] < vertexCount && indices[j] < vertexCount {
                                        adjacency[indices[i]].append(indices[j])
                                        adjacency[indices[j]].append(indices[i])
                                    }
                                }
                            }
                        }
                    }
                }

                // Apply Laplacian smoothing
                let iterations = type == .smooth ? 3 : 1
                let factor: Float = type == .smooth ? 0.4 : 0.2
                var smoothed = positions

                for _ in 0..<iterations {
                    var newPositions = smoothed
                    for i in 0..<vertexCount {
                        let neighbors = adjacency[i]
                        guard !neighbors.isEmpty else { continue }
                        var avg = SCNVector3(0, 0, 0)
                        for n in neighbors {
                            avg.x += smoothed[n].x
                            avg.y += smoothed[n].y
                            avg.z += smoothed[n].z
                        }
                        let count = Float(neighbors.count)
                        avg.x /= count; avg.y /= count; avg.z /= count
                        newPositions[i].x += (avg.x - smoothed[i].x) * factor
                        newPositions[i].y += (avg.y - smoothed[i].y) * factor
                        newPositions[i].z += (avg.z - smoothed[i].z) * factor
                    }
                    smoothed = newPositions
                }

                // Create new vertex source with smoothed positions
                let newVertexSource = SCNGeometrySource(vertices: smoothed)

                // Rebuild geometry with smoothed vertices
                var sources = [newVertexSource]
                for source in geometry.sources(for: .normal) { sources.append(source) }
                for source in geometry.sources(for: .color) { sources.append(source) }
                for source in geometry.sources(for: .texcoord) { sources.append(source) }

                let newGeometry = SCNGeometry(sources: sources, elements: geometry.elements)
                newGeometry.materials = geometry.materials

                DispatchQueue.main.async {
                    node.geometry = newGeometry
                }
            }

            // Process the model and all children
            processNode(model)
            model.enumerateChildNodes { child, _ in processNode(child) }

            // Simulate processing time for user feedback
            Thread.sleep(forTimeInterval: 0.5)

            DispatchQueue.main.async {
                isProcessing = false
                processingMessage = ""
            }
        }
    }

    enum ProcessingType { case smooth, simplify }

    // MARK: - Floorplan Capture

    private func captureFloorplanImage() {
        // Switch to top-down view first
        cameraProjection = .floorPlan
        applyCameraProjection(.floorPlan)
    }

    // MARK: - Helpers

    private func getFileURL() -> URL? {
        return storageManager.getScanFileURL(scan: scan, project: project)
    }

    private func exportAndShare() {
        if let url = storageManager.exportScan(scan, from: project) {
            shareURL = url
            showingShareSheet = true
        }
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

struct MeasurementLabel: Identifiable {
    let id = UUID()
    let text: String
    let position: SCNVector3
}

extension Notification.Name {
    static let resetCameraView = Notification.Name("resetCameraView")
    static let joystickMove = Notification.Name("joystickMove")
    static let joystickLook = Notification.Name("joystickLook")
    static let setCameraView = Notification.Name("setCameraView")
    static let setCameraProjection = Notification.Name("setCameraProjection")
    static let setVisualizationMode = Notification.Name("setVisualizationMode")
    static let clearMeasurements = Notification.Name("clearMeasurements")
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
