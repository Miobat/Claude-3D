import XCTest
import simd
@testable import StorageCore

final class CaptureNavigationTests: XCTestCase {
    func testRangeIsRadialNotOpticalDepth() {
        XCTAssertTrue(CaptureRange.accepts(SIMD3(0, 0, -1), metres: 1))
        XCTAssertFalse(CaptureRange.accepts(SIMD3(0.8, 0, -0.8), metres: 1))
        XCTAssertTrue(CaptureRange.accepts(SIMD3(0.3, 0.4, -0.8), metres: 1))
    }
    func testInvalidAndBehindCameraDepthRejected() {
        for p: SIMD3<Float> in [SIMD3(0, 0, 1), SIMD3(0, 0, 0), SIMD3(.nan, 0, -1), SIMD3(0, 0, -.infinity)] {
            XCTAssertFalse(CaptureRange.accepts(p, metres: 2))
        }
        XCTAssertFalse(CaptureRange.accepts(SIMD3(0, 0, -1), metres: .nan))
    }
    func testMovingNearAnUnseenSurfaceDoesNotCaptureIt() {
        var index = CapturedSurfaceIndex()
        XCTAssertTrue(index.insert(SIMD3(0, 0, -0.99), camera: .zero, range: 1))
        XCTAssertTrue(index.contains(SIMD3(0, 0, -0.99)))
        XCTAssertFalse(index.contains(SIMD3(0, 0, -1.01)))
        XCTAssertFalse(index.contains(SIMD3(0, 0, 0.5)))
    }
    func testCoveragePersistsWhenCameraLeavesAndReturns() {
        var index = CapturedSurfaceIndex()
        let first = SIMD3<Float>(0, 0, -0.8)
        index.insert(first, camera: .zero, range: 1)
        index.insert(SIMD3(5, 0, -0.8), camera: SIMD3(5, 0, 0), range: 1)
        XCTAssertTrue(index.contains(first))
        XCTAssertTrue(index.contains(SIMD3(5, 0, -0.8)))
        XCTAssertFalse(index.contains(SIMD3(2.5, 0, -0.8)))
    }
    func testBudgetDoesNotPaintUncommittedSurface() {
        var index = CapturedSurfaceIndex(capacity: 1)
        XCTAssertTrue(index.insert(SIMD3(0, 0, -0.5), camera: .zero, range: 1))
        XCTAssertFalse(index.insert(SIMD3(0.4, 0, -0.5), camera: .zero, range: 1))
        XCTAssertFalse(index.contains(SIMD3(0.4, 0, -0.5)))
        XCTAssertTrue(index.insert(SIMD3(0, 0, -0.5), camera: .zero, range: 1))
    }
    func testPhotoCoverageNeedsACommittedRetainedPhoto() {
        var index = CapturedSurfaceIndex()
        let p = SIMD3<Float>(0, 0, -0.8)
        index.insert(p, camera: .zero, range: 1)
        XCTAssertTrue(index.contains(p))
        XCTAssertFalse(index.contains(p, requirePhoto: true))
        index.markPhotographed(p, photoID: 7) // not committed / retained yet
        XCTAssertFalse(index.isPhotographed(p))
        index.retainPhotos([7])
        index.markPhotographed(p, photoID: 7)
        XCTAssertTrue(index.isPhotographed(p))
        // A later depth-only observation keeps the photo mark.
        index.insert(p, camera: .zero, range: 1)
        XCTAssertTrue(index.contains(p, requirePhoto: true))
        index.retainPhotos([]) // a removed image cannot promise sharp colour
        XCTAssertFalse(index.contains(p, requirePhoto: true))
        XCTAssertTrue(index.contains(p))
    }
    func testPhotoDoesNotCreateGeometryOrPaintTheNextView() {
        var index = CapturedSurfaceIndex()
        let p = SIMD3<Float>(0, 0, -0.8), other = SIMD3<Float>(0.3, 0, -0.8)
        index.retainPhotos([1])
        index.markPhotographed(p, photoID: 1)
        XCTAssertFalse(index.contains(p))
        index.insert(other, camera: .zero, range: 1)
        index.markPhotographed(p, photoID: 1)
        XCTAssertFalse(index.contains(other, requirePhoto: true))
    }
    func testSmallTriangleCannotCrossRangeAtAnAcceptedCorner() {
        var index = CapturedSurfaceIndex()
        let a = SIMD3<Float>(0, 0, -0.99)
        index.insert(a, camera: .zero, range: 1)
        let observations = [index.sample(at: a)!]
        XCTAssertFalse(CapturedSurfaceIndex.withinObservedRange(a, SIMD3(0.1, 0, -1.08),
            SIMD3(0, 0.1, -1.08), observations: observations))
        XCTAssertTrue(CapturedSurfaceIndex.withinObservedRange(a, SIMD3(0.05, 0, -0.95),
            SIMD3(0, 0.05, -0.95), observations: observations))
    }
    func testEvidenceRetainsRealCameraColour() {
        var index = CapturedSurfaceIndex()
        let p = SIMD3<Float>(0, 0, -0.8), red = SIMD3<Float>(1, 0.1, 0.2)
        index.insert(p, camera: .zero, range: 1, color: red)
        XCTAssertEqual(index.sample(at: p)?.color, red)
    }
    func testCapacityFitsCombinedBudgetAndSaveReserve() {
        for available in [512.0, 700, 1024, 2048, 4096, 8192] {
            for spacing: Float in [4, 10, 20, 50] {
                for dense in [false, true] {
                    let limits = CaptureBudget.limits(dense: dense, detailMM: spacing, availableMB: available)
                    let bytes = Double(limits.points + limits.coverageCells) * CaptureBudget.bytesPerEntry
                    XCTAssertLessThanOrEqual(bytes, max(0, available - 600) * 1_048_576 * 0.35)
                    if !dense { XCTAssertEqual(limits.points, 0) }
                }
            }
        }
        XCTAssertEqual(CaptureBudget.limits(dense: true, detailMM: 10, availableMB: .nan).coverageCells, 0)
    }
    func testMaskErosionKeepsBackgroundExcludedAndRoundTrips() throws {
        let mask = PhotoRangeMask(width: 5, height: 5, pixels: Data(repeating: 255, count: 25), rangeMetres: 1)
        let eroded = mask.eroded()
        XCTAssertEqual(eroded.pixels.filter { $0 == 255 }.count, 9)
        XCTAssertEqual(eroded.pixels[0], 0)
        XCTAssertEqual(eroded.pixels[12], 255)
        XCTAssertEqual(try JSONDecoder().decode(PhotoRangeMask.self, from: JSONEncoder().encode(eroded)), eroded)
        XCTAssertFalse(PhotoRangeMask(width: 4, height: 4, pixels: Data(), rangeMetres: 1).isValid)
    }
    func testPointPickChoosesTouchedPixelNotForegroundElsewhereInDisc() {
        let touched = SIMD3<Float>(0, 0, 0.5)
        let adjacentForeground = SIMD3<Float>(0.12, 0, -0.8)
        let picker = PointCloudPicker(points: [adjacentForeground, touched])
        XCTAssertEqual(picker.pick(at: SIMD2(50, 50), viewport: SIMD2(100, 100), projection: matrix_identity_float4x4), touched)
    }
    func testMaskCompressionBoundsAndLegacyData() throws {
        let mask = PhotoRangeMask(width: 256, height: 192, pixels: Data(repeating: 255, count: 256 * 192), rangeMetres: 1)
        let encoded = try JSONEncoder().encode(mask)
        XCTAssertLessThan(encoded.count, 150)
        XCTAssertEqual(try JSONDecoder().decode(PhotoRangeMask.self, from: encoded), mask)
        let legacy = Data(#"{"width":2,"height":2,"pixels":"/wAA/w==","rangeMetres":1}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PhotoRangeMask.self, from: legacy).pixels, Data([255, 0, 0, 255]))
        let invalid = Data(#"{"width":2,"height":2,"runs":"////","rangeMetres":1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PhotoRangeMask.self, from: invalid))
    }
    func testSamePixelUsesFrontSurfaceAndRejectsEmptyOrClippedSpace() {
        let near = SIMD3<Float>(0, 0, -0.5), far = SIMD3<Float>(0, 0, 0.5)
        let picker = PointCloudPicker(points: [far, near, SIMD3(0, 0, -2)])
        XCTAssertEqual(picker.pick(at: SIMD2(50, 50), viewport: SIMD2(100, 100), projection: matrix_identity_float4x4), near)
        XCTAssertNil(picker.pick(at: SIMD2(80, 80), viewport: SIMD2(100, 100), projection: matrix_identity_float4x4))
    }
    func testLargeCloudDoesNotSkipEveryOtherPoint() {
        let points = (0..<1000).map { SIMD3<Float>(Float($0) / 500 - 1, 0, 0) }
        let picker = PointCloudPicker(points: points)
        XCTAssertEqual(picker.pick(at: SIMD2(50.1, 50), viewport: SIMD2(100, 100), projection: matrix_identity_float4x4, radius: 0.01), points[501])
    }
    func testOffCentreOrbitRebaseDoesNotMoveCamera() {
        let camera = SIMD3<Float>(3, 2, 10), pivot = SIMD3<Float>(-1, 0.4, -2)
        let q = simd_quatf(angle: 0.4, axis: SIMD3(0, 1, 0))
        let offset = WalkGeometry.orbitOffset(camera: camera, pivot: pivot, orientation: q)
        XCTAssertLessThan(simd_distance(pivot + q.act(offset), camera), 0.00001)
        let rotated = simd_quatf(angle: 0.7, axis: SIMD3(0, 1, 0))
        XCTAssertEqual(simd_length(rotated.act(offset)), simd_distance(camera, pivot), accuracy: 0.00001)
    }
    func testWalkGroundRejectsWallsFloorJumpsAndNonfiniteValues() {
        XCTAssertTrue(WalkGeometry.acceptsGround(previousY: 0, groundY: 0.15, normalY: 1))
        XCTAssertTrue(WalkGeometry.acceptsGround(previousY: 0, groundY: -0.15, normalY: -1))
        XCTAssertFalse(WalkGeometry.acceptsGround(previousY: 0, groundY: 3, normalY: 1))
        XCTAssertFalse(WalkGeometry.acceptsGround(previousY: 0, groundY: 0, normalY: 0.5))
        XCTAssertFalse(WalkGeometry.acceptsGround(previousY: 0, groundY: .nan, normalY: 1))
        XCTAssertEqual(WalkGeometry.eyeHeight, 1.8)
    }
}
