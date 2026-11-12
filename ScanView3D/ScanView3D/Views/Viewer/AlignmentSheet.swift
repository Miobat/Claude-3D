import SwiftUI
import simd

/// Info → Accuracy & alignment.
///
/// Shows what drift correction did to a long point-cloud scan, lets the user
/// check any scan against things measured independently (a taped distance, an
/// edge known to be straight, surveyed control points), and makes COPIES: the
/// points as captured, or fitted to the references. The scan this sheet was
/// opened from is never changed.
struct AlignmentSheet: View {
    let scan: Scan
    let project: Project
    /// Saved measurements of this scan: the source of reference points.
    let measurements: [ScanMeasurement]
    @ObservedObject var store: StorageManager
    @Environment(\.dismiss) private var dismiss

    @State private var references = ScanReferenceDocument()
    @State private var loaded = false
    @State private var busy = false
    @State private var failure: String?
    @State private var copy: Scan?
    @State private var copyTitle = ""

    @State private var showingLength = false
    @State private var pendingDistance: ScanMeasurement?
    @State private var lengthText = ""
    @State private var showingControl = false
    @State private var pendingPoint: SIMD3<Float>?
    @State private var pendingName = ""
    @State private var eastText = ""
    @State private var northText = ""
    @State private var heightText = ""

    private var isPointCloud: Bool {
        scan.faceCount == 0 && (scan.fileName as NSString).pathExtension.lowercased() == "ply"
    }
    private var hasWalkRecording: Bool { (scan.alignment?.segmentCount ?? 0) >= 2 }
    private var report: DriftReferences.Report { DriftReferences.report(references) }
    private var canFit: Bool {
        isPointCloud && (references.controls.count >= 2
            || (hasWalkRecording && (!references.distances.isEmpty || !references.lines.isEmpty)))
    }

