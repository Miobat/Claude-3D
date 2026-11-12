import Foundation
import simd

// Checking a scan against things measured independently, and fitting it to them.
//
// Three kinds of reference, all marked on the scan with the ordinary Measure
// tools and then given their real-world value:
//   • a known distance (tape) between two points,
//   • a straight line: points known to lie on one straight edge or string line,
//   • control points with surveyed coordinates (east, north, height).
//
// Checking never changes anything. Fitting makes a corrected COPY: the walk's
// segments are moved so the references hold, while neighbouring segments keep
// their measured relative pose as far as the references allow. A scan without a
// walk recording can only be turned and shifted as a whole onto control points.

/// Sidecar next to a scan: `<base>_references.json`. Points are in the saved
/// model's coordinates (metres, Y up), copied when the reference was added.
struct ScanReferenceDocument: Codable, Equatable {
    static let suffix = "_references.json"
    static let maximumBytes = 2_000_000

    struct KnownDistance: Codable, Equatable, Identifiable {
        var id = UUID()
        var name: String
        var a: [Double]
        var b: [Double]
        var knownMetres: Double
    }

    struct StraightLine: Codable, Equatable, Identifiable {
        var id = UUID()
        var name: String
        var points: [[Double]]
    }

    struct ControlPoint: Codable, Equatable, Identifiable {
        var id = UUID()
        var name: String
        var point: [Double]
        var east: Double
        var north: Double
        var height: Double
    }

    var version = 1
    var distances: [KnownDistance] = []
    var lines: [StraightLine] = []
    var controls: [ControlPoint] = []

    var isEmpty: Bool { distances.isEmpty && lines.isEmpty && controls.isEmpty }

    static func vector(_ values: [Double]) -> SIMD3<Double>? {
        guard values.count == 3, values.allSatisfy({ $0.isFinite }) else { return nil }
        return SIMD3<Double>(values[0], values[1], values[2])
    }

    func validate() throws {
        guard version == 1, distances.count <= 200, lines.count <= 50, controls.count <= 200,
              distances.allSatisfy({ ScanReferenceDocument.vector($0.a) != nil && ScanReferenceDocument.vector($0.b) != nil
                  && $0.knownMetres.isFinite && $0.knownMetres > 0 && $0.knownMetres < 100_000 }),
              lines.allSatisfy({ $0.points.count >= 3 && $0.points.count <= 200
                  && $0.points.allSatisfy { ScanReferenceDocument.vector($0) != nil } }),
              controls.allSatisfy({ ScanReferenceDocument.vector($0.point) != nil
                  && $0.east.isFinite && $0.north.isFinite && $0.height.isFinite }) else {
            throw ScanAlignmentError.invalidDocument
        }
    }
}

enum DriftReferences {
    struct DistanceCheck: Identifiable, Equatable {
        var id: UUID
        var name: String
        var scanMetres: Double
        var knownMetres: Double
        var deviation: Double { scanMetres - knownMetres }
    }

    struct LineCheck: Identifiable, Equatable {
        var id: UUID
        var name: String
        var lengthMetres: Double
        /// Largest sideways distance of a marked point from the straight line
        /// through the first and last point.
        var largestOffsetMetres: Double
    }

    struct ControlCheck: Identifiable, Equatable {
        var id: UUID
        var name: String
        /// Distance left after turning and shifting the whole scan onto the
        /// control points (nil with fewer than two).
        var residualMetres: Double?
    }

    struct Report: Equatable {
        var distances: [DistanceCheck] = []
        var lines: [LineCheck] = []
        var controls: [ControlCheck] = []
        var worstMetres: Double {
            max(distances.map { abs($0.deviation) }.max() ?? 0, lines.map(\.largestOffsetMetres).max() ?? 0,
                controls.compactMap(\.residualMetres).max() ?? 0)
        }
    }

    /// Surveyed coordinates in the scan's axis convention: X east, Y up, Z south.
    static func axes(east: Double, north: Double, height: Double) -> SIMD3<Double> {
        SIMD3<Double>(east, height, -north)
    }

    /// Whole-metre origin near the control points, so fitted copies keep
    /// millimetre precision in 32-bit point files. Returned as east, north, height.
    static func siteOrigin(_ controls: [ScanReferenceDocument.ControlPoint]) -> [Double] {
        guard !controls.isEmpty else { return [0, 0, 0] }
        let n = Double(controls.count)
        return [(controls.map(\.east).reduce(0, +) / n).rounded(), (controls.map(\.north).reduce(0, +) / n).rounded(),
                (controls.map(\.height).reduce(0, +) / n).rounded()]
    }

