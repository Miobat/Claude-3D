import Foundation
import simd

// What a long point-cloud capture records so drift can be corrected afterwards.
//
// The walk is cut into SEGMENTS (about 1.5 m of walking, or a 30° turn). Each
// segment owns an ARKit anchor placed at the phone's pose when it started. ARKit
// keeps moving its anchors as it refines its own map, so comparing an anchor's
// transform at the end of the capture with the one it had when the segment's
// points were recorded gives the phone's own correction for those points.
// Every saved point remembers its segment (two bytes).

/// Recorded by the scanner; travels with the pending capture (and its recovery
/// checkpoint) until the scan is saved.
struct AlignmentCapture: Codable, Equatable {
    struct Segment: Codable, Equatable {
        /// Anchor transform while this segment's points were recorded (16, column-major).
        var reference: [Float]
        /// The same anchor's transform when the capture ended.
        var end: [Float]
        /// Seconds since the capture started.
        var startTime: Double
    }

    static let maximumSegments = 200
    var version = 1
    var spacingMetres: Float
    var segments: [Segment]
    /// Walked path, packed Float32: time, x, y, z, qx, qy, qz, qw per sample.
    var path: Data
    var pathLengthMetres: Double
    /// Sudden position changes: the phone re-recognised a place and snapped back.
    var trackingJumps: Int
    /// Seconds spent turning faster than about 60° per second.
    var fastTurnSeconds: Double

    var isUsable: Bool {
        version == 1 && !segments.isEmpty && segments.count <= AlignmentCapture.maximumSegments
            && spacingMetres.isFinite && spacingMetres > 0
            && segments.allSatisfy { $0.reference.count == 16 && $0.end.count == 16
                && $0.reference.allSatisfy({ $0.isFinite }) && $0.end.allSatisfy({ $0.isFinite }) }
            && path.count % 32 == 0 && pathLengthMetres.isFinite
    }

    static func matrix(_ m: [Float]) -> simd_float4x4? {
        guard m.count == 16, m.allSatisfy({ $0.isFinite }) else { return nil }
        return simd_float4x4(SIMD4<Float>(m[0], m[1], m[2], m[3]), SIMD4<Float>(m[4], m[5], m[6], m[7]),
                             SIMD4<Float>(m[8], m[9], m[10], m[11]), SIMD4<Float>(m[12], m[13], m[14], m[15]))
    }

    static func array(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }
}

/// Decides when a new segment starts and keeps the walked path. Pure logic so
/// it is tested without a camera. Used on the main thread only.
struct CaptureSegmenter {
    static let fastTurnHint = "Turn slowly — fast turns bend long scans"
    static let pivotHint = "Step sideways while you turn — turning on the spot bends long scans"

    private(set) var segmentCount = 0
    private(set) var pathLength = 0.0
    private(set) var jumps = 0
    private(set) var fastTurnSeconds = 0.0
    private(set) var hint: String?
    private(set) var path = Data()

    private var startTime: Double?
    private var segmentStartPose: simd_float4x4?
    private var segmentStartTime = 0.0
    private var lastPose: simd_float4x4?
    private var lastTime = 0.0
    private var lastSamplePose: simd_float4x4?
    private var lastSampleTime = -Double.infinity
    private var framePosition: SIMD3<Float>?
    private var frameTime = 0.0
    private var pendingBreak = false
    private var anchorRestarts = 0
    private var recent: [(dt: Double, turn: Float, move: Float)] = []
    private var hintUntil = 0.0
    private static let maximumPathSamples = 20_000

    /// Seconds since the first accepted pose.
    func elapsed(_ time: Double) -> Double { time - (startTime ?? time) }