    var body: some View {
        NavigationStack {
            Form {
                driftSection
                Section {
                    Text("Mark points with Measure first, then give them their real value here. Checking never changes the scan.")
                        .font(.callout)
                } header: { Text("Check against known measurements") }
                distanceSection
                lineSection
                controlSection
                fitSection
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .navigationTitle("Accuracy & alignment").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .alert("Known length", isPresented: $showingLength) {
                TextField("Metres", text: $lengthText).keyboardType(.numbersAndPunctuation)
                Button("Add") { addDistance() }
                Button("Cancel", role: .cancel) { pendingDistance = nil }
            } message: {
                Text("The tape-measured distance between the two points, in metres.")
            }
            .alert("Control point", isPresented: $showingControl) {
                TextField("East (m)", text: $eastText).keyboardType(.numbersAndPunctuation)
                TextField("North (m)", text: $northText).keyboardType(.numbersAndPunctuation)
                TextField("Height (m)", text: $heightText).keyboardType(.numbersAndPunctuation)
                Button("Add") { addControl() }
                Button("Cancel", role: .cancel) { pendingPoint = nil }
            } message: {
                Text("Surveyed coordinates of \(pendingName), in metres.")
            }
            .onAppear { load() }
        }
    }

    // MARK: Drift report

    @ViewBuilder private var driftSection: some View {
        if let summary = scan.alignment {
            Section("Drift on this scan") {
                if summary.segmentCount > 0 {
                    LabeledContent("Walked", value: String(format: "%.0f m in %d stretches", summary.pathLengthMetres, summary.segmentCount))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Passes over the same place").font(.subheadline.weight(.semibold))
                        Text(summary.overlapDescription).font(.callout).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                    if let worst = summary.disagreementMetres, worst >= 0.001 {
                        LabeledContent("Largest mismatch found", value: centimetres(worst))
                    }
                    if summary.overlap == DriftRefiner.Result.applied.rawValue,
                       let before = summary.mismatchBeforeMetres, let after = summary.mismatchAfterMetres {
                        LabeledContent("Doubled surfaces", value: centimetres(before) + " → " + centimetres(after))
                    }
                    LabeledContent("Phone's own corrections",
                                   value: summary.phoneCorrectionMetres > 0 ? "up to " + centimetres(summary.phoneCorrectionMetres) : "none")
                    if summary.trackingJumps > 0 {
                        LabeledContent("Position snaps while scanning", value: "\(summary.trackingJumps)")
                    }
                    if summary.fastTurnSeconds >= 1 {
                        LabeledContent("Fast turning", value: String(format: "%.0f s", summary.fastTurnSeconds))
                    }
                }
                LabeledContent("Largest move applied",
                               value: summary.corrected ? centimetres(summary.largestMoveMetres) : "none — saved as captured")
                if summary.asCapturedCopy == true {
                    Label("This is an as-captured copy", systemImage: "arrow.uturn.backward.circle")
                }
                if summary.fittedToReferences == true {
                    Label("Fitted to references", systemImage: "scope")
                }
                if let origin = summary.siteOrigin, origin.count == 3 {
                    Text(String(format: "Control-point grid. X = east − %.0f, Y = height − %.0f, Z = −(north − %.0f).",
                                origin[0], origin[2], origin[1]))
                        .font(.callout)
                }
            }
            Section {
                Text("Whole stretches of the walk are moved together; no points are added, removed or averaged. Error along the length of a plain wall or canal cannot be seen from overlap. This is not a field-accuracy guarantee: check a long scan against a known distance.")
                    .font(.callout)
                if summary.corrected, summary.asCapturedCopy != true, isPointCloud, summary.segmentCount > 0 {
                    Button { makeCopy("As-captured copy") { try store.saveAsCapturedCopy(of: scan, in: project) } } label: {
                        HStack {
                            Label("Save as-captured copy", systemImage: "arrow.uturn.backward")
                            if busy { Spacer(); ProgressView() }
                        }
                    }.disabled(busy)
                    Text("Keeps this scan unchanged and adds the points exactly as the phone recorded them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Section("Drift on this scan") {
                Text("This scan has no walk recording: it was made before drift correction existed, is not a point cloud, or used Auto terrain sampling. It can still be checked against known measurements below.")
                    .font(.callout)
            }
        }
    }

    // MARK: References

    private var distanceCandidates: [(index: Int, measurement: ScanMeasurement)] {
        measurements.enumerated().compactMap { index, m in
            m.kind == .distance && m.points.count == 2 ? (index + 1, m) : nil
        }
    }
    private var lineCandidates: [(index: Int, measurement: ScanMeasurement)] {
        measurements.enumerated().compactMap { index, m in
            m.kind == .path && m.points.count >= 3 ? (index + 1, m) : nil
        }
    }
    private var pointCandidates: [(name: String, point: SIMD3<Float>)] {
        var out: [(String, SIMD3<Float>)] = []
        for (index, m) in measurements.enumerated() {
            for (k, p) in m.points.enumerated() where out.count < 60 {
                out.append(("\(m.kind.rawValue) \(index + 1), point \(k + 1)", p))
            }
        }
        return out
    }

    @ViewBuilder private var distanceSection: some View {
        Section {
            ForEach(report.distances) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name).font(.subheadline.weight(.semibold))
                    Text("Scan \(metres(row.scanMetres)) · known \(metres(row.knownMetres))")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Text("Difference " + signed(row.deviation))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(abs(row.deviation) > 0.02 ? Color.orange : Color.primary)
                }.accessibilityElement(children: .combine)
            }
            .onDelete { offsets in references.distances.remove(atOffsets: offsets); persist() }
            Menu {
                ForEach(distanceCandidates, id: \.measurement.id) { entry in
                    Button("Distance \(entry.index) · \(entry.measurement.summary(unit: .meters))") {
                        pendingDistance = entry.measurement; pendingName = "Distance \(entry.index)"
                        lengthText = ""; showingLength = true
                    }
                }
            } label: { Label("Add known distance", systemImage: "ruler") }
            .disabled(distanceCandidates.isEmpty || busy)
        } header: { Text("Known distances") } footer: {
            Text(distanceCandidates.isEmpty
                 ? "Use Measure → Distance between two marks whose distance you have taped, then add it here."
                 : "Pick a Distance measurement and enter what the tape says.")
        }
    }

