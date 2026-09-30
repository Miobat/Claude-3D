import XCTest
import simd
@testable import StorageCore

final class AutomaticMeasurementTests: XCTestCase {
    private let modelDigest = String(repeating: "a", count: 64)

    private func revision() -> MeasurementModelRevision {
        MeasurementModelRevision(modelSHA256: modelDigest, worldTransform: CoordinateMath.identity)
    }

    private func bounds(angle: Float = 0) -> UprightMeasurementBounds {
        let front = SIMD3<Float>(sin(angle), 0, cos(angle))
        return UprightMeasurementBounds(center: SIMD3(4, 1.65, -3),
            right: simd_cross(SIMD3(0, 1, 0), front), front: front, size: SIMD3(1.2, 0.9, 0.6))
    }

    private func document() -> AutomaticMeasurementDocument {
        AutomaticMeasurementDocument(revision: revision(), regions: [AutomaticMeasuredRegion(
            name: "Cabinet", kind: .object, bounds: bounds(), dimensions: [
                AutomaticDimension(axis: .width, metres: 1.2, evidence: .observedSpan),
                AutomaticDimension(axis: .height, metres: 0.9, evidence: .observedSpan),
                AutomaticDimension(axis: .depth, metres: nil, evidence: .unavailable)
            ])])
    }

    func testRotatedBoxDoesNotUseGlobalBoundingBox() throws {
        for angle: Float in [0, 0.25, .pi / 4, .pi / 2, -.pi * 0.9] {
            let expected = bounds(angle: angle)
            let fitted = try UprightMeasurementBounds.fit(points: expected.corners(), front: expected.front)
            XCTAssertLessThan(simd_distance(fitted.size, expected.size), 0.00001)
            XCTAssertLessThan(simd_distance(fitted.center, expected.center), 0.00001)
        }
    }

    func testRaisedCabinetDoesNotIncludeEmptySpaceToFloor() throws {
        let expected = bounds()
        let fitted = try UprightMeasurementBounds.fit(points: expected.corners(), front: expected.front)
        XCTAssertEqual(fitted.bottom, 1.2, accuracy: 0.00001)
        XCTAssertEqual(fitted.top, 2.1, accuracy: 0.00001)
        XCTAssertEqual(fitted.size.y, 0.9, accuracy: 0.00001)
    }

    func testNoPercentileTrimOfRealProtrusion() throws {
        let expected = bounds()
        // One real handle among many body points is still part of overall size.
        var points = Array(repeating: expected.corners(), count: 200).flatMap { $0 }
        points.append(expected.center + expected.front * 0.4)
        let fitted = try UprightMeasurementBounds.fit(points: points, front: expected.front)
        XCTAssertEqual(fitted.size.z, 0.7, accuracy: 0.00001)
    }

    func testFrontOnlyDoesNotInventDepth() throws {
        let selected = [SIMD3<Float>(0, 1, 0), SIMD3(1, 1, 0), SIMD3(1, 2, 0), SIMD3(0, 2, 0)]
        let fitted = try UprightMeasurementBounds.fit(points: selected, front: SIMD3(0, 0, 1))
        XCTAssertEqual(fitted.size.z, 0)
        XCTAssertNoThrow(try AutomaticDimension(axis: .depth, metres: nil, evidence: .unavailable).validate())
        XCTAssertThrowsError(try AutomaticDimension(axis: .depth, metres: 0, evidence: .observedSpan).validate())
    }

    func testInvalidGeometryRejectedNotSilentlyThinned() {
        XCTAssertThrowsError(try UprightMeasurementBounds.fit(points: [], front: SIMD3(0, 0, 1)))
        for bad: SIMD3<Float> in [SIMD3(.nan, 0, 0), SIMD3(0, .infinity, 0)] {
            XCTAssertThrowsError(try UprightMeasurementBounds.fit(points: [.zero, bad], front: SIMD3(0, 0, 1)))
        }
        for front: SIMD3<Float> in [.zero, SIMD3(0, 1, 0), SIMD3(.nan, 0, 1)] {
            XCTAssertThrowsError(try UprightMeasurementBounds.fit(points: bounds().corners(), front: front))
        }
    }

    func testInvalidAndMirroredAxesRejected() {
        var bad = bounds(); bad.right = -bad.right
        XCTAssertThrowsError(try bad.validate())
        bad = bounds(); bad.size.x = -1
        XCTAssertThrowsError(try bad.validate())
        bad = bounds(); bad.front = bad.right
        XCTAssertThrowsError(try bad.validate())
    }

    func testFaceRemappingPreservesExactLabels() throws {
        let result = try SurfaceLabelDocument.retaining([3, 0, 2], from: Data([1, 2, 3, 4]), originalFaceCount: 4)
        XCTAssertEqual(result, Data([4, 1, 3]))
        XCTAssertNil(try SurfaceLabelDocument.retaining([0], from: nil, originalFaceCount: 1))
        XCTAssertEqual(try SurfaceLabelDocument.retaining([], from: Data([1]), originalFaceCount: 1), Data())
    }

