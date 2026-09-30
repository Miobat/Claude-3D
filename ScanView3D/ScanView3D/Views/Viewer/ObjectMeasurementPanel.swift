import SwiftUI
import simd

struct ObjectMeasurementPanel: View {
    @ObservedObject var session: ObjectMeasurementSession
    let unit: ScanSettings.MeasurementUnit
    @State private var showingEdit = false
    @State private var showingDelete = false
    @State private var showingNew = false
    @State private var showingWall = false
    @State private var showingOpen = false
    @State private var pendingOpen: AutomaticMeasuredRegion?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.draft?.name ?? "Select an object").font(.headline)
                    Text(session.message).font(.caption).foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if session.busy { ProgressView().tint(FieldStyle.mint).accessibilityLabel("Analysing selection") }
                else if session.draft != nil {
                    Button { session.save() } label: {
                        Label(session.dirty ? "Save" : "Saved", systemImage: session.dirty ? "checkmark" : "checkmark.circle")
                            .font(.caption.weight(.semibold)).padding(.horizontal, 10).frame(minHeight: 44)
                            .foregroundStyle(FieldStyle.ink).background(FieldStyle.mint, in: RoundedRectangle(cornerRadius: 10))
                    }.disabled(!session.writable || !session.dirty)
                        .accessibilityLabel(session.dirty ? "Save reviewed object" : "Object is saved")
                }
            }
            if let warning = session.warning {
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.yellow).fixedSize(horizontal: false, vertical: true)
            }
            if let region = session.draft {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) { dimensionCards(region) }
                } else {
                    HStack(alignment: .top, spacing: 6) { dimensionCards(region) }
                }
                Text("Scanned surfaces only. Hidden parts may extend beyond these spans.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                if let wall = session.wallDepth {
                    Button { showingWall = true } label: {
                        Label("Use wall depth · " + unit.format(meters: wall.metres), systemImage: "rectangle.dashed")
                            .font(.caption.weight(.semibold)).frame(minHeight: 44)
                    }.disabled(session.busy)
                        .accessibilityHint("Requires you to confirm that the object has no gap behind it")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ObjectMeasurementSession.Mode.allCases, id: \.self) { mode in
                        Button { session.mode = mode } label: {
                            Label(mode.rawValue, systemImage: mode == .select ? "cursorarrow.rays" : (mode == .add ? "paintbrush.pointed" : "eraser"))
                                .font(.caption.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 44)
                                .foregroundStyle(session.mode == mode ? FieldStyle.ink : .white)
                                .background(session.mode == mode ? FieldStyle.mint : .white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        }.disabled(!session.ready || session.busy)
                        .accessibilityAddTraits(session.mode == mode ? .isSelected : [])
                    }
                    Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }
                        .disabled(!session.canUndo).accessibilityLabel("Undo object selection change")
                }
            }.fixedSize(horizontal: false, vertical: true)
            if session.mode == .select {
                HStack(spacing: 10) {
                    Text("Reach").font(.caption)
                    Slider(value: $session.radius, in: 0.25...5, step: 0.05).tint(FieldStyle.mint)
                        .accessibilityLabel("Selection reach from the tapped surface")
                        .accessibilityValue(unit.format(meters: session.radius))
                    Text(unit.format(meters: session.radius)).font(.caption.monospacedDigit()).frame(minWidth: 55)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        Text("Brush").font(.caption)
                        Slider(value: $session.brushRadius, in: 0.01...0.25, step: 0.01).tint(FieldStyle.mint)
                            .accessibilityLabel("Selection brush radius").accessibilityValue(unit.format(meters: session.brushRadius))
                        Text(unit.format(meters: session.brushRadius)).font(.caption.monospacedDigit()).frame(minWidth: 55)
                    }
                    Text("Drag one finger to paint · Use two fingers to pan, pinch to zoom.")
                        .font(.caption2).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let region = session.draft {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(["front", "side", "top"], id: \.self) { view in
                            Button(view.capitalized) { session.alignView?(view, region.bounds) }
                                .font(.caption.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 44)
                                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityLabel("Aligned \(view) view of selected object")
                        }
                        Button { session.rotateFront() } label: { Image(systemName: "rotate.right").frame(width: 44, height: 44) }
                            .disabled(session.busy || region.selection == nil).accessibilityLabel("Turn object front direction by 90 degrees")
                        Button("−5°") { session.turnFront(degrees: -5) }.frame(minWidth: 44, minHeight: 44)
                            .disabled(session.busy || region.selection == nil).accessibilityLabel("Turn object front direction left by 5 degrees")
                        Button("+5°") { session.turnFront(degrees: 5) }.frame(minWidth: 44, minHeight: 44)
                            .disabled(session.busy || region.selection == nil).accessibilityLabel("Turn object front direction right by 5 degrees")
                        Button { showingEdit = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }
                            .disabled(session.busy).accessibilityLabel("Edit object name and bounds")
                    }
                }.fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { if session.dirty { showingNew = true } else { session.newObject() } } label: {
                        Label("New", systemImage: "plus").font(.caption.weight(.semibold)).frame(minWidth: 44, minHeight: 44)
                    }.disabled(session.busy)
                    Spacer(minLength: 0)
                    Button { showingDelete = true } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                        .disabled(session.busy || !session.writable).accessibilityLabel("Delete selected object")
                }
            }
            if !session.saved.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(session.saved.filter { $0.kind == .object }) { object in
                            Button {
                                if session.dirty { pendingOpen = object; showingOpen = true }
                                else { session.open(object) }
                            } label: {
                                Label(object.name, systemImage: "cube").font(.caption).padding(.horizontal, 12).frame(minHeight: 44)
                                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            }.disabled(session.busy).accessibilityLabel("Reopen saved object \(object.name)")
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white).padding(12).fieldPanel().padding(.horizontal, 8)
        .accessibilityIdentifier("objectMeasurementPanel")
        .sheet(isPresented: $showingEdit) {
            if let region = session.draft { ObjectBoundsEditor(region: region) { name, size in session.adjust(name: name, size: size) } }
        }
        .confirmationDialog("Delete this object measurement?", isPresented: $showingDelete, titleVisibility: .visible) {
            Button("Delete object", role: .destructive) { session.deleteDraft() }
        }
        .confirmationDialog("Discard the unsaved selection?", isPresented: $showingNew, titleVisibility: .visible) {
            Button("Discard and select another", role: .destructive) { session.newObject() }
        }
        .confirmationDialog("Is the back of this object flush against the detected wall, with no gap?", isPresented: $showingWall, titleVisibility: .visible) {
            Button("Confirm flush contact — use wall depth") { session.confirmWallContact() }
        } message: {
            Text("This uses the front-to-wall span. Depth will be labelled Wall assumption, not measured. If you cannot confirm contact, keep the scanned span or unknown depth.")
        }
        .confirmationDialog("Discard unsaved changes and open the saved object?", isPresented: $showingOpen, titleVisibility: .visible) {
            Button("Discard and open", role: .destructive) { if let pendingOpen { session.open(pendingOpen) }; pendingOpen = nil }
            Button("Cancel", role: .cancel) { pendingOpen = nil }
        }
    }

    @ViewBuilder private func dimensionCards(_ region: AutomaticMeasuredRegion) -> some View {
        ForEach(AutomaticDimension.Axis.allCases, id: \.self) { axis in
            let dimension = region.dimensions.first { $0.axis == axis }
            VStack(alignment: .leading, spacing: 3) {
                Text(axis.rawValue.capitalized).font(.caption).foregroundStyle(.white.opacity(0.7))
                Text(dimension?.metres.map { unit.format(meters: $0) } ?? "Unknown")
                    .font(.headline.monospacedDigit()).foregroundStyle(FieldStyle.mint)
                    .minimumScaleFactor(0.8)
                Text(evidence(dimension?.evidence)).font(.caption2).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .combine)
        }
    }
    private func evidence(_ evidence: AutomaticDimension.Evidence?) -> String {
        switch evidence {
        case .observedSpan: return "Scanned span"
        case .partial: return "Partial span"
        case .adjusted: return "Adjusted"
        case .assumedFlushToWall: return "Wall assumption"
        default: return "Not observed"
        }
    }
}

