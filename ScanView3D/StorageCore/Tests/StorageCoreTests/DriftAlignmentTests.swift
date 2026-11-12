import Foundation
import XCTest
import simd
@testable import StorageCore

/// Synthetic captures with known truth. A concrete channel (two walls, a floor,
/// kerbs, ground on both sides and one box) is sampled on a grid, cut into
/// 1.5 m segments along the walk and, for the return pass, displaced the way
/// phone tracking drifts after a U-turn: turned about the turning point and
/// lifted slightly. The refiner must bring the return pass back onto the truth
/// without disturbing the first pass, and must leave agreeing scans alone.
final class DriftAlignmentTests: XCTestCase {

    // MARK: Scene

    private func grid(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double, step: Double, phase: Double,
                      _ make: (Double, Double) -> SIMD3<Double>) -> [SIMD3<Double>] {
        var out: [SIMD3<Double>] = []
        var a = a0 + phase * step
        while a < a1 {
            var b = b0 + phase * step
            while b < b1 { out.append(make(a, b)); b += step }
            a += step
        }
        return out
    }

    private func canal(length: Double, step: Double, phase: Double) -> [SIMD3<Double>] {
        var p: [SIMD3<Double>] = []
        p += grid(0, length, -0.375, 0.375, step: step, phase: phase) { SIMD3($0, -0.95, $1) }            // floor
        for z in [-0.375, 0.375] {                                                                        // walls
            p += grid(0, length, -0.95, 0.12, step: step, phase: phase) { SIMD3($0, $1, z) }
        }
        for (z0, z1) in [(-0.575, -0.375), (0.375, 0.575)] {                                              // kerb tops
            p += grid(0, length, z0, z1, step: step, phase: phase) { SIMD3($0, 0.12, $1) }
        }
        for (z0, z1) in [(-2.5, -0.575), (0.575, 2.5)] {                                                  // ground
            p += grid(0, length, z0, z1, step: step, phase: phase) { SIMD3($0, 0, $1) }
        }
        let cx = length / 2, cz = 1.6                                                                     // a box
        let ground = p.filter { !(abs($0.x - cx) < 0.4 && abs($0.z - cz) < 0.3 && $0.y == 0) }
        p = ground
        p += grid(cx - 0.4, cx + 0.4, cz - 0.3, cz + 0.3, step: step, phase: phase) { SIMD3($0, 0.6, $1) }
        for x in [cx - 0.4, cx + 0.4] {
            p += grid(cz - 0.3, cz + 0.3, 0, 0.6, step: step, phase: phase) { SIMD3(x, $1, $0) }
        }
        for z in [cz - 0.3, cz + 0.3] {
            p += grid(cx - 0.4, cx + 0.4, 0, 0.6, step: step, phase: phase) { SIMD3($0, $1, z) }
        }
        return p
    }

    private struct Capture {
        var points: [SIMD3<Float>] = []
        var truth: [SIMD3<Double>] = []
        var segments: [UInt16] = []
        var poses: [RigidPose] = []
        var firstPassSegments = 0
    }