    func testStreamingRemapAndConflictingDuplicate() {
        var labels = FaceLabelAccumulator(classifications: Data([1, 2, 3, 4]), faceCount: 4)
        labels.keep(3); labels.keep(0)
        XCTAssertEqual(labels.data, Data([4, 1]))
        labels.mergeDuplicate(2, into: 0)
        XCTAssertEqual(labels.data, Data([0, 1]))
        labels.mergeDuplicate(3, into: 0) // a later duplicate cannot restore certainty
        XCTAssertEqual(labels.data, Data([0, 1]))
        labels.keep(4)
        XCTAssertNil(labels.data) // invalid mapping must not leave a partial label list
        var missing = FaceLabelAccumulator(classifications: nil, faceCount: 4)
        missing.keep(0); XCTAssertNil(missing.data)
        var invalid = FaceLabelAccumulator(classifications: Data([1]), faceCount: 4)
        invalid.keep(0); XCTAssertNil(invalid.data)
    }

    func testIncorrectFaceMappingsRejected() {
        XCTAssertThrowsError(try SurfaceLabelDocument.retaining([0], from: Data([1, 2]), originalFaceCount: 1))
        for index in [-1, 2] {
            XCTAssertThrowsError(try SurfaceLabelDocument.retaining([index], from: Data([1, 2]), originalFaceCount: 2))
        }
    }

    func testUnclassifiedAndFutureCategoriesAreNotWalls() throws {
        let doc = SurfaceLabelDocument(modelSHA256: modelDigest, viewerSHA256: modelDigest, faceCount: 3,
                                       classifications: Data([0, 255, 1]))
        try doc.validate()
        XCTAssertEqual(doc.category(at: 0), .unknown)
        XCTAssertEqual(doc.category(at: 1), .unknown)
        XCTAssertEqual(doc.category(at: 2), .wall)
        XCTAssertEqual(doc.category(at: -1), .unknown)
        XCTAssertEqual(doc.category(at: 3), .unknown)
    }

    func testSurfaceMetadataRoundTripAndValidation() throws {
        var doc = SurfaceLabelDocument(modelSHA256: modelDigest, viewerSHA256: modelDigest, faceCount: 2, classifications: Data([2, 1]))
        XCTAssertEqual(try JSONDecoder().decode(SurfaceLabelDocument.self, from: JSONEncoder().encode(doc)), doc)
        doc.faceCount = 3
        XCTAssertThrowsError(try doc.validate())
        doc.faceCount = 2; doc.modelSHA256 = "bad"
        XCTAssertThrowsError(try doc.validate())
        doc.modelSHA256 = modelDigest; doc.version = 2
        XCTAssertThrowsError(try doc.validate())
    }

    func testWallBasedDepthRequiresExplicitConfirmation() {
        var value = AutomaticDimension(axis: .depth, metres: 0.6, evidence: .assumedFlushToWall)
        XCTAssertThrowsError(try value.validate())
        value.wallContactConfirmed = false
        XCTAssertThrowsError(try value.validate())
        value.wallContactConfirmed = true
        XCTAssertNoThrow(try value.validate())
    }

    func testUnavailableCannotCarryPlausibleNumber() {
        XCTAssertThrowsError(try AutomaticDimension(axis: .depth, metres: 0.6, evidence: .unavailable).validate())
        for metres: Float in [-1, 0, .nan, .infinity] {
            XCTAssertThrowsError(try AutomaticDimension(axis: .height, metres: metres, evidence: .partial).validate())
        }
    }

    func testAutomaticDocumentRoundTrip() throws {
        let expected = document()
        XCTAssertEqual(try AutomaticMeasurementDocument.decode(expected.encoded()), expected)
    }

    func testModelChangesInvalidateResults() {
        let doc = document()
        var changed = revision(); changed.modelSHA256 = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try doc.validate(for: changed))
        changed = revision(); changed.worldTransform[12] = 0.1
        XCTAssertThrowsError(try doc.validate(for: changed))
        changed = revision(); changed.viewerSHA256 = modelDigest
        XCTAssertThrowsError(try doc.validate(for: changed))
        XCTAssertNoThrow(try doc.validate(for: revision()))
    }

    func testDuplicateRecordIDsAndDuplicateAxesRejected() {
        var doc = document(); doc.regions.append(doc.regions[0])
        XCTAssertThrowsError(try doc.validate())
        doc = document(); doc.regions[0].dimensions[2].axis = .width
        XCTAssertThrowsError(try doc.validate())
    }

    func testLabelsCannotDisagreeWithSelectionBox() {
        var doc = document(); doc.regions[0].dimensions[0].metres = 2.4
        XCTAssertThrowsError(try doc.validate())
    }

    func testFutureVersionCheckedBeforeUnknownTypes() {
        let data = Data(#"{"version":2,"regions":[{"kind":"future-shape"}]}"#.utf8)
        XCTAssertThrowsError(try AutomaticMeasurementDocument.decode(data)) { error in
            guard case AutomaticMeasurementError.unsupportedVersion = error else {
                return XCTFail("Future file must be identified before decoding unfamiliar enums: \(error)")
            }
        }
    }

    func testInvalidHashesTransformsAndOversizedDocumentsRejected() {
        var value = revision(); value.worldTransform = []
        XCTAssertThrowsError(try value.validate())
        value = revision(); value.modelSHA256 = String(repeating: "g", count: 64)
        XCTAssertThrowsError(try value.validate())
        XCTAssertThrowsError(try AutomaticMeasurementDocument.decode(Data(repeating: 32, count: 4_000_001)))
    }
}
