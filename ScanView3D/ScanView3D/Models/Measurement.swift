import Foundation
import simd

/// A measurement saved with a scan. Points are in the scan's world space (metres,
/// Y up = gravity), i.e. the same space the viewer shows the model in.
struct ScanMeasurement: Identifiable, Codable, Equatable {

    enum Kind: String, Codable, CaseIterable {
        case distance = "Distance"
        case height = "Height"
        case wallToWall = "Wall↔Wall"
        case path = "Path"
        case area = "Area"
        case elevation = "Elevation"

        var icon: String {
            switch self {
            case .distance: return "ruler"
            case .height: return "arrow.up.and.down"
            case .wallToWall: return "arrow.left.and.right.square"
            case .path: return "point.topleft.down.curvedto.point.bottomright.up"
            case .area: return "square.dashed"
            case .elevation: return "mountain.2"
            }
        }

        /// One-line instruction shown while this tool is active.
        var hint: String {
            switch self {
            case .distance: return "Place two points. Snaps to corners, edges, vertical and wall directions."
            case .height: return "Place one point — finds the surfaces straight above and below it."
            case .wallToWall: return "Place a point on each of two surfaces — gives the true perpendicular gap."
            case .path: return "Place points along a route, then tap Done."
            case .area: return "Place the corners of an area, then tap Done."
            case .elevation: return "Place points to read their height compared to the first one."
            }
        }

        /// Points after which the measurement completes by itself (nil = finish with Done).
        var autoCompleteCount: Int? {
            switch self {
            case .distance, .wallToWall: return 2
            case .height: return 1
            case .path, .area, .elevation: return nil
            }
        }

        var minimumPoints: Int {
            switch self {
            case .height, .elevation: return 1
            case .distance, .wallToWall, .path: return 2
            case .area: return 3
            }
        }

        /// Whether snapping along vertical / wall directions from the previous point applies.
        var usesAxisSnapping: Bool {
            self == .distance || self == .path || self == .area
        }
    }

    var id = UUID()
    var kind: Kind
    var points: [SIMD3<Float>]
    /// Wall↔Wall: the fitted surface normal at each point.
    var normals: [SIMD3<Float>] = []
    var createdAt = Date()

    // MARK: - Values

    var straightDistance: Float {
        guard points.count >= 2 else { return 0 }
        return simd_distance(points[0], points[points.count - 1])
    }

    var heightDifference: Float {
        guard points.count >= 2 else { return 0 }
        return points[points.count - 1].y - points[0].y
    }

    var horizontalDistance: Float {
        guard points.count >= 2 else { return 0 }
        let d = points[points.count - 1] - points[0]
        return (d.x * d.x + d.z * d.z).squareRoot()
    }

    var pathLength: Float {
        guard points.count >= 2 else { return 0 }
        var total: Float = 0
        for i in 1..<points.count { total += simd_distance(points[i - 1], points[i]) }
        return total
    }

    /// Perpendicular distance between the two surfaces, and whether they were
    /// parallel enough to call it a true wall-to-wall distance.
    var perpendicularGap: (distance: Float, parallel: Bool) {
        guard points.count >= 2 else { return (0, false) }
        let delta = points[1] - points[0]
        guard normals.count >= 2 else { return (simd_length(delta), false) }
        let n1 = normals[0], n2 = normals[1]
        let cosAngle = simd_dot(n1, n2)
        if abs(cosAngle) > cos(Float.pi / 18) {          // within 10°
            let n = simd_normalize(cosAngle >= 0 ? n1 + n2 : n1 - n2)
            return (abs(simd_dot(n, delta)), true)
        }
        return (abs(simd_dot(n1, delta)), false)
    }

    /// Area of the outline. Mostly-horizontal outlines (floors, land) use the
    /// plan (map) area, which is what surveyors quote; tilted or vertical ones
    /// use the area on their own best-fit plane.
    var area: (value: Float, isPlan: Bool) {
        guard points.count >= 3 else { return (0, true) }
        let plane = GeometryMath.fitPlane(points)
        let normal = plane?.normal ?? SIMD3<Float>(0, 1, 0)
        let isPlan = abs(normal.y) > cos(Float.pi * 25 / 180)
        let n = isPlan ? SIMD3<Float>(0, 1, 0) : normal
        // Newell's method projected onto n: 0.5 * |Σ (p_i × p_{i+1}) · n|
        var sum = SIMD3<Float>(0, 0, 0)
        for i in 0..<points.count {
            sum += simd_cross(points[i], points[(i + 1) % points.count])
        }
        return (abs(simd_dot(sum, n)) * 0.5, isPlan)
    }