    private static func position(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    static func angle(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        func rotation(_ m: simd_float4x4) -> simd_float3x3 {
            simd_float3x3(SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                          SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                          SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        }
        let r = rotation(a).transpose * rotation(b)
        let trace = r[0].x + r[1].y + r[2].z
        return acos(max(-1, min(1, (trace - 1) / 2)))
    }

    /// Every camera frame (60 per second): spots the phone snapping to a new
    /// position, which no hand movement produces.
    mutating func noteFrame(time: Double, position: SIMD3<Float>) {
        defer { framePosition = position; frameTime = time }
        guard let previous = framePosition else { return }
        let dt = time - frameTime
        guard dt > 0, dt <= 0.1 else { return }
        let moved = simd_distance(previous, position)
        if moved > 0.04, Double(moved) / dt > 2.5 {
            jumps += 1
            pendingBreak = true
        }
    }

    /// The session was paused, interrupted or resumed: poses before and after
    /// must not share a segment.
    mutating func noteDiscontinuity() {
        pendingBreak = true
        framePosition = nil
        lastPose = nil
        recent.removeAll()
    }

    /// Call for each accepted capture tick, before its depth is recorded.
    /// - anchorMoved: ARKit has moved the active segment's anchor noticeably.
    /// - Returns: true when a new segment must start at this pose.
    mutating func update(time: Double, pose: simd_float4x4, anchorMoved: Bool) -> Bool {
        if startTime == nil { startTime = time }
        if let previous = lastPose, time > lastTime, time - lastTime <= 1 {
            let dt = time - lastTime
            let move = simd_distance(CaptureSegmenter.position(previous), CaptureSegmenter.position(pose))
            let turn = CaptureSegmenter.angle(previous, pose)
            if move < 3 { pathLength += Double(move) }
            if Double(turn) / dt > 60 * .pi / 180 { fastTurnSeconds += dt }
            recent.append((dt, turn, move))
            if recent.count > 20 { recent.removeFirst(recent.count - 20) }
            updateHint(time: time)
        }
        lastPose = pose
        lastTime = time
        recordPath(time: time, pose: pose)

        var start = segmentStartPose == nil || pendingBreak
        if !start, let origin = segmentStartPose, segmentCount < AlignmentCapture.maximumSegments {
            // Longer stretches once many segments exist, so very long walks still fit.
            let stretch: Float = segmentCount < 100 ? 1 : (segmentCount < 150 ? 2 : 4)
            let age = time - segmentStartTime
            let moved = simd_distance(CaptureSegmenter.position(origin), CaptureSegmenter.position(pose))
            let turned = CaptureSegmenter.angle(origin, pose)
            if moved >= 1.5 * stretch { start = true }
            else if turned >= 30 * .pi / 180, age >= 0.4 { start = true }
            else if age >= 12 * Double(stretch), moved >= 0.3 { start = true }
            else if anchorMoved, age >= (anchorRestarts < 60 ? 0.15 : 2) {
                // Points recorded after the phone moved this stretch's anchor are
                // already in the corrected frame: they need their own record at
                // once, or the correction would later be applied to them twice.
                // The budget keeps a jittery anchor from using up every segment.
                start = true; anchorRestarts += 1
            }
        }
        guard start, segmentCount < AlignmentCapture.maximumSegments else {
            pendingBreak = false
            return false
        }
        pendingBreak = false
        segmentStartPose = pose
        segmentStartTime = time
        segmentCount += 1
        return true
    }

    private mutating func updateHint(time: Double) {
        var windowTurn: Float = 0, windowMove: Float = 0, shortTurn: Float = 0, shortTime = 0.0
        for (index, entry) in recent.enumerated() {
            windowTurn += entry.turn; windowMove += entry.move
            if index >= recent.count - 5 { shortTurn += entry.turn; shortTime += entry.dt }
        }
        if shortTime > 0.3, Double(shortTurn) / shortTime > 60 * .pi / 180 {
            hint = CaptureSegmenter.fastTurnHint; hintUntil = time + 2
        } else if recent.count >= 12, windowTurn > 70 * .pi / 180, windowMove < 0.4 {
            hint = CaptureSegmenter.pivotHint; hintUntil = time + 2
        } else if time >= hintUntil {
            hint = nil
        }
    }

    private mutating func recordPath(time: Double, pose: simd_float4x4) {
        guard path.count / 32 < CaptureSegmenter.maximumPathSamples else { return }
        if let last = lastSamplePose {
            let moved = simd_distance(CaptureSegmenter.position(last), CaptureSegmenter.position(pose))
            guard moved >= 0.1 || CaptureSegmenter.angle(last, pose) >= 5 * .pi / 180 || time - lastSampleTime >= 1 else { return }
        }
        lastSamplePose = pose
        lastSampleTime = time
        let q = simd_quatf(pose)
        let p = CaptureSegmenter.position(pose)
        for value in [Float(elapsed(time)), p.x, p.y, p.z, q.imag.x, q.imag.y, q.imag.z, q.real] {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { path.append(contentsOf: $0) }
        }
    }
}

/// Stored with the scan (library index) and shown under Info.
struct ScanAlignmentSummary: Codable, Equatable {
    var version = 1
    var pathLengthMetres: Double
    var segmentCount: Int
    var trackingJumps: Int
    var fastTurnSeconds: Double
    /// Largest correction the phone itself made to a stretch of the walk.
    var phoneCorrectionMetres: Double
    /// `DriftRefiner.Result` raw value, or "off" / "notRun" / "tooSparse".
    var overlap: String
    /// How far apart two passes over the same place were, at worst.
    var disagreementMetres: Double?
    var mismatchBeforeMetres: Double?
    var mismatchAfterMetres: Double?
    /// Largest distance any stretch of the scan was moved in total.
    var largestMoveMetres: Double
    /// Saved points differ from the as-captured positions.
    var corrected: Bool
    var fittedToReferences: Bool?
    var asCapturedCopy: Bool?
    /// East, north, height subtracted from control coordinates in a fitted copy.
    var siteOrigin: [Double]?

    /// The summary is written into the library index (JSON), which refuses
    /// non-finite numbers: a report value must never be what fails a save.
    var sanitised: ScanAlignmentSummary {
        func number(_ value: Double) -> Double { value.isFinite ? value : 0 }
        func optional(_ value: Double?) -> Double? {
            guard let value, value.isFinite else { return nil }
            return value
        }
        var copy = self
        copy.pathLengthMetres = number(pathLengthMetres)
        copy.fastTurnSeconds = number(fastTurnSeconds)
        copy.phoneCorrectionMetres = number(phoneCorrectionMetres)
        copy.disagreementMetres = optional(disagreementMetres)
        copy.mismatchBeforeMetres = optional(mismatchBeforeMetres)
        copy.mismatchAfterMetres = optional(mismatchAfterMetres)
        copy.largestMoveMetres = number(largestMoveMetres)
        if let origin = siteOrigin, !(origin.count == 3 && origin.allSatisfy({ $0.isFinite })) { copy.siteOrigin = nil }
        return copy
    }

    var overlapDescription: String {
        switch overlap {
        case DriftRefiner.Result.applied.rawValue: return "Passes lined up"
        case DriftRefiner.Result.passesAgree.rawValue: return "Passes already agreed — nothing changed"
        case DriftRefiner.Result.noOverlap.rawValue: return "No place was scanned twice — nothing to line up"
        case DriftRefiner.Result.noImprovement.rawValue: return "No clear improvement found — left as captured"
        case "off": return "Drift correction was turned off — saved as captured"
        case "tooShort": return "Short scan — saved exactly as captured"
        case "tooSparse": return "Point spacing too coarse to line up passes"
        default: return "Not checked"
        }
    }
}

enum ScanAlignmentError: LocalizedError {
    case invalidDocument, staleModel, noSegments, fitFailed, nothingToFit, recordNotSaved
    var errorDescription: String? {
        switch self {
        case .recordNotSaved: return "The drift record could not be stored with the scan."
        case .invalidDocument: return "This scan's alignment record cannot be read. The scan itself is unchanged."
        case .staleModel: return "The alignment record does not belong to this version of the scan."
        case .noSegments: return "This scan has no walk recording, so it cannot be re-aligned."
        case .fitFailed: return "The references could not be fitted. Check the entered values. The scan is unchanged."
        case .nothingToFit: return "Add a straight line, a known distance or control points first."
        }
    }
}

/// Sidecar next to a saved point cloud. Everything is in the saved model's
/// coordinates unless stated. Bound to the model file by its SHA-256, because
/// `pointSegments` follows the file's point order.
struct ScanAlignmentDocument: Codable {
    static let suffix = "_alignment.json"
    static let maximumBytes = 96_000_000

    struct Segment: Codable, Equatable {
        /// Pose as recorded (16, column-major, saved frame).
        var captured: [Double]
        /// Pose after the phone's own corrections.
        var phone: [Double]
        /// Pose the saved points use.
        var saved: [Double]
        var startTime: Double
    }

    struct StoredLink: Codable, Equatable {
        var a: Int
        var b: Int
        /// Float32 × 9 per correspondence: qa, qb, nb (segment-local).
        var packed: Data
    }

    var version = 1
    var modelSHA256: String
    var pointCount: Int
    var spacingMetres: Double
    /// Gravity ("up") in the saved frame.
    var up: [Double]
    /// Capture frame → saved frame (16, column-major).
    var captureToSaved: [Double]
    var summary: ScanAlignmentSummary
    var segments: [Segment]
    var links: [StoredLink]
    /// UInt16 (little endian) per point, in the model file's order.
    var pointSegments: Data
    /// Walked path in the capture frame (see `AlignmentCapture.path`).
    var path: Data

    func validate() throws {
        guard version == 1, MeasurementModelRevision.validHash(modelSHA256), pointCount >= 0,
              pointSegments.count == pointCount * 2, !segments.isEmpty,
              segments.count <= AlignmentCapture.maximumSegments, up.count == 3, up.allSatisfy({ $0.isFinite }),
              RigidPose(array: captureToSaved) != nil, spacingMetres.isFinite, spacingMetres > 0,
              segments.allSatisfy({ RigidPose(array: $0.captured) != nil && RigidPose(array: $0.phone) != nil
                  && RigidPose(array: $0.saved) != nil }),
              links.allSatisfy({ $0.a >= 0 && $0.b >= 0 && $0.a < segments.count && $0.b < segments.count
                  && $0.packed.count % 36 == 0 }),
              path.count % 32 == 0 else { throw ScanAlignmentError.invalidDocument }
    }

    var capturedPoses: [RigidPose] { segments.compactMap { RigidPose(array: $0.captured) } }
    var phonePoses: [RigidPose] { segments.compactMap { RigidPose(array: $0.phone) } }
    var savedPoses: [RigidPose] { segments.compactMap { RigidPose(array: $0.saved) } }

    static func packSegments(_ segments: [UInt16]) -> Data {
        var data = Data(capacity: segments.count * 2)
        for value in segments { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    static func unpackSegments(_ data: Data) -> [UInt16] {
        let count = data.count / 2
        var out = [UInt16](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count { out[i] = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)) }
        }
        return out
    }

    static func packLink(_ link: DriftRefiner.Link) -> StoredLink {
        var data = Data(capacity: link.qa.count * 36)
        for k in 0..<link.qa.count {
            for v in [link.qa[k], link.qb[k], link.nb[k]] {
                for value in [Float(v.x), Float(v.y), Float(v.z)] {
                    withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
                }
            }
        }
        return StoredLink(a: link.a, b: link.b, packed: data)
    }

    static func unpackLink(_ stored: StoredLink) -> DriftRefiner.Link {
        var link = DriftRefiner.Link(a: stored.a, b: stored.b, qa: [], qb: [], nb: [])
        let count = stored.packed.count / 36
        stored.packed.withUnsafeBytes { raw in
            func vector(_ offset: Int) -> SIMD3<Double> {
                func value(_ k: Int) -> Double {
                    Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + k * 4, as: UInt32.self))))
                }
                return SIMD3<Double>(value(0), value(1), value(2))
            }
            for i in 0..<count {
                link.qa.append(vector(i * 36)); link.qb.append(vector(i * 36 + 12)); link.nb.append(vector(i * 36 + 24))
            }
        }
        return link
    }
}

