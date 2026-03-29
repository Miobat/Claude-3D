import SwiftUI
import SceneKit

/// Full-screen 3D model viewer with measurement and editing tools
struct ModelViewerView: View {
    let scan: Scan
    let project: Project
    @EnvironmentObject var storageManager: StorageManager

    @State private var sceneView: SCNView?
    @State private var modelNode: SCNNode?
    @State private var isLoading = true
    @State private var loadError: String?

    // Tools
    @State private var activeTool: ViewerTool = .orbit
    @State private var showGrid = true
    @State private var showWireframe = false
    @State private var showPointCloud = false
    @State private var pointSize: CGFloat = 2.0
    @State private var showJoysticks = false

    // Measurement
    @State private var measurementPoints: [SCNVector3] = []
    @State private var measurementLabels: [MeasurementLabel] = []
    @State private var measurementUnit: ScanSettings.MeasurementUnit = .meters

    // Share
    @State private var showingShareSheet = false
    @State private var shareURL: URL?

    enum ViewerTool: String, CaseIterable {
        case orbit = "Orbit"
        case measure = "Measure"
        case inspect = "Inspect"
    }

    var body: some View {
        ZStack {
            // 3D Scene
            SceneKitViewRepresentable(
                scan: scan,
                project: project,
                storageManager: storageManager,
                modelNode: $modelNode,
                isLoading: $isLoading,
                loadError: $loadError,
                showGrid: $showGrid,
                showWireframe: $showWireframe,
                activeTool: $activeTool,
                measurementPoints: $measurementPoints,
                measurementLabels: $measurementLabels,
                measurementUnit: $measurementUnit
            )
            .ignoresSafeArea(edges: .bottom)

            // Loading overlay
            if isLoading {
                loadingOverlay
            }

            // Error overlay
            if let error = loadError {
                errorOverlay(error)
            }

            // Toolbar and joysticks overlay
            if !isLoading && loadError == nil {
                VStack {
                    Spacer()

                    // Joystick overlay
                    if showJoysticks {
                        joystickOverlay
                    }

                    toolbarView
                }
            }
        }
        .navigationTitle(scan.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    exportAndShare()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }

                Menu {
                    if let node = modelNode {
                        let (minBound, maxBound) = node.boundingBox
                        let size = SCNVector3(
                            maxBound.x - minBound.x,
                            maxBound.y - minBound.y,
                            maxBound.z - minBound.z
                        )
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

    // MARK: - Loading Overlay

    private var loadingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading model...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: - Error Overlay

    private func errorOverlay(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text("Failed to Load Model")
                .font(.headline)
            Text(error)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: - Joystick Overlay

    private var joystickOverlay: some View {
        HStack {
            // Left joystick: Move/Pan
            VirtualJoystick(label: "Move") { dx, dy in
                NotificationCenter.default.post(
                    name: .joystickMove,
                    object: nil,
                    userInfo: ["dx": dx, "dy": dy]
                )
            }
            .frame(width: 120, height: 120)
            .padding(.leading, 20)

            Spacer()

            // Right joystick: Rotate/Look
            VirtualJoystick(label: "Look") { dx, dy in
                NotificationCenter.default.post(
                    name: .joystickLook,
                    object: nil,
                    userInfo: ["dx": dx, "dy": dy]
                )
            }
            .frame(width: 120, height: 120)
            .padding(.trailing, 20)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Toolbar

    private var toolbarView: some View {
        VStack(spacing: 8) {
            // Measurement display
            if !measurementLabels.isEmpty {
                HStack {
                    ForEach(measurementLabels.indices, id: \.self) { index in
                        let label = measurementLabels[index]
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.yellow)
                                .frame(width: 8, height: 8)
                            Text(label.text)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(8)
                    }

                    Button {
                        measurementPoints.removeAll()
                        measurementLabels.removeAll()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal)
            }

            // Tool buttons
            HStack(spacing: 12) {
                // Tool selector
                ForEach(ViewerTool.allCases, id: \.self) { tool in
                    Button {
                        activeTool = tool
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: iconForTool(tool))
                                .font(.system(size: 20))
                            Text(tool.rawValue)
                                .font(.caption2)
                        }
                        .foregroundColor(activeTool == tool ? .white : .gray)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(activeTool == tool ? Color.accentColor : Color.clear)
                        .cornerRadius(8)
                    }
                }

                Divider()
                    .frame(height: 30)

                // Display toggles
                Button {
                    showGrid.toggle()
                } label: {
                    Image(systemName: "grid")
                        .foregroundColor(showGrid ? .accentColor : .gray)
                        .font(.system(size: 20))
                }

                Button {
                    showWireframe.toggle()
                } label: {
                    Image(systemName: "cube.transparent")
                        .foregroundColor(showWireframe ? .accentColor : .gray)
                        .font(.system(size: 20))
                }

                // Joystick toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showJoysticks.toggle()
                    }
                } label: {
                    Image(systemName: "gamecontroller.fill")
                        .foregroundColor(showJoysticks ? .accentColor : .gray)
                        .font(.system(size: 20))
                }

                // Reset view
                Button {
                    NotificationCenter.default.post(name: .resetCameraView, object: nil)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundColor(.gray)
                        .font(.system(size: 20))
                }
            }
            .padding(.horizontal, AppConstants.Layout.padding)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .cornerRadius(AppConstants.Layout.cornerRadius)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Helpers

    private func iconForTool(_ tool: ViewerTool) -> String {
        switch tool {
        case .orbit: return "arrow.triangle.2.circlepath"
        case .measure: return "ruler"
        case .inspect: return "eye"
        }
    }

    private func exportAndShare() {
        if let url = storageManager.exportScan(scan, from: project) {
            shareURL = url
            showingShareSheet = true
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
            // Base circle
            Circle()
                .fill(Color.black.opacity(0.3))
                .frame(width: joystickRadius * 2, height: joystickRadius * 2)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 1.5)
                )

            // Direction indicators
            ForEach(0..<4) { i in
                let angle = Double(i) * .pi / 2
                Circle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 6, height: 6)
                    .offset(
                        x: cos(angle) * (joystickRadius - 12),
                        y: sin(angle) * (joystickRadius - 12)
                    )
            }

            // Knob
            Circle()
                .fill(Color.white.opacity(isDragging ? 0.8 : 0.5))
                .frame(width: knobRadius * 2, height: knobRadius * 2)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                .offset(effectiveOffset)
                .gesture(
                    DragGesture()
                        .updating($dragOffset) { value, state, _ in
                            state = value.translation
                        }
                        .onChanged { value in
                            isDragging = true
                            let clamped = clampToRadius(value.translation)
                            let dx = clamped.width / joystickRadius
                            let dy = clamped.height / joystickRadius
                            onMove(dx, dy)
                        }
                        .onEnded { _ in
                            isDragging = false
                            knobOffset = .zero
                            onMove(0, 0)
                        }
                )

            // Label
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .offset(y: joystickRadius + 10)
        }
    }

    private var effectiveOffset: CGSize {
        isDragging ? clampToRadius(dragOffset) : .zero
    }

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

// MARK: - Measurement Label

struct MeasurementLabel: Identifiable {
    let id = UUID()
    let text: String
    let position: SCNVector3
}

// MARK: - Notification Names

extension Notification.Name {
    static let resetCameraView = Notification.Name("resetCameraView")
    static let joystickMove = Notification.Name("joystickMove")
    static let joystickLook = Notification.Name("joystickLook")
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