    @ViewBuilder private var lineSection: some View {
        Section {
            ForEach(report.lines) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name).font(.subheadline.weight(.semibold))
                    Text("Length \(metres(row.lengthMetres)) · off a straight line by up to \(centimetres(row.largestOffsetMetres))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(row.largestOffsetMetres > 0.02 ? Color.orange : Color.secondary)
                }.accessibilityElement(children: .combine)
            }
            .onDelete { offsets in references.lines.remove(atOffsets: offsets); persist() }
            Menu {
                ForEach(lineCandidates, id: \.measurement.id) { entry in
                    Button("Path \(entry.index) · \(entry.measurement.points.count) points") { addLine(entry.measurement, name: "Path \(entry.index)") }
                }
            } label: { Label("Add straight line", systemImage: "line.diagonal") }
            .disabled(lineCandidates.isEmpty || busy)
        } header: { Text("Edges that are straight in reality") } footer: {
            Text(lineCandidates.isEmpty
                 ? "Use Measure → Path to place three or more points along an edge, kerb or string line you know is straight, then add it here."
                 : "Shows how far the scan bows away from a straight line through the first and last point.")
        }
    }

    @ViewBuilder private var controlSection: some View {
        Section {
            ForEach(Array(report.controls.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name).font(.subheadline.weight(.semibold))
                    if index < references.controls.count {
                        let c = references.controls[index]
                        Text(String(format: "E %.3f · N %.3f · H %.3f", c.east, c.north, c.height))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let residual = row.residualMetres {
                        Text("Misfit after turning and shifting the scan: " + centimetres(residual))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(residual > 0.03 ? Color.orange : Color.primary)
                    } else {
                        Text("Add at least one more control point").font(.callout).foregroundStyle(.secondary)
                    }
                }.accessibilityElement(children: .combine)
            }
            .onDelete { offsets in references.controls.remove(atOffsets: offsets); persist() }
            Menu {
                ForEach(Array(pointCandidates.enumerated()), id: \.offset) { _, entry in
                    Button(entry.name) {
                        pendingPoint = entry.point; pendingName = entry.name
                        eastText = ""; northText = ""; heightText = ""; showingControl = true
                    }
                }
            } label: { Label("Add control point", systemImage: "mappin.and.ellipse") }
            .disabled(pointCandidates.isEmpty || busy)
        } header: { Text("Control points (surveyed coordinates)") } footer: {
            Text("Any measured point can be a control point. Two fix heading and position; three or more also show how well the scan fits. The scan is never tilted: height stays vertical.")
        }
    }

    @ViewBuilder private var fitSection: some View {
        Section {
            if !references.isEmpty {
                LabeledContent("Largest difference now", value: centimetres(report.worstMetres))
            }
            if isPointCloud {
                Button { makeCopy("Fitted copy") { try store.saveFittedCopy(of: scan, in: project, references: references) } } label: {
                    HStack {
                        Label("Create fitted copy", systemImage: "scope")
                        if busy { Spacer(); ProgressView() }
                    }
                }.disabled(busy || !canFit)
            }
            if let copy {
                Label(copyTitle + " saved as a separate scan", systemImage: "checkmark.circle")
                NavigationLink("Open the copy") {
                    ModelViewerView(scan: copy, project: project).environmentObject(store)
                }
            }
        } header: { Text("Fit the scan to these references") } footer: {
            Text(fitExplanation)
        }
    }

    private var fitExplanation: String {
        if !isPointCloud { return "Fitted copies are made for point-cloud scans. Other scans can be checked here." }
        if canFit {
            return hasWalkRecording
                ? "Makes a new scan in which the stretches of the walk are moved so the references hold, keeping each stretch's shape. This scan stays as it is."
                : "This scan has no walk recording, so the copy is only turned and shifted as a whole onto the control points. This scan stays as it is."
        }
        if hasWalkRecording { return "Add a known distance, a straight line, or two control points to fit the scan." }
        return "Without a walk recording a scan cannot be bent to a distance or a straight line. Add two or more control points to place it in their coordinates."
    }

    // MARK: Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        do { references = try store.loadReferences(for: scan, in: project) }
        catch { failure = "Saved references could not be read: " + error.localizedDescription }
    }

    private func persist() {
        failure = nil
        do { try store.saveReferences(references, for: scan, in: project) }
        catch { failure = "References were not saved: " + error.localizedDescription }
    }

    private func number(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }

    private func vector(_ p: SIMD3<Float>) -> [Double] { [Double(p.x), Double(p.y), Double(p.z)] }

    private func addDistance() {
        defer { pendingDistance = nil }
        guard let measurement = pendingDistance, measurement.points.count == 2 else { return }
        guard let known = number(lengthText), known > 0, known < 100_000 else {
            failure = "Enter the known length in metres, for example 18.25."
            return
        }
        references.distances.append(ScanReferenceDocument.KnownDistance(name: pendingName,
            a: vector(measurement.points[0]), b: vector(measurement.points[1]), knownMetres: known))
        persist()
    }

    private func addLine(_ measurement: ScanMeasurement, name: String) {
        guard measurement.points.count >= 3 else { return }
        references.lines.append(ScanReferenceDocument.StraightLine(name: name, points: measurement.points.map(vector)))
        persist()
    }

    private func addControl() {
        defer { pendingPoint = nil }
        guard let point = pendingPoint else { return }
        guard let east = number(eastText), let north = number(northText), let height = number(heightText) else {
            failure = "Enter east, north and height in metres."
            return
        }
        references.controls.append(ScanReferenceDocument.ControlPoint(name: pendingName, point: vector(point),
                                                                      east: east, north: north, height: height))
        persist()
    }

    private func makeCopy(_ title: String, _ work: @escaping () throws -> Scan) {
        busy = true; failure = nil; copy = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work() }
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let saved): copy = saved; copyTitle = title
                case .failure(let error): failure = title + " was not made: " + error.localizedDescription
                }
            }
        }
    }

    // MARK: Text

    private func metres(_ value: Double) -> String { String(format: "%.3f m", value) }

    private func centimetres(_ value: Double) -> String {
        abs(value) < 0.0995 ? String(format: "%.1f cm", value * 100) : String(format: "%.2f m", value)
    }

    private func signed(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : "−"
        return sign + centimetres(abs(value))
    }
}