/// The save-time steps, on plain arrays so they are tested without the app.
enum DriftPipeline {
    struct PhoneCorrection {
        /// Segment poses as recorded (capture frame).
        var captured: [RigidPose]
        /// Segment poses after the phone's own corrections.
        var corrected: [RigidPose]
        /// Largest accepted correction (metres at the segment itself).
        var largest: Double
        var ignored: Int
    }

    /// Walks shorter than this are never touched: a short scan is saved exactly
    /// as it was captured, whatever the phone did to its anchors.
    static let minimumPathMetres = 10.0

    /// Reads what ARKit did to each segment's anchor, RELATIVE TO THE FIRST
    /// SEGMENT: only changes of shape count, so a shift of the whole map is no
    /// change at all. Relative changes under 5 mm and 0.05° are treated as
    /// exactly none; implausibly large ones are ignored.
    static func phoneCorrection(_ capture: AlignmentCapture) -> PhoneCorrection? {
        guard capture.isUsable else { return nil }
        var references: [RigidPose] = [], ends: [RigidPose] = []
        for segment in capture.segments {
            guard let a = AlignmentCapture.matrix(segment.reference), let b = AlignmentCapture.matrix(segment.end) else { return nil }
            references.append(RigidPose(a).orthonormalised)
            ends.append(RigidPose(b).orthonormalised)
        }
        // What happened to the first segment's anchor is taken out of all of them.
        let gauge = references[0].composed(with: ends[0].inverse)
        var corrected: [RigidPose] = []
        var largest = 0.0
        var ignored = 0
        for k in 0..<references.count {
            let reference = references[k]
            let end = gauge.composed(with: ends[k]).orthonormalised
            let shift = simd_distance(reference.t, end.t)
            let angle = simd_length(DriftMath.logSO3(end.r * reference.r.transpose))
            if k == 0 || (shift < 0.005 && angle < 0.00087) {
                corrected.append(reference)
            } else if shift > 3 || angle > 15 * .pi / 180 || !shift.isFinite || !angle.isFinite {
                corrected.append(reference); ignored += 1
            } else {
                corrected.append(end)
                largest = max(largest, shift + angle * 2)      // effect about 2 m from the anchor
            }
        }
        return PhoneCorrection(captured: references, corrected: corrected, largest: largest, ignored: ignored)
    }