    private func float(_ p: SIMD3<Double>) -> SIMD3<Float> { SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)) }

    /// Fewer samples than the app uses, so unoptimised test builds stay quick.
    /// The fixtures are sampled every 5 cm, hence the wider normal radius.
    private var light: DriftRefiner.Options {
        var options = DriftRefiner.Options()
        options.spacing = 0.04
        options.maxSamplesPerSegment = 1200
        options.maxSourceSamples = 400
        return options
    }

    /// Out along the channel and (optionally) back, with the return pass turned
    /// by `yawDegrees` about the turning point and lifted by `lift` metres.
    private func walk(length: Double = 9, step: Double = 0.05, passes: Int = 2, yawDegrees: Double = 1.2,
                      lift: Double = 0.03) -> Capture {
        var capture = Capture()
        let slices = Int((length / 1.5).rounded())
        capture.firstPassSegments = slices
        let pivot = SIMD3<Double>(length, 0, 1.3)
        let drift = DriftMath.yaw(yawDegrees * .pi / 180)
        for pass in 0..<passes {
            let scene = canal(length: length, step: step, phase: pass == 0 ? 0 : 0.5)
            let order = pass == 0 ? Array(0..<slices) : Array((0..<slices).reversed())
            for k in order {
                let camera = SIMD3<Double>(1.5 * Double(k) + 0.75, 1.4, 1.3)
                let index = UInt16(capture.poses.count)
                let pose: RigidPose
                if pass == 0 {
                    pose = RigidPose(r: matrix_identity_double3x3, t: camera)
                } else {
                    // Walking back: the phone has turned round, and its position estimate has drifted.
                    pose = RigidPose(r: drift * DriftMath.yaw(.pi), t: drift * (camera - pivot) + pivot + SIMD3(0, lift, 0))
                }
                capture.poses.append(pose)
                for p in scene where p.x >= 1.5 * Double(k) && p.x < 1.5 * Double(k + 1) {
                    let recorded = pass == 0 ? p : drift * (p - pivot) + pivot + SIMD3(0, lift, 0)
                    capture.points.append(float(recorded))
                    capture.truth.append(p)
                    capture.segments.append(index)
                }
            }
        }
        return capture
    }

    private func sideAndHeightRMS(_ points: [SIMD3<Float>], _ capture: Capture, fromSegment: Int) -> Double {
        var sum = 0.0
        var count = 0
        for i in 0..<points.count where Int(capture.segments[i]) >= fromSegment {
            let dy = Double(points[i].y) - capture.truth[i].y, dz = Double(points[i].z) - capture.truth[i].z
            sum += dy * dy + dz * dz; count += 1
        }
        return count > 0 ? (sum / Double(count)).squareRoot() : 0
    }

    // MARK: Maths

    func testRotationVectorRoundTripAndYawConvention() {
        for w in [SIMD3<Double>(0.01, -0.02, 0.03), SIMD3<Double>(0.4, 0.1, -0.7), SIMD3<Double>(0, 1.2, 0)] {
            let back = DriftMath.logSO3(DriftMath.expSO3(w))
            XCTAssertLessThan(simd_distance(back, w), 1e-9)
        }
        // A positive yaw turns +X towards −Z (right-handed, Y up).
        let turned = DriftMath.yaw(.pi / 2) * SIMD3<Double>(1, 0, 0)
        XCTAssertLessThan(simd_distance(turned, SIMD3<Double>(0, 0, -1)), 1e-12)
        XCTAssertLessThan(simd_distance(DriftMath.logSO3(DriftMath.yaw(0.3)), SIMD3<Double>(0, 0.3, 0)), 1e-12)
    }

    func testPoseAlgebra() throws {
        let a = RigidPose(r: DriftMath.expSO3(SIMD3(0.1, 0.2, -0.3)), t: SIMD3(1, 2, 3))
        let b = RigidPose(r: DriftMath.expSO3(SIMD3(-0.2, 0.05, 0.1)), t: SIMD3(-4, 0.5, 2))
        let p = SIMD3<Double>(0.3, -1.2, 2.5)
        XCTAssertLessThan(simd_distance(a.composed(with: b).apply(p), a.apply(b.apply(p))), 1e-12)
        XCTAssertLessThan(simd_distance(a.inverse.apply(a.apply(p)), p), 1e-12)
        XCTAssertLessThan(simd_distance(a.applyInverse(a.apply(p)), p), 1e-12)
        let restored = try XCTUnwrap(RigidPose(array: a.array))
        XCTAssertLessThan(simd_distance(restored.apply(p), a.apply(p)), 1e-12)
        XCTAssertNil(RigidPose(array: [2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1]), "scaled matrices are not rigid")
        XCTAssertNil(RigidPose(array: [1, 0, 0]))
        let nudged = a.boxplus([0, 0, 0, 0.1, 0, 0])
        XCTAssertLessThan(abs(simd_distance(nudged.t, a.t) - 0.1), 1e-12)
    }

    func testSymmetricEigenAndCholesky() throws {
        // A = Q·diag(1, 2, 5)·Qᵀ
        let q = DriftMath.expSO3(SIMD3(0.3, -0.5, 0.2))
        var a = [Double](repeating: 0, count: 9)
        let values = [1.0, 2.0, 5.0]
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { a[i * 3 + j] += q[k][i] * values[k] * q[k][j] } } }
        let eigen = DriftMath.symmetricEigen(a, n: 3)
        for k in 0..<3 { XCTAssertEqual(eigen.values[k], values[k], accuracy: 1e-9) }
        // Eigenvectors satisfy A·v = λ·v.
        for k in 0..<3 {
            for i in 0..<3 {
                var av = 0.0
                for j in 0..<3 { av += a[i * 3 + j] * eigen.vectors[j * 3 + k] }
                XCTAssertEqual(av, values[k] * eigen.vectors[i * 3 + k], accuracy: 1e-9)
            }
        }
        let x = try XCTUnwrap(DriftMath.choleskySolve(a, [1, -2, 0.5], n: 3))
        for i in 0..<3 {
            var sum = 0.0
            for j in 0..<3 { sum += a[i * 3 + j] * x[j] }
            XCTAssertEqual(sum, [1, -2, 0.5][i], accuracy: 1e-9)
        }
        XCTAssertNil(DriftMath.choleskySolve([1, 2, 2, 1], [1, 1], n: 2), "indefinite matrix must be refused")
    }

    func testYawFitRecoversHeadingAndShiftOnly() throws {
        let truth = RigidPose(r: DriftMath.yaw(0.7), t: SIMD3(120, 15, -40))
        let a = [SIMD3<Double>(0, 0, 0), SIMD3<Double>(5, 0.2, 1), SIMD3<Double>(-2, 1.5, 7), SIMD3<Double>(9, -0.4, -3)]
        let fit = try XCTUnwrap(DriftMath.yawFit(a, a.map { truth.apply($0) }))
        for p in a { XCTAssertLessThan(simd_distance(fit.apply(p), truth.apply(p)), 1e-9) }
    }

    // MARK: Lining up passes

    func testDriftedReturnPassIsBroughtBackWithoutDisturbingTheFirstPass() {
        let capture = walk()
        let before = sideAndHeightRMS(capture.points, capture, fromSegment: capture.firstPassSegments)
        XCTAssertGreaterThan(before, 0.08, "the fixture must start clearly doubled")
        let outcome = DriftRefiner.refine(points: capture.points, segments: capture.segments, poses: capture.poses, options: light)
        XCTAssertEqual(outcome.result, .applied)
        XCTAssertGreaterThan(outcome.disagreement, 0.10)
        XCTAssertGreaterThanOrEqual(outcome.matchedSegments, 3)
        let moved = DriftRefiner.move(points: capture.points, segments: capture.segments, from: capture.poses, to: outcome.poses)
        let after = sideAndHeightRMS(moved, capture, fromSegment: capture.firstPassSegments)
        XCTAssertLessThan(after, 0.02, "return pass must land within 2 cm sideways and in height (was \(before))")
        var firstPassMove: Float = 0
        var worst = 0.0
        for i in 0..<moved.count {
            if Int(capture.segments[i]) < capture.firstPassSegments {
                firstPassMove = max(firstPassMove, simd_distance(moved[i], capture.points[i]))
            }
            worst = max(worst, simd_distance(SIMD3<Double>(Double(moved[i].x), Double(moved[i].y), Double(moved[i].z)), capture.truth[i]))
        }
        XCTAssertLessThan(firstPassMove, 0.04, "the accurate first pass must stay where it was")
        XCTAssertLessThan(worst, 0.06)
        let mismatchBefore = outcome.mismatchBefore ?? 0, mismatchAfter = outcome.mismatchAfter ?? 1
        XCTAssertLessThan(mismatchAfter, 0.3 * mismatchBefore)
        XCTAssertEqual(outcome.poses[0], capture.poses[0], "the start of the scan never moves")
        XCTAssertFalse(outcome.links.isEmpty)
    }

    func testAgreeingPassesAreLeftExactlyAsCaptured() {
        let capture = walk(yawDegrees: 0, lift: 0)
        let outcome = DriftRefiner.refine(points: capture.points, segments: capture.segments, poses: capture.poses, options: light)
        XCTAssertEqual(outcome.result, .passesAgree)
        XCTAssertEqual(outcome.poses, capture.poses)
        XCTAssertEqual(DriftRefiner.move(points: capture.points, segments: capture.segments, from: capture.poses, to: outcome.poses),
                       capture.points, "nothing may change, bit for bit")
    }

    func testBarelyDriftedSmallScanIsNotTouched() {
        // 8 mm of disagreement is within sensor noise: a short, careful scan stays as captured.
        let capture = walk(length: 6, yawDegrees: 0.05, lift: 0.004)
        let outcome = DriftRefiner.refine(points: capture.points, segments: capture.segments, poses: capture.poses, options: light)
        XCTAssertEqual(outcome.result, .passesAgree)
        XCTAssertEqual(outcome.poses, capture.poses)
    }

    func testSinglePassHasNothingToLineUp() {
        let capture = walk(passes: 1)
        let outcome = DriftRefiner.refine(points: capture.points, segments: capture.segments, poses: capture.poses, options: light)
        XCTAssertEqual(outcome.result, .noOverlap)
        XCTAssertEqual(outcome.poses, capture.poses)
    }

    func testFlatGroundAloneCannotInventASidewaysCorrection() {
        // Only the height of a flat surface can be observed; sideways and heading must not be guessed.
        var capture = Capture()
        let drift = DriftMath.yaw(1.5 * .pi / 180)
        let pivot = SIMD3<Double>(9, 0, 1.3)
        for pass in 0..<2 {
            let order = pass == 0 ? Array(0..<6) : Array((0..<6).reversed())
            for k in order {
                let camera = SIMD3<Double>(1.5 * Double(k) + 0.75, 1.4, 1.3)
                let index = UInt16(capture.poses.count)
                capture.poses.append(pass == 0 ? RigidPose(r: matrix_identity_double3x3, t: camera)
                    : RigidPose(r: drift * DriftMath.yaw(.pi), t: drift * (camera - pivot) + pivot + SIMD3(0, 0.04, 0)))
                for p in grid(1.5 * Double(k), 1.5 * Double(k + 1), -2, 2, step: 0.05, phase: pass == 0 ? 0 : 0.5,
                              { SIMD3($0, 0, $1) }) {
                    capture.points.append(float(pass == 0 ? p : drift * (p - pivot) + pivot + SIMD3(0, 0.04, 0)))
                    capture.truth.append(p); capture.segments.append(index)
                }
            }
        }
        capture.firstPassSegments = 6
        let outcome = DriftRefiner.refine(points: capture.points, segments: capture.segments, poses: capture.poses, options: light)
        let moved = DriftRefiner.move(points: capture.points, segments: capture.segments, from: capture.poses, to: outcome.poses)
        for i in stride(from: 0, to: moved.count, by: 97) {
            let sideways = simd_distance(SIMD2<Float>(moved[i].x, moved[i].z), SIMD2<Float>(capture.points[i].x, capture.points[i].z))
            XCTAssertLessThan(sideways, 0.02, "a flat floor gives no sideways evidence")
        }
        if outcome.result == .applied {
            // Height is observable and should improve.
            var worst = 0.0
            for i in 0..<moved.count where Int(capture.segments[i]) >= 6 { worst = max(worst, abs(Double(moved[i].y))) }
            XCTAssertLessThan(worst, 0.025)
        }
    }

    func testCancellationReturnsTheCaptureUnchanged() {
        let capture = walk(length: 6)
        let outcome = DriftRefiner.refine(points: capture.points, segments: capture.segments, poses: capture.poses,
                                          options: light, cancelled: { true })
        XCTAssertEqual(outcome.result, .cancelled)
        XCTAssertEqual(outcome.poses, capture.poses)
    }

    // MARK: Phone corrections and the saved record

    private func matrix(_ pose: RigidPose) -> [Float] { AlignmentCapture.array(pose.float4x4) }

    func testPhoneCorrectionsAreAppliedOnlyWhenRealAndPlausible() throws {
        let base = RigidPose(r: DriftMath.yaw(0.4), t: SIMD3(2, 1.4, -3))
        let tiny = RigidPose(r: DriftMath.yaw(0.4 + 0.0001), t: SIMD3(2.001, 1.4, -3))
        let real = RigidPose(r: DriftMath.yaw(0.4 + 0.01), t: SIMD3(2.06, 1.42, -3.01))
        let absurd = RigidPose(r: DriftMath.yaw(2.4), t: SIMD3(40, 1.4, -3))
        let capture = AlignmentCapture(spacingMetres: 0.01, segments: [
            AlignmentCapture.Segment(reference: matrix(base), end: matrix(base), startTime: 0),
            AlignmentCapture.Segment(reference: matrix(base), end: matrix(tiny), startTime: 1),
            AlignmentCapture.Segment(reference: matrix(base), end: matrix(real), startTime: 2),
            AlignmentCapture.Segment(reference: matrix(base), end: matrix(absurd), startTime: 3)
        ], path: Data(), pathLengthMetres: 5, trackingJumps: 0, fastTurnSeconds: 0)
        let correction = try XCTUnwrap(DriftPipeline.phoneCorrection(capture))
        XCTAssertEqual(correction.corrected[0], correction.captured[0])
        XCTAssertEqual(correction.corrected[1], correction.captured[1], "sub-2 mm nudges count as exactly nothing")
        XCTAssertNotEqual(correction.corrected[2], correction.captured[2])
        XCTAssertEqual(correction.corrected[3], correction.captured[3], "implausible jumps are ignored")
        XCTAssertEqual(correction.ignored, 1)
        XCTAssertGreaterThan(correction.largest, 0.05)
        XCTAssertLessThan(correction.largest, 0.12)

        // Points follow their own segment's correction and nothing else.
        let points = [SIMD3<Float>(2.5, 0, -3), SIMD3<Float>(2.5, 0, -3), SIMD3<Float>(2.5, 0, -3), SIMD3<Float>(2.5, 0, -3)]
        let prepared = try XCTUnwrap(DriftPipeline.prepare(points: points, segments: [0, 1, 2, 3], capture: capture, enabled: true))
        XCTAssertEqual(prepared.points[0], points[0]); XCTAssertEqual(prepared.points[1], points[1])
        XCTAssertEqual(prepared.points[3], points[3])
        let expected = real.apply(base.applyInverse(SIMD3<Double>(2.5, 0, -3)))
        XCTAssertLessThan(simd_distance(SIMD3<Double>(Double(prepared.points[2].x), Double(prepared.points[2].y), Double(prepared.points[2].z)), expected), 1e-5)
        XCTAssertTrue(prepared.summary.corrected)
        XCTAssertEqual(prepared.summary.overlap, DriftRefiner.Result.noOverlap.rawValue)

        // Turned off: exactly as captured, and said so.
        let off = try XCTUnwrap(DriftPipeline.prepare(points: points, segments: [0, 1, 2, 3], capture: capture, enabled: false))
        XCTAssertEqual(off.points, points)
        XCTAssertFalse(off.summary.corrected)
        XCTAssertEqual(off.summary.overlap, "off")
        // A segment index without a record is refused rather than guessed.
        XCTAssertNil(DriftPipeline.prepare(points: points, segments: [0, 1, 2, 9], capture: capture, enabled: true))
    }

    func testPipelineCorrectsASavedRecordRoundTripsAndRestoresAsCaptured() throws {
        let walked = walk(length: 6)
        let capture = AlignmentCapture(spacingMetres: 0.01,
            segments: walked.poses.enumerated().map { AlignmentCapture.Segment(reference: matrix($1), end: matrix($1), startTime: Double($0)) },
            path: Data(count: 64), pathLengthMetres: 12, trackingJumps: 1, fastTurnSeconds: 0.5)
        let prepared = try XCTUnwrap(DriftPipeline.prepare(points: walked.points, segments: walked.segments, capture: capture, enabled: true, options: light))
        XCTAssertEqual(prepared.summary.overlap, DriftRefiner.Result.applied.rawValue)
        XCTAssertTrue(prepared.summary.corrected)
        XCTAssertGreaterThan(prepared.summary.largestMoveMetres, 0.05)
        XCTAssertLessThan(sideAndHeightRMS(prepared.points, walked, fromSegment: walked.firstPassSegments), 0.02)

        // Saved in another frame (turned and shifted), with the record alongside.
        let frame = RigidPose(r: DriftMath.yaw(0.9), t: SIMD3(-3, 0.95, 4))
        let saved = prepared.points.map { p -> SIMD3<Float> in let q = frame.apply(p); return SIMD3(Float(q.x), Float(q.y), Float(q.z)) }
        let document = DriftPipeline.document(prepared: prepared, capture: capture, pointSegments: walked.segments, frame: frame,
                                              modelSHA256: String(repeating: "a", count: 64))
        try document.validate()
        let decoded = try JSONDecoder().decode(ScanAlignmentDocument.self, from: JSONEncoder().encode(document))
        try decoded.validate()
        XCTAssertEqual(decoded.pointSegments, document.pointSegments)
        XCTAssertEqual(decoded.links, document.links)
        XCTAssertEqual(ScanAlignmentDocument.unpackSegments(decoded.pointSegments), walked.segments)
        let link = try XCTUnwrap(prepared.links.first)
        let unpacked = ScanAlignmentDocument.unpackLink(ScanAlignmentDocument.packLink(link))
        XCTAssertEqual(unpacked.qa.count, link.qa.count)
        XCTAssertLessThan(simd_distance(unpacked.nb[0], link.nb[0]), 1e-6)

        // "As captured" is recoverable from the saved points alone.
        let restored = try DriftPipeline.asCaptured(points: saved, document: decoded)
        for i in stride(from: 0, to: restored.count, by: 53) {
            let original = frame.apply(walked.points[i])
            XCTAssertLessThan(simd_distance(SIMD3<Double>(Double(restored[i].x), Double(restored[i].y), Double(restored[i].z)), original), 2e-4)
        }
        XCTAssertThrowsError(try DriftPipeline.asCaptured(points: Array(saved.dropLast()), document: decoded))
        var broken = decoded; broken.pointSegments.removeLast()
        XCTAssertThrowsError(try broken.validate())
        var future = decoded; future.version = 2
        XCTAssertThrowsError(try future.validate(), "a newer record must not be reinterpreted")
    }

    func testCoarseSpacingSkipsLiningUpButKeepsPhoneCorrections() throws {
        let walked = walk(length: 6)
        let capture = AlignmentCapture(spacingMetres: 0.2,
            segments: walked.poses.map { AlignmentCapture.Segment(reference: matrix($0), end: matrix($0), startTime: 0) },
            path: Data(), pathLengthMetres: 12, trackingJumps: 0, fastTurnSeconds: 0)
        let prepared = try XCTUnwrap(DriftPipeline.prepare(points: walked.points, segments: walked.segments, capture: capture, enabled: true))
        XCTAssertEqual(prepared.summary.overlap, "tooSparse")
        XCTAssertEqual(prepared.points, walked.points)
    }

    // MARK: Segments during capture

    private func pose(x: Float, yaw: Float = 0) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)))
        m.columns.3 = SIMD4<Float>(x, 1.4, 0, 1)
        return m
    }

    func testSegmentsStartOnDistanceTurnJumpAndResume() {
        var segmenter = CaptureSegmenter()
        XCTAssertTrue(segmenter.update(time: 0, pose: pose(x: 0), anchorMoved: false), "first pose opens a segment")
        var started = 0
        var t = 0.0
        for step in 1...40 {               // 4 m at 1 m/s
            t += 0.1
            if segmenter.update(time: t, pose: pose(x: Float(step) * 0.1), anchorMoved: false) { started += 1 }
        }
        XCTAssertEqual(started, 2, "a new segment every 1.5 m")
        XCTAssertEqual(segmenter.pathLength, 4, accuracy: 0.01)
        // Turning on the spot at 40° per second: a new segment at 32°, 64° and 96°, and a hint.
        started = 0
        for step in 1...31 {
            t += 0.1
            if segmenter.update(time: t, pose: pose(x: 4, yaw: Float(step) * 4 * .pi / 180), anchorMoved: false) { started += 1 }
        }
        let heading = Float(31) * 4 * .pi / 180
        XCTAssertEqual(started, 3)
        XCTAssertEqual(segmenter.hint, CaptureSegmenter.pivotHint)
        // A sudden snap of the phone's position estimate.
        segmenter.noteFrame(time: t + 0.016, position: SIMD3<Float>(4, 1.4, 0))
        segmenter.noteFrame(time: t + 0.033, position: SIMD3<Float>(4.2, 1.4, 0))
        XCTAssertEqual(segmenter.jumps, 1)
        t += 0.1
        XCTAssertTrue(segmenter.update(time: t, pose: pose(x: 4.2, yaw: heading), anchorMoved: false))
        // Ordinary walking between frames is not a jump.
        segmenter.noteFrame(time: t + 0.016, position: SIMD3<Float>(4.2, 1.4, 0))
        segmenter.noteFrame(time: t + 0.033, position: SIMD3<Float>(4.225, 1.4, 0))
        XCTAssertEqual(segmenter.jumps, 1)
        // The phone moved this segment's anchor: later points need their own record.
        t += 1.2
        XCTAssertTrue(segmenter.update(time: t, pose: pose(x: 4.3, yaw: heading), anchorMoved: true))
        t += 0.1
        XCTAssertFalse(segmenter.update(time: t, pose: pose(x: 4.3, yaw: heading), anchorMoved: true),
                       "a moved anchor does not restart segments more than once a second")
        segmenter.noteDiscontinuity()
        t += 5
        XCTAssertTrue(segmenter.update(time: t, pose: pose(x: 4.3, yaw: heading), anchorMoved: false))
        XCTAssertEqual(segmenter.path.count % 32, 0)
        XCTAssertGreaterThan(segmenter.path.count, 32 * 20)
    }

    func testFastTurnHintAndSegmentBudget() {
        var segmenter = CaptureSegmenter()
        var t = 0.0
        _ = segmenter.update(time: t, pose: pose(x: 0), anchorMoved: false)
        for step in 1...8 {                // 120°/s
            t += 0.1
            _ = segmenter.update(time: t, pose: pose(x: 0, yaw: Float(step) * 12 * .pi / 180), anchorMoved: false)
        }
        XCTAssertEqual(segmenter.hint, CaptureSegmenter.fastTurnHint)
        XCTAssertGreaterThan(segmenter.fastTurnSeconds, 0.5)
        // Calm walking clears the hint.
        for step in 1...40 {
            t += 0.1
            _ = segmenter.update(time: t, pose: pose(x: Float(step) * 0.05, yaw: 96 * .pi / 180), anchorMoved: false)
        }
        XCTAssertNil(segmenter.hint)
        // However long the walk, the number of segments stays bounded.
        for step in 1...40_000 {
            t += 0.1
            _ = segmenter.update(time: t, pose: pose(x: 2 + Float(step) * 0.1, yaw: 96 * .pi / 180), anchorMoved: false)
        }
        XCTAssertLessThanOrEqual(segmenter.segmentCount, AlignmentCapture.maximumSegments)
        XCTAssertLessThanOrEqual(segmenter.path.count / 32, 20_000)
    }

    // MARK: References

    /// One pass whose heading error grows by `kinkDegrees` at every segment joint.
    private func bentPass(length: Double = 9, step: Double = 0.05, kinkDegrees: Double = 0.5) -> Capture {
        var capture = Capture()
        let slices = Int((length / 1.5).rounded())
        let scene = canal(length: length, step: step, phase: 0)
        var total = RigidPose.identity
        for k in 0..<slices {
            if k > 0 {
                let hinge = SIMD3<Double>(1.5 * Double(k), 0, 0)
                let turn = DriftMath.yaw(kinkDegrees * .pi / 180)
                total = total.composed(with: RigidPose(r: turn, t: hinge - turn * hinge))
            }
            let camera = SIMD3<Double>(1.5 * Double(k) + 0.75, 1.4, 1.3)
            capture.poses.append(RigidPose(r: total.r, t: total.apply(camera)))
            for p in scene where p.x >= 1.5 * Double(k) && p.x < 1.5 * Double(k + 1) {
                capture.points.append(float(total.apply(p))); capture.truth.append(p); capture.segments.append(UInt16(k))
            }
        }
        capture.firstPassSegments = slices
        return capture
    }

    private func nearestIndex(_ truth: SIMD3<Double>, in capture: Capture) -> Int {
        var best = 0
        var distance = Double.greatestFiniteMagnitude
        for (i, p) in capture.truth.enumerated() {
            let d = simd_distance_squared(p, truth)
            if d < distance { distance = d; best = i }
        }
        return best
    }

    /// Recorded position of the scene point nearest to `truth`.
    private func recorded(_ truth: SIMD3<Double>, in capture: Capture) -> [Double] {
        let p = capture.points[nearestIndex(truth, in: capture)]
        return [Double(p.x), Double(p.y), Double(p.z)]
    }

    private func kerbBow(_ points: [SIMD3<Float>], _ capture: Capture) -> Double {
        var edge: [(x: Double, p: SIMD3<Double>)] = []
        for (i, t) in capture.truth.enumerated() where abs(t.y - 0.12) < 1e-9 && abs(t.z - 0.525) < 0.01 {
            edge.append((t.x, SIMD3<Double>(Double(points[i].x), Double(points[i].y), Double(points[i].z))))
        }
        guard let first = edge.min(by: { $0.x < $1.x }), let last = edge.max(by: { $0.x < $1.x }) else { return 0 }
        return edge.map { simd_length(DriftReferences.offset($0.p, from: first.p, to: last.p)) }.max() ?? 0
    }

    func testReferenceReportMeasuresWithoutChangingAnything() throws {
        let capture = bentPass()
        var references = ScanReferenceDocument()
        let a = recorded(SIMD3(0.3, 0.12, 0.56), in: capture), b = recorded(SIMD3(8.7, 0.12, -0.56), in: capture)
        references.distances = [ScanReferenceDocument.KnownDistance(name: "Diagonal", a: a, b: b, knownMetres: 8.5)]
        references.lines = [ScanReferenceDocument.StraightLine(name: "Kerb",
            points: [0.3, 3.1, 5.9, 8.7].map { recorded(SIMD3($0, 0.12, 0.56), in: capture) })]
        try references.validate()
        let report = DriftReferences.report(references)
        XCTAssertEqual(report.distances.count, 1)
        XCTAssertEqual(report.distances[0].deviation, report.distances[0].scanMetres - 8.5, accuracy: 1e-12)
        XCTAssertGreaterThan(report.lines[0].largestOffsetMetres, 0.03, "the fixture is visibly bowed")
        XCTAssertEqual(report.worstMetres, max(abs(report.distances[0].deviation), report.lines[0].largestOffsetMetres), accuracy: 1e-12)
        let decoded = try JSONDecoder().decode(ScanReferenceDocument.self, from: JSONEncoder().encode(references))
        XCTAssertEqual(decoded, references)
        var bad = references; bad.lines[0].points = [[0, 0, 0], [1, 0, 0]]
        XCTAssertThrowsError(try bad.validate(), "a line needs at least three points")
        bad = references; bad.distances[0].knownMetres = 0
        XCTAssertThrowsError(try bad.validate())
    }

    func testStraightLineAndKnownDistanceStraightenABentScan() throws {
        let capture = bentPass()
        let before = kerbBow(capture.points, capture)
        XCTAssertGreaterThan(before, 0.05)
        var references = ScanReferenceDocument()
        references.lines = [ScanReferenceDocument.StraightLine(name: "Kerb",
            points: [0.3, 3.1, 5.9, 8.7].map { recorded(SIMD3($0, 0.12, 0.56), in: capture) })]
        let a = recorded(SIMD3(0.3, 0.12, 0.56), in: capture), b = recorded(SIMD3(8.7, 0.12, -0.56), in: capture)
        // The "tape" value is the true distance between the same two marks.
        let known = simd_distance(capture.truth[nearestIndex(SIMD3(0.3, 0.12, 0.56), in: capture)],
                                  capture.truth[nearestIndex(SIMD3(8.7, 0.12, -0.56), in: capture)])
        references.distances = [ScanReferenceDocument.KnownDistance(name: "Diagonal", a: a, b: b, knownMetres: known)]
        let fit = try DriftReferences.fit(points: capture.points, segments: capture.segments, poses: capture.poses,
                                          captured: capture.poses, links: [], up: SIMD3(0, 1, 0), references: references)
        XCTAssertNil(fit.siteOrigin)
        XCTAssertEqual(fit.frame, .identity)
        XCTAssertEqual(fit.poses[0], capture.poses[0], "the start of the scan never moves")
        XCTAssertLessThan(kerbBow(fit.points, capture), 0.4 * before, "the kerb must come out much straighter (was \(before))")
        XCTAssertLessThan(fit.report.lines[0].largestOffsetMetres, 0.006, "marked points lie on the line")
        XCTAssertLessThan(abs(fit.report.distances[0].deviation), 0.004, "the taped distance holds")
        XCTAssertGreaterThan(fit.largestMoveMetres, 0.02)
        // Only whole segments move: points of one segment keep their distances.
        let i0 = capture.segments.firstIndex(of: 3)!, i1 = capture.segments.lastIndex(of: 3)!
        XCTAssertEqual(simd_distance(fit.points[i0], fit.points[i1]), simd_distance(capture.points[i0], capture.points[i1]), accuracy: 2e-5)
    }

    func testControlPointsPutTheScanInSiteCoordinates() throws {
        // A rigid scan (one segment) and three surveyed points in a far-away grid.
        let scene = canal(length: 6, step: 0.05, phase: 0)
        let points = scene.map(float)
        let segments = [UInt16](repeating: 0, count: points.count)
        let site = RigidPose(r: DriftMath.yaw(-0.6), t: SIMD3(0, 0, 0))    // scan → site axes, about the origin
        func survey(_ p: SIMD3<Double>) -> (Double, Double, Double) {
            let q = site.apply(p)
            return (q.x + 612_345.25, -q.z + 6_701_234.5, q.y + 87.3)     // east, north, height
        }
        var references = ScanReferenceDocument()
        for (index, p) in [SIMD3<Double>(0, 0, 0.6), SIMD3<Double>(5.95, 0, -2.5), SIMD3<Double>(3, 0.6, 1.6)].enumerated() {
            let nearest = scene.min { simd_distance_squared($0, p) < simd_distance_squared($1, p) }!
            let (e, n, h) = survey(nearest)
            references.controls.append(ScanReferenceDocument.ControlPoint(name: "C\(index + 1)",
                point: [nearest.x, nearest.y, nearest.z], east: e, north: n, height: h))
        }
        let report = DriftReferences.report(references)
        XCTAssertLessThan(report.worstMetres, 1e-4, "a rigid scan already fits its own survey")
        let fit = try DriftReferences.fit(points: points, segments: segments, poses: [.identity], captured: [.identity],
                                          links: [], up: SIMD3(0, 1, 0), references: references)
        let origin = try XCTUnwrap(fit.siteOrigin)
        XCTAssertEqual(origin, origin.map { $0.rounded() }, "the origin is whole metres")
        for i in stride(from: 0, to: points.count, by: 211) {
            let (e, n, h) = survey(scene[i])
            let expected = SIMD3<Double>(e - origin[0], h - origin[2], -(n - origin[1]))
            let got = SIMD3<Double>(Double(fit.points[i].x), Double(fit.points[i].y), Double(fit.points[i].z))
            XCTAssertLessThan(simd_distance(got, expected), 0.002, "x = east, y = height, z = −north, minus the origin")
        }
        XCTAssertLessThan(fit.report.worstMetres, 0.002)
        // One control point cannot fix a heading, and nothing else was given.
        var single = ScanReferenceDocument(); single.controls = [references.controls[0]]
        XCTAssertThrowsError(try DriftReferences.fit(points: points, segments: segments, poses: [.identity], captured: [.identity],
                                                     links: [], up: SIMD3(0, 1, 0), references: single))
        // A scan without a walk recording cannot be bent to a tape distance.
        var tape = ScanReferenceDocument()
        tape.distances = [ScanReferenceDocument.KnownDistance(name: "d", a: [0, 0, 0.6], b: [5, 0, 0.6], knownMetres: 5.02)]
        XCTAssertThrowsError(try DriftReferences.fit(points: points, segments: segments, poses: [.identity], captured: [.identity],
                                                     links: [], up: SIMD3(0, 1, 0), references: tape))
    }
}
