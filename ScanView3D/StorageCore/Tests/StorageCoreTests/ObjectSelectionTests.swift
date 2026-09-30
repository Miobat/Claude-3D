import XCTest
import simd
@testable import StorageCore

final class ObjectSelectionTests: XCTestCase {
    private func box(angle: Float = 0, bottom: Float = 0) -> (points: [SIMD3<Float>], faces: [SIMD3<UInt32>], front: SIMD3<Float>) {
        let front = SIMD3<Float>(sin(angle), 0, cos(angle)), right = simd_cross(SIMD3(0, 1, 0), front)
        let bounds = UprightMeasurementBounds(center: SIMD3(0, bottom + 0.5, 0), right: right, front: front, size: SIMD3(1.2, 1, 0.6))
        let faces: [SIMD3<UInt32>] = [SIMD3(4, 5, 7), SIMD3(4, 7, 6), SIMD3(0, 2, 3), SIMD3(0, 3, 1),
            SIMD3(0, 4, 6), SIMD3(0, 6, 2), SIMD3(1, 3, 7), SIMD3(1, 7, 5),
            SIMD3(2, 6, 7), SIMD3(2, 7, 3), SIMD3(0, 1, 5), SIMD3(0, 5, 4)]
        return (bounds.corners(), faces, front)
    }
    func testRotatedClosedBoxAndRaisedHeight() throws {
        for angle: Float in [0, 0.37, -.pi / 3] {
            let mesh = box(angle: angle, bottom: 1.2)
            let index = try ObjectSelectionIndex(points: mesh.points, triangles: mesh.faces)
            let selection = try index.grow(from: 0, radius: 2)
            XCTAssertEqual(selection.selection.ids.count, 12)
            let region = try index.region(selection: selection.selection, front: mesh.front, partial: false)
            XCTAssertEqual(region.bounds.size.x, 1.2, accuracy: 0.00001)
            XCTAssertEqual(region.bounds.size.y, 1, accuracy: 0.00001)
            XCTAssertEqual(region.bounds.size.z, 0.6, accuracy: 0.00001)
            XCTAssertEqual(region.bounds.bottom, 1.2, accuracy: 0.00001)
        }
    }
    func testConnectedFloorDoesNotLeakIntoSelection() throws {
        var mesh = box()
        mesh.points.append(contentsOf: [SIMD3(-3, 0, -3), SIMD3(3, 0, -3)])
        mesh.faces.append(SIMD3(0, 8, 9)) // shares an object vertex
        let index = try ObjectSelectionIndex(points: mesh.points, triangles: mesh.faces, labels: Data(Array(repeating: UInt8(0), count: 12) + [2]))
        let result = try index.grow(from: 0, radius: 5)
        XCTAssertFalse(result.selection.ids.contains(12))
        XCTAssertThrowsError(try index.grow(from: 12, radius: 5))
    }
    func testVerticalSurfaceMislabeledFloorRemainsSelectable() throws {
        let mesh = box()
        let index = try ObjectSelectionIndex(points: mesh.points, triangles: mesh.faces, labels: Data(repeating: 2, count: 12))
        XCTAssertFalse(index.structural.contains(0))
        XCTAssertTrue(try index.grow(from: 0, radius: 2).selection.ids.contains(0))
    }
    func testDisconnectedNoiseExcludedButConnectedHandleRetained() throws {
        var mesh = box()
        mesh.points.append(contentsOf: [SIMD3(0, 0.5, 0.45), SIMD3(2, 0, 0), SIMD3(2.1, 0, 0), SIMD3(2, 0.1, 0)])
        mesh.faces.append(SIMD3(4, 5, 8)); mesh.faces.append(SIMD3(9, 10, 11))
        let index = try ObjectSelectionIndex(points: mesh.points, triangles: mesh.faces)
        let result = try index.grow(from: 0, radius: 5)
        XCTAssertTrue(result.selection.ids.contains(12)); XCTAssertFalse(result.selection.ids.contains(13))
        let region = try index.region(selection: result.selection, front: mesh.front, partial: false)
        XCTAssertEqual(region.bounds.size.z, 0.75, accuracy: 0.00001)
    }
    func testUVExpandedVerticesAndSeamAcrossBucketBoundaryConnect() throws {
        let points: [SIMD3<Float>] = [SIMD3(0.0059, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0),
                                   SIMD3(0.0061, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)]
        let index = try ObjectSelectionIndex(points: points, triangles: [SIMD3(0, 1, 2), SIMD3(3, 4, 5)])
        XCTAssertEqual(try index.grow(from: 0, radius: 2).selection.ids, [0, 1])
    }
    func testFrontOnlyDepthIsUnavailable() throws {
        let points: [SIMD3<Float>] = [SIMD3(0, 0.8, 0), SIMD3(1, 0.8, 0.002), SIMD3(1, 1.8, 0), SIMD3(0, 1.8, 0)]
        let index = try ObjectSelectionIndex(points: points, triangles: [SIMD3(0, 1, 2), SIMD3(0, 2, 3)])
        let selection = try index.grow(from: 0, radius: 2).selection
        let region = try index.region(selection: selection, front: SIMD3(0, 0, 1), partial: false)
        XCTAssertNil(region.dimensions.first { $0.axis == .depth }?.metres)
        XCTAssertEqual(region.dimensions.first { $0.axis == .depth }?.evidence, .unavailable)
    }
    func testReachClippingIsExplicitAndDoesNotDropOuterVertices() throws {
        let points: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(0.1, 0, 0), SIMD3(0, 0.1, 0), SIMD3(2, 0, 0)]
        let index = try ObjectSelectionIndex(points: points, triangles: [SIMD3(0, 1, 2), SIMD3(1, 2, 3)])
        let result = try index.grow(from: 0, radius: 0.3)
        XCTAssertTrue(result.touchesLimit); XCTAssertEqual(result.selection.ids, [0])
        let region = try index.region(selection: result.selection, front: SIMD3(0, 0, 1), partial: result.touchesLimit)
        XCTAssertEqual(region.dimensions.first { $0.axis == .width }?.evidence, .partial)
    }
    func testBrushHitsLargeTriangleAwayFromCentroidAndCanUndoEmpty() throws {
        let index = try ObjectSelectionIndex(points: [SIMD3(0, 1, 0), SIMD3(1, 1, 0), SIMD3(0, 2, 0)], triangles: [SIMD3(0, 1, 2)])
        let p = SIMD3<Float>(0.02, 1.02, 0)
        XCTAssertEqual(index.nearest(to: p), 0)
        let selection = try XCTUnwrap(index.brush(nil, at: p, radius: 0.03, adding: true))
        XCTAssertEqual(selection.ids, [0])
        XCTAssertNil(try index.brush(selection, at: p, radius: 0.03, adding: false))
    }
    func testPointCloudConnectedComponentIsAlwaysPartial() throws {
        let points = (0..<10).map { SIMD3<Float>(Float($0) * 0.03, 1, 0) } + [SIMD3<Float>(4, 1, 0)]
        let index = try ObjectSelectionIndex(points: points, triangles: [])
        let result = try index.grow(from: 0, radius: 1)
        XCTAssertEqual(result.selection.kind, .points); XCTAssertEqual(result.selection.ids.count, 10)
        let region = try index.region(selection: result.selection, front: SIMD3(0, 0, 1), partial: false)
        XCTAssertEqual(region.dimensions.first { $0.axis == .width }?.evidence, .partial)
        XCTAssertNil(region.dimensions.first { $0.axis == .depth }?.metres)
    }
    func testSelectionPackedRoundTripAndRevisionBinding() throws {
        let mesh = box(), index = try ObjectSelectionIndex(points: mesh.points, triangles: mesh.faces)
        let selection = try index.grow(from: 0, radius: 2).selection
        let region = try index.region(selection: selection, front: mesh.front, partial: false)
        let revision = MeasurementModelRevision(modelSHA256: String(repeating: "a", count: 64), worldTransform: CoordinateMath.identity)
        let doc = AutomaticMeasurementDocument(revision: revision, regions: [region])
        let restored = try AutomaticMeasurementDocument.decode(doc.encoded())
        XCTAssertEqual(restored.regions[0].selection, selection)
        XCTAssertNoThrow(try index.validate(try XCTUnwrap(restored.regions[0].selection)))
        var changed = revision; changed.modelSHA256 = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try restored.validate(for: changed))
    }
    func testMalformedIDsWrongTopologyAndInvalidGeometryRejected() throws {
        let mesh = box(), index = try ObjectSelectionIndex(points: mesh.points, triangles: mesh.faces)
        var selection = try AutomaticRegionSelection(kind: .triangles, ids: [0])
        selection.packedIDs.append(0); XCTAssertThrowsError(try selection.validate())
        XCTAssertThrowsError(try index.validate(AutomaticRegionSelection(kind: .points, ids: [0])))
        XCTAssertThrowsError(try index.validate(AutomaticRegionSelection(kind: .triangles, ids: [12])))
        XCTAssertThrowsError(try ObjectSelectionIndex(points: [SIMD3(.nan, 0, 0)], triangles: []))
        XCTAssertThrowsError(try ObjectSelectionIndex(points: mesh.points, triangles: [SIMD3(0, 1, 100)]))
        XCTAssertThrowsError(try ObjectSelectionIndex(points: mesh.points, triangles: mesh.faces, labels: Data([1])))
        XCTAssertThrowsError(try index.grow(from: 0, radius: .nan))
        XCTAssertThrowsError(try index.brush(nil, at: .zero, radius: -1, adding: true))
    }
    func testCancellationAndMemoryLimitAreExplicit() throws {
        let mesh = box(), index = try ObjectSelectionIndex(points: mesh.points, triangles: mesh.faces)
        XCTAssertThrowsError(try ObjectSelectionIndex(points: mesh.points, triangles: mesh.faces, cancelled: { true }))
        XCTAssertThrowsError(try index.grow(from: 0, radius: 2, cancelled: { true }))
        XCTAssertThrowsError(try AutomaticRegionSelection(kind: .triangles, ids: Array(0...ObjectSelectionIndex.maximumSelection)))
        XCTAssertThrowsError(try ObjectSelectionIndex(points: Array(repeating: SIMD3<Float>.zero, count: ObjectSelectionIndex.maximumPoints + 1), triangles: []))
    }
    func testLargeWallStopsButSmallWallLabeledCabinetDoesNot() throws {
        var mesh = box()
        mesh.points.append(contentsOf: [SIMD3(0.6, 0, -3), SIMD3(0.6, 3, -3), SIMD3(0.6, 3, 3), SIMD3(0.6, 0, 3)])
        mesh.faces.append(contentsOf: [SIMD3(1, 8, 9), SIMD3(8, 10, 9), SIMD3(8, 11, 10)])
        let index = try ObjectSelectionIndex(points: mesh.points, triangles: mesh.faces, labels: Data(repeating: 1, count: mesh.faces.count))
        XCTAssertFalse(index.structural.contains(0))
        let result = try index.grow(from: 0, radius: 5)
        XCTAssertFalse(result.selection.ids.contains(12)); XCTAssertFalse(result.selection.ids.contains(13))
    }

    func testWallDepthNeedsExplicitContactAndPreservesFrontDatum() throws {
        var mesh = box(bottom: 0.7)
        mesh.points.append(contentsOf: [SIMD3(-2, 0, -0.8), SIMD3(2, 0, -0.8), SIMD3(2, 3, -0.8), SIMD3(-2, 3, -0.8)])
        mesh.faces.append(contentsOf: [SIMD3(8, 9, 10), SIMD3(8, 10, 11)])
        let index = try ObjectSelectionIndex(points: mesh.points, triangles: mesh.faces, labels: Data(Array(repeating: UInt8(0), count: 12) + [1, 1]))
        let selection = try index.grow(from: 0, radius: 2).selection
        let region = try index.region(selection: selection, front: mesh.front, partial: false)
        XCTAssertEqual(try XCTUnwrap(index.wallDepth(for: region)).metres, 1.1, accuracy: 0.00001)
        XCTAssertThrowsError(try index.assumingWallContact(region, confirmed: false))
        let assumed = try index.assumingWallContact(region, confirmed: true)
        XCTAssertEqual(assumed.bounds.size.z, 1.1, accuracy: 0.00001)
        XCTAssertEqual(assumed.bounds.size.x, region.bounds.size.x)
        XCTAssertEqual(assumed.bounds.bottom, region.bounds.bottom)
        XCTAssertEqual(assumed.bounds.center.z + assumed.bounds.size.z * 0.5, 0.3, accuracy: 0.00001)
        let depth = try XCTUnwrap(assumed.dimensions.first { $0.axis == .depth })
        XCTAssertEqual(depth.evidence, .assumedFlushToWall); XCTAssertEqual(depth.wallContactConfirmed, true)
        XCTAssertNoThrow(try assumed.validate())
    }
    func testFreeStandingBoxDoesNotInventWallDepth() throws {
        let mesh = box(), index = try ObjectSelectionIndex(points: mesh.points, triangles: mesh.faces)
        let region = try index.region(selection: index.grow(from: 0, radius: 2).selection, front: mesh.front, partial: false)
        XCTAssertNil(index.wallDepth(for: region))
        XCTAssertThrowsError(try index.assumingWallContact(region, confirmed: true))
    }

    func testOpenedTopologyFingerprintRejectsSameCountReorderingAndTransform() throws {
        let mesh = box(), index = try ObjectSelectionIndex(points: mesh.points, triangles: mesh.faces)
        let selection = try index.grow(from: 0, radius: 2).selection
        XCTAssertEqual(selection.geometrySHA256, index.geometrySHA256)
        let reordered = try ObjectSelectionIndex(points: mesh.points, triangles: Array(mesh.faces.reversed()))
        XCTAssertThrowsError(try reordered.validate(selection))
        let moved = try ObjectSelectionIndex(points: mesh.points.map { $0 + SIMD3(0, 1, 0) }, triangles: mesh.faces)
        XCTAssertThrowsError(try moved.validate(selection))
        let identical = try ObjectSelectionIndex(points: mesh.points, triangles: mesh.faces)
        XCTAssertNoThrow(try identical.validate(selection))
        var legacy = selection; legacy.geometrySHA256 = nil
        XCTAssertThrowsError(try identical.validate(legacy)) // review-only, not guessed
    }

    func testLegacyShapeOnlyFloorSurvivesDisconnectedLowNoise() throws {
        var mesh = box()
        mesh.points.append(contentsOf: [SIMD3(-3, 0, -3), SIMD3(3, 0, -3), SIMD3(0, -1, 0)])
        mesh.faces.append(SIMD3(0, 8, 9))
        let index = try ObjectSelectionIndex(points: mesh.points, triangles: mesh.faces)
        XCTAssertTrue(index.structural.contains(12))
        XCTAssertFalse(try index.grow(from: 0, radius: 5).selection.ids.contains(12))
    }
}