    struct Prepared {
        var points: [SIMD3<Float>]
        var captured: [RigidPose]
        var phone: [RigidPose]
        var refined: [RigidPose]
        var links: [DriftRefiner.Link]
        var summary: ScanAlignmentSummary
    }

    /// As-captured points in, corrected points out (capture frame). Never
    /// changes which points exist, their order or their colours.
    static func prepare(points: [SIMD3<Float>], segments: [UInt16], capture: AlignmentCapture, enabled: Bool,
                        options custom: DriftRefiner.Options? = nil,
                        cancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) -> Prepared? {
        guard points.count == segments.count, let phone = phoneCorrection(capture),
              segments.allSatisfy({ Int($0) < phone.captured.count }) else { return nil }
        var summary = ScanAlignmentSummary(pathLengthMetres: capture.pathLengthMetres, segmentCount: capture.segments.count,
            trackingJumps: capture.trackingJumps, fastTurnSeconds: capture.fastTurnSeconds,
            phoneCorrectionMetres: 0, overlap: "off", largestMoveMetres: 0, corrected: false)
        guard enabled else {
            return Prepared(points: points, captured: phone.captured, phone: phone.captured, refined: phone.captured,
                            links: [], summary: summary.sanitised)
        }
        guard capture.pathLengthMetres >= minimumPathMetres else {
            summary.overlap = "tooShort"
            return Prepared(points: points, captured: phone.captured, phone: phone.captured, refined: phone.captured,
                            links: [], summary: summary.sanitised)
        }
        summary.phoneCorrectionMetres = phone.largest
        var current = DriftRefiner.move(points: points, segments: segments, from: phone.captured, to: phone.corrected)
        var refined = phone.corrected
        var links: [DriftRefiner.Link] = []
        let spacing = Double(capture.spacingMetres)
        if spacing > 0.05 {
            summary.overlap = "tooSparse"
        } else {
            var options = DriftRefiner.Options()
            options.spacing = spacing
            if let custom { options = custom }
            let outcome = DriftRefiner.refine(points: current, segments: segments, poses: phone.corrected,
                                              options: options, cancelled: cancelled, progress: progress)
            summary.overlap = outcome.result == .cancelled ? "notRun" : outcome.result.rawValue
            summary.disagreementMetres = outcome.disagreement
            summary.mismatchBeforeMetres = outcome.mismatchBefore
            summary.mismatchAfterMetres = outcome.mismatchAfter
            if outcome.result == .applied {
                current = DriftRefiner.move(points: current, segments: segments, from: phone.corrected, to: outcome.poses)
                refined = outcome.poses
                links = outcome.links
            }
        }
        var largest = 0.0
        var changed = false
        for k in 0..<refined.count {
            let delta = refined[k].composed(with: phone.captured[k].inverse)
            let size = delta.magnitude
            if size.angle >= 1e-9 || size.shift >= 1e-7 { changed = true }
            // Movement of the segment's own origin (where the phone stood).
            largest = max(largest, simd_distance(refined[k].t, phone.captured[k].t) + size.angle * 2)
        }
        summary.corrected = changed
        summary.largestMoveMetres = changed ? largest : 0
        // A correction that produced a non-finite position is discarded whole.
        if changed, !current.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) {
            summary.corrected = false; summary.largestMoveMetres = 0; summary.overlap = DriftRefiner.Result.noImprovement.rawValue
            return Prepared(points: points, captured: phone.captured, phone: phone.captured, refined: phone.captured,
                            links: [], summary: summary.sanitised)
        }
        return Prepared(points: changed ? current : points, captured: phone.captured, phone: phone.corrected,
                        refined: refined, links: links, summary: summary.sanitised)
    }

    /// Builds the sidecar once the saved frame and model hash are known.
    static func document(prepared: Prepared, capture: AlignmentCapture, pointSegments: [UInt16], frame: RigidPose,
                         modelSHA256: String) -> ScanAlignmentDocument {
        let segments = (0..<prepared.refined.count).map { k in
            ScanAlignmentDocument.Segment(captured: frame.composed(with: prepared.captured[k]).array,
                phone: frame.composed(with: prepared.phone[k]).array,
                saved: frame.composed(with: prepared.refined[k]).array,
                startTime: k < capture.segments.count ? capture.segments[k].startTime : 0)
        }
        let up = frame.rotate(SIMD3<Double>(0, 1, 0))
        return ScanAlignmentDocument(modelSHA256: modelSHA256, pointCount: pointSegments.count,
            spacingMetres: Double(capture.spacingMetres), up: [up.x, up.y, up.z], captureToSaved: frame.array,
            summary: prepared.summary, segments: segments, links: prepared.links.map(ScanAlignmentDocument.packLink),
            pointSegments: ScanAlignmentDocument.packSegments(pointSegments), path: capture.path)
    }

    /// The points exactly as the phone recorded them, in the saved frame.
    static func asCaptured(points: [SIMD3<Float>], document: ScanAlignmentDocument) throws -> [SIMD3<Float>] {
        try document.validate()
        guard points.count == document.pointCount else { throw ScanAlignmentError.staleModel }
        return DriftRefiner.move(points: points, segments: ScanAlignmentDocument.unpackSegments(document.pointSegments),
                                 from: document.savedPoses, to: document.capturedPoses)
    }
}

