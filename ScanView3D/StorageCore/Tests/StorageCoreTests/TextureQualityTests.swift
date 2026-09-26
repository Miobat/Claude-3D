import Foundation
import XCTest
import simd
@testable import StorageCore

final class TextureQualityTests: XCTestCase {
    func testCloseObjectsRequireSlowerMovement() {
        let close = TextureQualityMath.motionBlur(turn: 0, move: 0.01, seconds: 0.1, exposure: 0.01, focalPixels: 1000, distance: 0.25)
        let far = TextureQualityMath.motionBlur(turn: 0, move: 0.01, seconds: 0.1, exposure: 0.01, focalPixels: 1000, distance: 2)
        XCTAssertEqual(close, far * 8, accuracy: 0.0001)
    }
    func testRotationBlurDoesNotDependOnDistance() {
        XCTAssertEqual(TextureQualityMath.motionBlur(turn: 0.1, move: 0, seconds: 0.1, exposure: 0.01, focalPixels: 1000, distance: 1), 10, accuracy: 0.001)
    }
    func testInvalidMotionDoesNotClaimSharp() {
        XCTAssertFalse(TextureQualityMath.motionBlur(turn: 0, move: 0, seconds: 0, exposure: 1, focalPixels: 1, distance: 1).isFinite)
        XCTAssertFalse(TextureQualityMath.motionBlur(turn: .nan, move: 0, seconds: 1, exposure: 1, focalPixels: 1, distance: 1).isFinite)
    }
    func testNearZeroDepthIsBounded() {
        XCTAssertEqual(TextureQualityMath.motionBlur(turn: 0, move: 0.15, seconds: 1, exposure: 1, focalPixels: 1, distance: 0), 1, accuracy: 0.0001)
    }
    func testSharpBoundary() {
        XCTAssertTrue(TextureFrameQuality(blurPixels: 2.5).permitsSharpCoverage)
        XCTAssertFalse(TextureFrameQuality(blurPixels: 2.51).permitsSharpCoverage)
        XCTAssertFalse(TextureFrameQuality(blurPixels: .infinity).permitsSharpCoverage)
    }
    func testClippedFramesDoNotClaimSharpCoverage() {
        let q = TextureFrameQuality.measure(luma: [255, 255, 255, 100], blurPixels: 0)
        XCTAssertEqual(q.clippedFraction, 0.75)
        XCTAssertFalse(q.permitsSharpCoverage)
        XCTAssertNotNil(q.lightingHint)
    }
    func testDarkFramesDoNotClaimSharpCoverage() {
        let q = TextureFrameQuality.measure(luma: Array(repeating: 0, count: 10), blurPixels: 0)
        XCTAssertFalse(q.permitsSharpCoverage)
        XCTAssertNotNil(q.lightingHint)
    }
    func testWellExposedFramesHaveNoLightingWarning() {
        let q = TextureFrameQuality.measure(luma: [80, 120, 180], blurPixels: 1)
        XCTAssertTrue(q.permitsSharpCoverage)
        XCTAssertNil(q.lightingHint)
    }
    func testBlurAndLightingReducePhotoScore() {
        func score(_ q: TextureFrameQuality) -> Float {
            TextureQualityMath.viewScore(facing: 1, alignment: 1, centre: 1, distance: 1, quality: q)
        }
        XCTAssertGreaterThan(score(.init()), score(.init(blurPixels: 4)))
        XCTAssertGreaterThan(score(.init()), score(.init(clippedFraction: 0.5)))
        XCTAssertEqual(score(.init(blurPixels: .nan)), 0)
    }
    func testInvalidViewHasNoPhotoScore() {
        XCTAssertEqual(TextureQualityMath.viewScore(facing: 0, alignment: 1, centre: 1, distance: 1, quality: .init()), 0)
        XCTAssertEqual(TextureQualityMath.viewScore(facing: 1, alignment: 1, centre: 1, distance: .nan, quality: .init()), 0)
    }
    func testPatchSmoothingPreservesOriginalQualityBudget() {
        XCTAssertTrue(TextureQualityMath.canAdopt(current: 1, candidate: 0.85, currentSharp: true, candidateSharp: true))
        XCTAssertFalse(TextureQualityMath.canAdopt(current: 1, candidate: 0.84, currentSharp: true, candidateSharp: true))
    }
    func testPatchSmoothingNeverTradesSharpForSoft() {
        XCTAssertFalse(TextureQualityMath.canAdopt(current: 1, candidate: 100, currentSharp: true, candidateSharp: false))
        XCTAssertTrue(TextureQualityMath.canAdopt(current: 100, candidate: 0.01, currentSharp: false, candidateSharp: true))
    }
    func testInvalidPatchAlternativeRejected() {
        for value in [Float(0), -.infinity, .nan] {
            XCTAssertFalse(TextureQualityMath.canAdopt(current: 0, candidate: value, currentSharp: false, candidateSharp: true))
        }
    }
    func testPaletteRoundTripAndBounds() {
        for key in 0..<4096 { XCTAssertEqual(TextureQualityMath.paletteKey(TextureQualityMath.paletteColor(key)), key) }
        XCTAssertEqual(TextureQualityMath.paletteKey(SIMD3(-1, 2, 0)), 0x0f0)
        XCTAssertTrue((0..<4096).contains(TextureQualityMath.paletteKey(SIMD3(.nan, .infinity, -.infinity))))
    }
    func testSeamCorrectionDirectionAndAnchor() {
        let gains = TextureSeamCorrection.gains(frameCount: 2, matches: [.init(a: 0, b: 1, logRatio: log(1.2), weight: 10)])
        XCTAssertEqual(gains[0], 1)
        XCTAssertEqual(gains[1], 1.2, accuracy: 0.001)
    }
    func testSeamCorrectionsAreBounded() {
        for ratio in [Float(0.01), 100] {
            let gains = TextureSeamCorrection.gains(frameCount: 2, matches: [.init(a: 0, b: 1, logRatio: log(ratio), weight: 1)])
            XCTAssertGreaterThanOrEqual(gains[1], 0.7999)
            XCTAssertLessThanOrEqual(gains[1], 1.2501)
        }
    }
    func testDisconnectedPhotosRemainIndependent() {
        let gains = TextureSeamCorrection.gains(frameCount: 5, matches: [.init(a: 1, b: 3, logRatio: log(1.1), weight: 1)])
        XCTAssertEqual(gains[0], 1); XCTAssertEqual(gains[1], 1); XCTAssertEqual(gains[2], 1); XCTAssertEqual(gains[4], 1)
        XCTAssertEqual(gains[3], 1.1, accuracy: 0.001)
    }
    func testInvalidOverlapCannotAffectExposure() {
        let edges: [TextureSeamMatch] = [.init(a: -1, b: 0, logRatio: 1, weight: 1),
            .init(a: 0, b: 2, logRatio: 1, weight: 1), .init(a: 0, b: 1, logRatio: .nan, weight: 1),
            .init(a: 0, b: 1, logRatio: 1, weight: 0)]
        XCTAssertEqual(TextureSeamCorrection.gains(frameCount: 2, matches: edges), [1, 1])
    }
    func testLinearLuminanceUsesSRGBTransfer() {
        XCTAssertEqual(TextureQualityMath.linearLuminance(SIMD3(repeating: 0.5)), 0.21404, accuracy: 0.0001)
        XCTAssertEqual(TextureQualityMath.linearLuminance(SIMD3(repeating: 1)), 1, accuracy: 0.0001)
    }
    func testAreaReportRoundTrip() throws {
        let report = TextureQualityReport(sharpArea: 6, softArea: 3, fallbackArea: 1, atlasSize: 2048, atlasScale: 0.75, photoCount: 12)
        XCTAssertEqual(report.sharpFraction, 0.6, accuracy: 0.0001)
        XCTAssertEqual(report.softFraction + report.fallbackFraction, 0.4, accuracy: 0.0001)
        XCTAssertEqual(try JSONDecoder().decode(TextureQualityReport.self, from: JSONEncoder().encode(report)), report)
    }
    func testEmptyAreaReportIsNotComplete() {
        let report = TextureQualityReport(sharpArea: 0, softArea: 0, fallbackArea: 0, atlasSize: 2048, atlasScale: 1, photoCount: 0)
        XCTAssertEqual(report.sharpFraction, 0); XCTAssertEqual(report.fallbackFraction, 0)
    }
}