    static func offset(_ point: SIMD3<Double>, from a: SIMD3<Double>, to b: SIMD3<Double>) -> SIMD3<Double> {
        let span = b - a
        let length = simd_length(span)
        guard length > 1e-9 else { return point - a }
        let u = span / length
        let v = point - a
        return v - u * simd_dot(v, u)
    }

    /// Pure check: how the scan as it stands compares with the references.
    static func report(_ document: ScanReferenceDocument) -> Report {
        var report = Report()
        for item in document.distances {
            guard let a = ScanReferenceDocument.vector(item.a), let b = ScanReferenceDocument.vector(item.b) else { continue }
            report.distances.append(DistanceCheck(id: item.id, name: item.name, scanMetres: simd_distance(a, b),
                                                  knownMetres: item.knownMetres))
        }
        for item in document.lines {
            let points = item.points.compactMap(ScanReferenceDocument.vector)
            guard points.count >= 3, let first = points.first, let last = points.last else { continue }
            let worst = points.dropFirst().dropLast().map { simd_length(offset($0, from: first, to: last)) }.max() ?? 0
            report.lines.append(LineCheck(id: item.id, name: item.name, lengthMetres: simd_distance(first, last),
                                          largestOffsetMetres: worst))
        }
        let origin = siteOrigin(document.controls)
        let scan = document.controls.compactMap { ScanReferenceDocument.vector($0.point) }
        let site = document.controls.map { axes(east: $0.east - origin[0], north: $0.north - origin[1], height: $0.height - origin[2]) }
        let fit = scan.count == site.count && scan.count >= 2 ? DriftMath.yawFit(site, scan) : nil
        for (index, item) in document.controls.enumerated() {
            var residual: Double?
            if let fit, index < scan.count { residual = simd_distance(fit.apply(site[index]), scan[index]) }
            report.controls.append(ControlCheck(id: item.id, name: item.name, residualMetres: residual))
        }
        return report
    }

    struct FitResult {
        /// Corrected points, in the output frame (site-local when control points were used).
        var points: [SIMD3<Float>]
        /// Segment poses of the corrected copy (output frame).
        var poses: [RigidPose]
        /// Output frame ← input (saved) frame; identity without control points.
        var frame: RigidPose
        var siteOrigin: [Double]?
        /// The references as they stand in the corrected copy.
        var references: ScanReferenceDocument
        var report: Report
        var largestMoveMetres: Double
    }

    private static func nearestSegment(to point: SIMD3<Double>, points: [SIMD3<Float>], segments: [UInt16]) -> Int {
        var best = 0
        var bestDistance = Float.greatestFiniteMagnitude
        let p = SIMD3<Float>(Float(point.x), Float(point.y), Float(point.z))
        for i in 0..<points.count {
            let d = simd_distance_squared(points[i], p)
            if d < bestDistance { bestDistance = d; best = i }
        }
        return points.isEmpty ? 0 : Int(segments[best])
    }

