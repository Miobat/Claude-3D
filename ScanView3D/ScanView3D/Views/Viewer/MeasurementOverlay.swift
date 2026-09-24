import SwiftUI
import SpriteKit
import simd

// MARK: - Snapping types

enum SnapKind: String {
    case surface = "Surface"
    case point = "Point"
    case corner = "Corner"
    case edge = "Edge"
    case vertical = "Vertical"
    case wallAxis = "Along wall"
    case level = "Level"

    var color: UIColor {
        switch self {
        case .surface: return .white
        case .point: return .systemPink
        case .corner: return .systemRed
        case .edge: return .systemOrange
        case .vertical: return .systemGreen
        case .wallAxis: return .systemBlue
        case .level: return .systemPurple
        }
    }
}

struct SnapResult: Equatable {
    var point: SIMD3<Float>
    var kind: SnapKind
    var normal: SIMD3<Float>?
}

/// Geometry questions the measuring tools ask the 3D view.
protocol MeasurementGeometryProvider: AnyObject {
    /// Surfaces straight below and above a point (bottom, top), or nil if none found.
    func verticalSpan(at point: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>)?
    /// Best-fit flat surface around a point: a point on it and its normal.
    func surfacePlane(at point: SIMD3<Float>, fallbackNormal: SIMD3<Float>?) -> (point: SIMD3<Float>, normal: SIMD3<Float>)
}

// MARK: - Session (state + tool logic, main thread)

/// Everything about measuring on one scan: saved measurements, the one being
/// drawn, the live snap preview and the chosen tool.
final class MeasurementSession: ObservableObject {
    @Published private(set) var measurements: [ScanMeasurement] = []
    @Published var tool: ScanMeasurement.Kind = .distance {
        didSet { if oldValue != tool { discardDraft() } }
    }
    @Published private(set) var draftPoints: [SIMD3<Float>] = []
    @Published var snappingEnabled = true { didSet { publish() } }
    @Published var selectedID: UUID? { didSet { publish() } }
    @Published var preview: SnapResult? { didSet { publish() } }
    @Published var isActive = false { didSet { publish() } }
    @Published var message: String?

    var unit: ScanSettings.MeasurementUnit = .meters { didSet { publish() } }
    weak var geometry: MeasurementGeometryProvider?
    /// Called whenever the saved list changes (persist it).
    var onSave: (([ScanMeasurement]) -> Void)?
    /// Called with a fresh snapshot for the overlay to draw.
    var renderSink: ((MeasurementRenderState) -> Void)? { didSet { publish() } }

    private var draftNormals: [SIMD3<Float>] = []

    // MARK: Loading

    func load(_ saved: [ScanMeasurement]) {
        measurements = saved
        publish()
    }

    // MARK: Placing points

    /// Every point you can snap to: saved measurements and the one in progress.
    var snapTargets: [SIMD3<Float>] {
        measurements.flatMap { $0.points } + draftPoints
    }

    var canFinish: Bool {
        tool.autoCompleteCount == nil && draftPoints.count >= tool.minimumPoints
    }

    var status: String {
        if let message = message { return message }
        switch tool {
        case .distance, .wallToWall:
            return draftPoints.isEmpty ? tool.hint : "Place point 2 of 2"
        case .height:
            return tool.hint
        case .path, .area, .elevation:
            if draftPoints.isEmpty { return tool.hint }
            let needed = tool.minimumPoints - draftPoints.count
            return needed > 0 ? "\(draftPoints.count) placed — add \(needed) more" : "\(draftPoints.count) placed — add more or tap Done"
        }
    }

    func placeAtCrosshair() {
        guard let snap = preview else {
            flash("Aim the crosshair at the model")
            return
        }
        place(snap)
    }

    func place(_ snap: SnapResult) {
        message = nil
        switch tool {
        case .height:
            guard let span = geometry?.verticalSpan(at: snap.point) else {
                flash("No surface found straight above or below that point")
                return
            }
            commit(ScanMeasurement(kind: .height, points: [span.0, span.1]))

        case .wallToWall:
            let plane = geometry?.surfacePlane(at: snap.point, fallbackNormal: snap.normal)
                ?? (point: snap.point, normal: snap.normal ?? SIMD3<Float>(0, 1, 0))
            draftPoints.append(plane.point)
            draftNormals.append(plane.normal)
            if draftPoints.count == 2 {
                commit(ScanMeasurement(kind: .wallToWall, points: draftPoints, normals: draftNormals))
            }

        default:
            draftPoints.append(snap.point)
            if let n = tool.autoCompleteCount, draftPoints.count >= n {
                commit(ScanMeasurement(kind: tool, points: draftPoints))
            }
        }
        publish()
    }