private struct ObjectBoundsEditor: View {
    let region: AutomaticMeasuredRegion
    let apply: (String, SIMD3<Float>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var width: String
    @State private var height: String
    @State private var depth: String
    init(region: AutomaticMeasuredRegion, apply: @escaping (String, SIMD3<Float>) -> Void) {
        self.region = region; self.apply = apply
        _name = State(initialValue: region.name)
        _width = State(initialValue: String(format: "%.4f", region.bounds.size.x))
        _height = State(initialValue: String(format: "%.4f", region.bounds.size.y))
        _depth = State(initialValue: String(format: "%.4f", region.bounds.size.z))
    }
    private var size: SIMD3<Float>? {
        func number(_ text: String) -> Float? { Float(text.replacingOccurrences(of: ",", with: ".")) }
        guard let w = number(width), let h = number(height), let d = number(depth),
              w.isFinite, h.isFinite, d.isFinite, w > 0, h > 0, d >= 0, max(w, max(h, d)) <= 1000 else { return nil }
        return SIMD3(w, h, d)
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Object name", text: $name)
                Section("Overall bounds · metres") {
                    TextField("Width", text: $width).keyboardType(.decimalPad).accessibilityLabel("Width in metres")
                    TextField("Height", text: $height).keyboardType(.decimalPad).accessibilityLabel("Height in metres")
                    TextField("Depth", text: $depth).keyboardType(.decimalPad).accessibilityLabel("Depth in metres")
                }
                Text("Changed extents are labelled Adjusted, not measured. Depth of zero stays unknown. The lower, left and rear bounds stay fixed.")
                    .font(.caption)
            }.navigationTitle("Edit object bounds").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") { if let size { apply(name.trimmingCharacters(in: .whitespacesAndNewlines), size); dismiss() } }
                            .disabled(size == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 200)
                    }
                }
        }
    }
}