    // MARK: - Text

    /// Short text for the list of measurements.
    func summary(unit: ScanSettings.MeasurementUnit) -> String {
        switch kind {
        case .distance:
            return unit.format(meters: straightDistance)
        case .height:
            return "↕ " + unit.format(meters: abs(heightDifference))
        case .wallToWall:
            let gap = perpendicularGap
            return (gap.parallel ? "⊥ " : "⊥≈ ") + unit.format(meters: gap.distance)
        case .path:
            return "Path " + unit.format(meters: pathLength)
        case .area:
            let a = area
            return (a.isPlan ? "Area " : "Surface ") + unit.format(squareMeters: a.value)
        case .elevation:
            guard let first = points.first, let last = points.last, points.count > 1 else { return "Elevation (ref)" }
            return "Elev. " + signed(last.y - first.y, unit: unit)
        }
    }

    /// Longer description for export.
    func details(unit: ScanSettings.MeasurementUnit) -> String {
        switch kind {
        case .distance:
            return "3D \(unit.format(meters: straightDistance)); height \(unit.format(meters: abs(heightDifference))); horizontal \(unit.format(meters: horizontalDistance))"
        case .height:
            return "vertical \(unit.format(meters: abs(heightDifference)))"
        case .wallToWall:
            let gap = perpendicularGap
            return gap.parallel ? "surfaces parallel" : "surfaces not parallel (distance to first surface)"
        case .path:
            return "\(points.count) points"
        case .area:
            let a = area
            return a.isPlan ? "plan (horizontal) area; perimeter \(unit.format(meters: perimeter))"
                            : "area on sloped plane; perimeter \(unit.format(meters: perimeter))"
        case .elevation:
            guard let first = points.first else { return "" }
            return points.enumerated().map { "P\($0.offset + 1) \(signed($0.element.y - first.y, unit: unit))" }
                .joined(separator: "; ")
        }
    }

    var perimeter: Float {
        guard points.count >= 2 else { return 0 }
        return pathLength + simd_distance(points[points.count - 1], points[0])
    }

    /// Labels to draw in the 3D view: (position, text).
    func labels(unit: ScanSettings.MeasurementUnit) -> [(SIMD3<Float>, String)] {
        guard let first = points.first else { return [] }
        switch kind {
        case .distance:
            guard points.count >= 2 else { return [] }
            var text = unit.format(meters: straightDistance)
            if abs(heightDifference) >= 0.01 && horizontalDistance >= 0.01 {
                text += "  ↕ " + unit.format(meters: abs(heightDifference))
            }
            return [((points[0] + points[1]) / 2, text)]
        case .height:
            guard points.count >= 2 else { return [] }
            return [((points[0] + points[1]) / 2, summary(unit: unit))]
        case .wallToWall:
            guard points.count >= 2 else { return [] }
            return [((points[0] + points[1]) / 2, summary(unit: unit))]
        case .path:
            guard let last = points.last, points.count >= 2 else { return [] }
            return [(last, summary(unit: unit))]
        case .area:
            guard points.count >= 3 else { return [] }
            let centroid = points.reduce(SIMD3<Float>(0, 0, 0), +) / Float(points.count)
            return [(centroid, summary(unit: unit))]
        case .elevation:
            return points.enumerated().map { i, p in
                (p, i == 0 ? "0 (ref)" : signed(p.y - first.y, unit: unit))
            }
        }
    }

    private func signed(_ value: Float, unit: ScanSettings.MeasurementUnit) -> String {
        (value >= 0 ? "+" : "−") + unit.format(meters: abs(value))
    }

    // MARK: - Export

    static func csv(_ measurements: [ScanMeasurement], unit: ScanSettings.MeasurementUnit) -> String {
        func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["Type,Value,Details,Points (x y z in metres)"]
        for m in measurements {
            let pts = m.points.map { String(format: "%.3f %.3f %.3f", $0.x, $0.y, $0.z) }.joined(separator: "; ")
            lines.append([quote(m.kind.rawValue), quote(m.summary(unit: unit)),
                          quote(m.details(unit: unit)), quote(pts)].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