    /// Finish an open-ended measurement (path, area, elevation).
    func finish() {
        guard canFinish else { return }
        commit(ScanMeasurement(kind: tool, points: draftPoints))
    }

    func undo() {
        message = nil
        if !draftPoints.isEmpty {
            draftPoints.removeLast()
            if draftNormals.count > draftPoints.count { draftNormals.removeLast() }
        } else if !measurements.isEmpty {
            measurements.removeLast()
            onSave?(measurements)
        }
        publish()
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        measurements.removeAll { $0.id == id }
        selectedID = nil
        onSave?(measurements)
        publish()
    }

    func clearAll() {
        measurements.removeAll()
        selectedID = nil
        discardDraft()
        onSave?(measurements)
    }

    private func commit(_ m: ScanMeasurement) {
        measurements.append(m)
        draftPoints.removeAll()
        draftNormals.removeAll()
        selectedID = m.id
        onSave?(measurements)
        publish()
    }

    private func discardDraft() {
        draftPoints.removeAll()
        draftNormals.removeAll()
        message = nil
        publish()
    }

    private func flash(_ text: String) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.message == text { self?.message = nil }
        }
    }

    // MARK: Overlay

    private var version = 0

    private func publish() {
        version += 1
        renderSink?(MeasurementRenderState(
            measurements: measurements, selectedID: selectedID, draftKind: tool,
            draftPoints: draftPoints, draftNormals: draftNormals, preview: preview,
            showCrosshair: isActive, unit: unit, version: version))
    }
}

// MARK: - Overlay drawing (SpriteKit on top of SceneKit)

struct MeasurementRenderState {
    var measurements: [ScanMeasurement] = []
    var selectedID: UUID?
    var draftKind: ScanMeasurement.Kind = .distance
    var draftPoints: [SIMD3<Float>] = []
    var draftNormals: [SIMD3<Float>] = []
    var preview: SnapResult?
    var showCrosshair = false
    var unit: ScanSettings.MeasurementUnit = .meters
    var version = 0
}

/// Draws measurements as flat lines, dots and labels that stay the same size on
/// screen at any zoom. Redrawn from SceneKit's render loop only when the camera
/// or the measurements change.
final class MeasurementOverlayScene: SKScene {
    private let lock = NSLock()
    private var state = MeasurementRenderState()
    private var drawnVersion = -1
    private var drawnCamera: simd_float4x4?
    private var drawnOrtho: Double = 0
    private var drawnSize: CGSize = .zero

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Main thread.
    func update(_ newState: MeasurementRenderState) {
        lock.lock()
        state = newState
        lock.unlock()
    }

    /// SceneKit render thread. `project` maps a world point to overlay
    /// coordinates (origin bottom-left), or nil if it's behind the camera.
    func redrawIfNeeded(camera: simd_float4x4, ortho: Double, project: (SIMD3<Float>) -> CGPoint?) {
        lock.lock()
        let s = state
        lock.unlock()

        if s.version == drawnVersion, size == drawnSize, ortho == drawnOrtho,
           let last = drawnCamera, Self.same(last, camera) { return }
        drawnVersion = s.version
        drawnCamera = camera
        drawnOrtho = ortho
        drawnSize = size

        removeAllChildren()

        for m in s.measurements {
            let color: UIColor = m.id == s.selectedID ? .systemOrange : .systemYellow
            draw(m, color: color, unit: s.unit, project: project)
        }

        // Measurement in progress (+ live preview to the crosshair)
        var draft = s.draftPoints
        if let p = s.preview?.point, s.showCrosshair, s.draftKind != .height {
            if s.draftKind == .wallToWall, let first = draft.first, let n = s.draftNormals.first {
                // Live perpendicular gap to the surface under the crosshair
                let gap = abs(simd_dot(n, p - first))
                if let a = project(first), let b = project(p) {
                    line([a, b], color: .systemCyan, width: 2, dashed: true)
                    label(s.unit.format(meters: gap), at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), color: .systemCyan)
                }
                draft = []
            } else if !draft.isEmpty {
                draft.append(p)
            }
        }
        if !draft.isEmpty {
            let temp = ScanMeasurement(kind: s.draftKind, points: draft)
            draw(temp, color: .systemCyan, unit: s.unit, project: project, dashed: true)
        }