/// Reads back a point cloud written by `PointCloudPLYWriter` (and nothing else:
/// binary little-endian, float x y z, optional uchar red green blue). Used to
/// make corrected or as-captured COPIES of a saved scan.
enum PointCloudPLYReader {
    static let maximumPoints = 8_000_000

    static func read(_ url: URL) throws -> (positions: [SIMD3<Float>], colors: [SIMD4<Float>]) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let prefix = try input.read(upToCount: 4096) ?? Data()
        let marker = Data("end_header\n".utf8)
        guard let end = prefix.range(of: marker), let header = String(data: prefix[prefix.startIndex..<end.lowerBound], encoding: .utf8) else {
            throw ScanAlignmentError.invalidDocument
        }
        var count = -1
        var properties: [String] = []
        var binary = false
        for (index, line) in header.split(separator: "\n").enumerated() {
            let fields = line.split(separator: " ").map(String.init)
            if index == 0 { guard line == "ply" else { throw ScanAlignmentError.invalidDocument }; continue }
            guard let keyword = fields.first else { continue }
            switch keyword {
            case "comment": continue
            case "format": binary = fields.count == 3 && fields[1] == "binary_little_endian" && fields[2] == "1.0"
            case "element":
                guard fields.count == 3, fields[1] == "vertex", count < 0, let n = Int(fields[2]) else { throw ScanAlignmentError.invalidDocument }
                count = n
            case "property":
                guard fields.count == 3 else { throw ScanAlignmentError.invalidDocument }
                properties.append(fields[1] + " " + fields[2])
            default: throw ScanAlignmentError.invalidDocument
            }
        }
        let plain = ["float x", "float y", "float z"]
        let coloured = plain + ["uchar red", "uchar green", "uchar blue"]
        guard binary, count > 0, count <= maximumPoints, properties == plain || properties == coloured else {
            throw ScanAlignmentError.invalidDocument
        }
        let hasColor = properties == coloured
        let stride = hasColor ? 15 : 12
        try input.seek(toOffset: UInt64(prefix.distance(from: prefix.startIndex, to: end.upperBound)))
        let body = try input.readToEnd() ?? Data()
        guard body.count == count * stride else { throw ScanAlignmentError.invalidDocument }
        var positions = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: count)
        var colors: [SIMD4<Float>] = hasColor ? [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 1), count: count) : []
        try body.withUnsafeBytes { raw in
            for i in 0..<count {
                let base = i * stride
                func value(_ k: Int) -> Float {
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base + k * 4, as: UInt32.self)))
                }
                let p = SIMD3<Float>(value(0), value(1), value(2))
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { throw ScanAlignmentError.invalidDocument }
                positions[i] = p
                if hasColor {
                    colors[i] = SIMD4<Float>(Float(raw[base + 12]) / 255, Float(raw[base + 13]) / 255, Float(raw[base + 14]) / 255, 1)
                }
            }
        }
        return (positions, colors)
    }
}
