import XCTest
import simd
@testable import StorageCore

final class ScanRetentionTests: XCTestCase {
    func testSparseWallsAndThinStemsAreNotSmallDebris() {
        XCTAssertTrue(MeshRetentionPolicy.keepComponent(vertices: 4, minimumVertices: 150, area: 2, extent: SIMD3(2, 1, 0)))
        XCTAssertTrue(MeshRetentionPolicy.keepComponent(vertices: 8, minimumVertices: 150, area: 0.003, extent: SIMD3(0.01, 0.3, 0.01)))
        XCTAssertFalse(MeshRetentionPolicy.keepComponent(vertices: 4, minimumVertices: 30, area: 0.00001, extent: SIMD3(repeating: 0.004)))
    }

    func testReportUsesPhysicalAreaNotTriangleCount() throws {
        let a = MeshRetentionReport.Stage(vertices: 200, faces: 100, area: 10)
        let b = MeshRetentionReport.Stage(vertices: 100, faces: 50, area: 9.9)
        let report = MeshRetentionReport(cleanup: "Balanced", captured: a, cleaned: b, saved: b)
        XCTAssertEqual(report.removedAreaFraction, 0.01, accuracy: 0.000001)
        XCTAssertEqual(report, try JSONDecoder().decode(MeshRetentionReport.self, from: JSONEncoder().encode(report)))
    }

    func testPhotoMaskRejectsLocalClippingWithoutRejectingPlainWalls() {
        let plain = PhotoPatchQuality.mask(luma: Array(repeating: 220, count: 81), width: 9, height: 9)
        XCTAssertEqual(plain[40], 255, "Low texture does not mean blurred")
        for value: UInt8 in [0, 255] {
            var pixels = [UInt8](repeating: 160, count: 81)
            for y in 2...5 { for x in 2...5 { pixels[y * 9 + x] = value } }
            let mask = PhotoPatchQuality.mask(luma: pixels, width: 9, height: 9)
            XCTAssertEqual(mask[4 * 9 + 4], 0, "Bad local exposure cannot borrow the frame average")
            XCTAssertEqual(mask[7 * 9 + 7], 255)
        }
        XCTAssertTrue(PhotoPatchQuality.mask(luma: [1], width: 100, height: 100).isEmpty)
    }

    func testOverlayModesDoNotClaimPhotosInShapeOnlyCapture() {
        XCTAssertEqual(CaptureOverlayMode.off.shaderValue(hasPhotos: true), 0)
        XCTAssertEqual(CaptureOverlayMode.shape.shaderValue(hasPhotos: true), 1)
        XCTAssertEqual(CaptureOverlayMode.combined.shaderValue(hasPhotos: true), 2)
        XCTAssertEqual(CaptureOverlayMode.photos.shaderValue(hasPhotos: true), 3)
        XCTAssertEqual(CaptureOverlayMode.photos.shaderValue(hasPhotos: false), 1)
    }
}