        if s.showCrosshair { drawCrosshair(s.preview, project: project) }
    }

    private static func same(_ a: simd_float4x4, _ b: simd_float4x4) -> Bool {
        a.columns.0 == b.columns.0 && a.columns.1 == b.columns.1 &&
        a.columns.2 == b.columns.2 && a.columns.3 == b.columns.3
    }

    private func draw(_ m: ScanMeasurement, color: UIColor, unit: ScanSettings.MeasurementUnit,
                      project: (SIMD3<Float>) -> CGPoint?, dashed: Bool = false) {
        let screen = m.points.map(project)
        let visible = screen.compactMap { $0 }

        switch m.kind {
        case .elevation:
            break   // points only
        case .area where visible.count == screen.count && visible.count >= 3:
            let path = CGMutablePath()
            path.addLines(between: visible)
            path.closeSubpath()
            let fill = SKShapeNode(path: path)
            fill.fillColor = color.withAlphaComponent(0.18)
            fill.strokeColor = color
            fill.lineWidth = 2.5
            addChild(fill)
        default:
            // Connect consecutive visible points
            for i in 1..<max(screen.count, 1) {
                if let a = screen[i - 1], let b = screen[i] { line([a, b], color: color, width: 3, dashed: dashed) }
            }
        }
        for p in visible { dot(p, color: color, radius: 5) }

        for (pos, text) in m.labels(unit: unit) {
            if let p = project(pos) { label(text, at: CGPoint(x: p.x, y: p.y + 16), color: color) }
        }
    }

    private func drawCrosshair(_ preview: SnapResult?, project: (SIMD3<Float>) -> CGPoint?) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let color = preview?.kind.color ?? UIColor(white: 0.6, alpha: 1)

        let ring = SKShapeNode(circleOfRadius: 16)
        ring.position = center
        ring.strokeColor = color
        ring.lineWidth = 2
        addChild(ring)
        let cross = CGMutablePath()
        cross.move(to: CGPoint(x: center.x - 6, y: center.y)); cross.addLine(to: CGPoint(x: center.x + 6, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - 6)); cross.addLine(to: CGPoint(x: center.x, y: center.y + 6))
        let plus = SKShapeNode(path: cross)
        plus.strokeColor = color
        plus.lineWidth = 1.5
        addChild(plus)

        if let preview = preview {
            // Snapped position can sit off the exact centre (e.g. a nearby corner).
            if let p = project(preview.point) {
                dot(p, color: color, radius: 6)
                if hypot(p.x - center.x, p.y - center.y) > 3 {
                    line([center, p], color: color, width: 1, dashed: true)
                }
            }
            if preview.kind != .surface {
                label(preview.kind.rawValue, at: CGPoint(x: center.x, y: center.y - 34), color: color)
            }
        } else {
            label("Aim at the model", at: CGPoint(x: center.x, y: center.y - 34), color: UIColor(white: 0.3, alpha: 1))
        }
    }

    // MARK: Primitives

    private func line(_ pts: [CGPoint], color: UIColor, width: CGFloat, dashed: Bool = false) {
        let path = CGMutablePath()
        path.addLines(between: pts)
        let finalPath: CGPath = dashed ? path.copy(dashingWithPhase: 0, lengths: [8, 5]) : path
        let node = SKShapeNode(path: finalPath)
        node.strokeColor = color
        node.lineWidth = width
        node.lineCap = .round
        addChild(node)
    }

    private func dot(_ p: CGPoint, color: UIColor, radius: CGFloat) {
        let node = SKShapeNode(circleOfRadius: radius)
        node.position = p
        node.fillColor = color
        node.strokeColor = .black
        node.lineWidth = 1
        addChild(node)
    }

    private func label(_ text: String, at p: CGPoint, color: UIColor) {
        let l = SKLabelNode(text: text)
        l.fontName = "HelveticaNeue-Bold"
        l.fontSize = 13
        l.fontColor = .black
        l.verticalAlignmentMode = .center
        l.horizontalAlignmentMode = .center
        let w = l.frame.width + 12
        let bg = SKShapeNode(rect: CGRect(x: -w / 2, y: -11, width: w, height: 22), cornerRadius: 6)
        bg.fillColor = color.withAlphaComponent(0.92)
        bg.strokeColor = .clear
        bg.position = p
        bg.addChild(l)
        addChild(bg)
    }
}