    /// Fits a point cloud to its references.
    /// - poses: current pose of each segment; `captured`: poses the odometry is
    ///   read from; `links`: stored overlaps (may be empty). A scan without a walk
    ///   recording passes one identity segment and is only moved as a whole.
    static func fit(points: [SIMD3<Float>], segments: [UInt16], poses: [RigidPose], captured: [RigidPose],
                    links: [DriftRefiner.Link], up: SIMD3<Double>, references: ScanReferenceDocument,
                    cancelled: () -> Bool = { false }) throws -> FitResult {
        try references.validate()
        let count = poses.count
        guard count >= 1, captured.count == count, points.count == segments.count,
              segments.allSatisfy({ Int($0) < count }) else { throw ScanAlignmentError.invalidDocument }
        let useControls = references.controls.count >= 2
        let movable = count >= 2
        guard useControls || (movable && (!references.distances.isEmpty || !references.lines.isEmpty)) else {
            throw ScanAlignmentError.nothingToFit
        }
        struct Mark { var node: Int; var local: SIMD3<Double> }
        func mark(_ values: [Double]) throws -> Mark {
            guard let p = ScanReferenceDocument.vector(values) else { throw ScanAlignmentError.invalidDocument }
            let node = nearestSegment(to: p, points: points, segments: segments)
            return Mark(node: node, local: poses[node].applyInverse(p))
        }
        var nodes = poses
        let graph: DriftGraph
        let origin = DriftReferences.siteOrigin(references.controls)
        var siteIndex: Int?
        var controlMarks: [(mark: Mark, site: SIMD3<Double>)] = []
        if useControls {
            for control in references.controls {
                let attached = try mark(control.point)
                let site = axes(east: control.east - origin[0], north: control.north - origin[1], height: control.height - origin[2])
                controlMarks.append((attached, site))
            }
            let sitePoints = controlMarks.map { $0.site }
            let scanPoints = controlMarks.map { nodes[$0.mark.node].apply($0.mark.local) }
            guard let start = DriftMath.yawFit(sitePoints, scanPoints) else { throw ScanAlignmentError.fitFailed }
            nodes.append(start)
            siteIndex = count
        }
        graph = DriftGraph(poses: nodes)
        DriftRefiner.addCaptureConstraints(to: graph, captured: captured, links: links, up: up)
        if movable {
            for item in references.distances {
                let a = try mark(item.a), b = try mark(item.b)
                let known = item.knownMetres
                graph.add(nodes: [a.node, b.node]) { x in
                    [(simd_distance(x[a.node].apply(a.local), x[b.node].apply(b.local)) - known) / 0.001]
                }
            }
            for item in references.lines {
                let marks = try item.points.map(mark)
                guard marks.count >= 3 else { continue }
                graph.add(nodes: marks.map { $0.node }) { x in
                    let world = marks.map { x[$0.node].apply($0.local) }
                    var out: [Double] = []
                    for p in world.dropFirst().dropLast() {
                        let e = offset(p, from: world[0], to: world[world.count - 1]) / 0.001
                        out.append(contentsOf: [e.x, e.y, e.z])
                    }
                    return out
                }
            }
        }
        if let siteIndex {
            // The site frame is level: only its heading and position are unknown.
            let side = abs(up.y) > 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
            let e1 = simd_normalize(simd_cross(up, side)), e2 = simd_cross(up, e1)
            let siteUp = SIMD3<Double>(0, 1, 0)
            graph.add(nodes: [siteIndex]) { x in
                let d = x[siteIndex].rotate(siteUp) - up
                return [simd_dot(d, e1) / 1e-4, simd_dot(d, e2) / 1e-4]
            }
            for entry in controlMarks {
                let node = entry.mark.node, local = entry.mark.local, site = entry.site
                graph.add(nodes: [node, siteIndex]) { x in
                    let e = (x[node].apply(local) - x[siteIndex].apply(site)) / 0.003
                    return [e.x, e.y, e.z]
                }
            }
        }
        let before = graph.cost(graph.x)
        let after = graph.solve(iterations: 25, cancelled: cancelled)
        if cancelled() { throw CancellationError() }
        guard after.isFinite, after <= before else { throw ScanAlignmentError.fitFailed }
        let solved = graph.x
        var newPoses = Array(solved.prefix(count))
        var largest = 0.0
        for k in 0..<count {
            let delta = newPoses[k].composed(with: poses[k].inverse)
            largest = max(largest, simd_distance(newPoses[k].t, poses[k].t) + delta.magnitude.angle * 2)
        }
        guard largest.isFinite, largest < 50 else { throw ScanAlignmentError.fitFailed }
        var moved = DriftRefiner.move(points: points, segments: segments, from: poses, to: newPoses)

        // Express the copy in site-local coordinates when control points exist.
        var frame = RigidPose.identity
        if let siteIndex { frame = solved[siteIndex].inverse }
        if siteIndex != nil {
            for i in 0..<moved.count {
                let p = frame.apply(moved[i])
                moved[i] = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
            }
            newPoses = newPoses.map { frame.composed(with: $0) }
        }
        // Carry the references into the copy so its own report can be shown.
        var carried = references
        func place(_ values: [Double]) throws -> [Double] {
            let m = try mark(values)
            let p = frame.apply(solved[m.node].apply(m.local))
            return [p.x, p.y, p.z]
        }
        for i in carried.distances.indices {
            carried.distances[i].a = try place(carried.distances[i].a)
            carried.distances[i].b = try place(carried.distances[i].b)
        }
        for i in carried.lines.indices { carried.lines[i].points = try carried.lines[i].points.map(place) }
        for i in carried.controls.indices { carried.controls[i].point = try place(carried.controls[i].point) }
        return FitResult(points: moved, poses: newPoses, frame: frame, siteOrigin: siteIndex == nil ? nil : origin,
                         references: carried, report: report(carried), largestMoveMetres: largest)
    }
}
