import XCTest
import simd
@testable import StorageCore

final class CaptureAuditTests: XCTestCase {
    func testLaterDepthRepresentativeDoesNotMovePhotoEvidence() {
        var index = CapturedSurfaceIndex(cellSize: 0.025)
        let photographed = SIMD3<Float>(0.001, 0.001, -0.999)
        let changed = SIMD3<Float>(0.024, 0.024, -0.976)
        XCTAssertTrue(index.insert(photographed, camera: .zero, range: 2))
        index.retainPhotos([1])
        index.markPhotographed(photographed, photoID: 1)
        XCTAssertTrue(index.isPhotographed(photographed))
        XCTAssertTrue(index.insert(changed, camera: .zero, range: 2))
        XCTAssertTrue(index.contains(changed))
        XCTAssertFalse(index.isPhotographed(changed))
        XCTAssertFalse(index.contains(changed, requirePhoto: true))
        index.markPhotographed(changed, photoID: 1)
        XCTAssertTrue(index.isPhotographed(changed))
    }

    func testExtremeFiniteToleranceIsBoundedBeforeIntegerConversion() {
        let index = CapturedSurfaceIndex(cellSize: 0.005)
        XCTAssertNil(index.sample(at: .zero, tolerance: .greatestFiniteMagnitude))
        XCTAssertNil(index.sample(at: .zero, tolerance: .infinity))
        XCTAssertNil(index.sample(at: .zero, tolerance: .nan))
        XCTAssertNil(index.sample(at: .zero, tolerance: -1))
    }

    func testInvalidCoverageColorDoesNotPoisonRecoverySamples() {
        var index = CapturedSurfaceIndex()
        for color: SIMD3<Float> in [SIMD3(.nan, 0, 0), SIMD3(0, .infinity, 0), SIMD3(0, 0, -.infinity)] {
            XCTAssertFalse(index.insert(SIMD3(0, 0, -1), camera: .zero, range: 2, color: color))
        }
        XCTAssertTrue(index.cells.isEmpty)
    }

    func testInvalidCellSizeDoesNotCollapseAllWorldCoverageIntoOneCell() {
        for size: Float in [.nan, .infinity, -.infinity] {
            var index = CapturedSurfaceIndex(cellSize: size)
            XCTAssertEqual(index.cellSize, 0.025)
            XCTAssertTrue(index.insert(SIMD3(0, 0, -1), camera: .zero, range: 2))
            XCTAssertTrue(index.insert(SIMD3(0.5, 0, -1), camera: .zero, range: 2))
            XCTAssertEqual(index.cells.count, 2)
        }
    }
}
