import XCTest
import simd
@testable import StorageCore

final class ObjectBoundaryTests: XCTestCase {
    private struct Mesh {
        var points: [SIMD3<Float>] = []
        var faces: [SIMD3<UInt32>] = []
        mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            let i = UInt32(points.count); points += [a, b, c, d]
            faces += [SIMD3(i, i + 1, i + 2), SIMD3(i, i + 2, i + 3)]
        }
        mutating func box(center: SIMD3<Float>, size: SIMD3<Float>, angle: Float = 0) {
            let front = SIMD3<Float>(sin(angle), 0, cos(angle))
            let bounds = UprightMeasurementBounds(center: center, right: simd_cross(SIMD3(0, 1, 0), front), front: front, size: size)
            let i = UInt32(points.count); points += bounds.corners()
            faces += [SIMD3<UInt32>(4,5,7), SIMD3(4,7,6), SIMD3(0,2,3), SIMD3(0,3,1),
                      SIMD3(0,4,6), SIMD3(0,6,2), SIMD3(1,3,7), SIMD3(1,7,5),
                      SIMD3(2,6,7), SIMD3(2,7,3), SIMD3(0,1,5), SIMD3(0,5,4)].map { $0 &+ SIMD3(repeating: i) }
        }
        mutating func floor(size: Float = 4) {
            quad(SIMD3(-size,0,-size), SIMD3(size,0,-size), SIMD3(size,0,size), SIMD3(-size,0,size))
        }
        mutating func wallWithOpening() {
            func p(_ x: Float, _ y: Float) -> SIMD3<Float> { SIMD3(x,y,0) }
            quad(p(-2,0), p(-0.8,0), p(-0.8,3), p(-2,3))
            quad(p(0.8,0), p(2,0), p(2,3), p(0.8,3))
            quad(p(-0.8,0), p(0.8,0), p(0.8,0.7), p(-0.8,0.7))
            quad(p(-0.8,2.3), p(0.8,2.3), p(0.8,3), p(-0.8,3))
        }
        func index() throws -> ObjectSelectionIndex { try ObjectSelectionIndex(points: points, triangles: faces) }
    }

    func testAutomaticBoundaryFindsWholeLargeObjectWithoutSettingReach() throws {
        var mesh = Mesh()
        mesh.box(center: SIMD3(0,0.65,0), size: SIMD3(3.8,1.3,0.8)); mesh.floor()
        let index = try mesh.index(), selection = try index.grow(from: 0)
        let region = try index.region(selection: selection.selection, front: SIMD3(0,0,1), partial: selection.touchesLimit, automaticOrientation: true)
        XCTAssertFalse(selection.touchesLimit)
        XCTAssertTrue(selection.selection.ids.allSatisfy { $0 < 12 })
        XCTAssertEqual(region.bounds.size.x, 3.8, accuracy: 0.0001)
        XCTAssertEqual(region.bounds.size.y, 1.3, accuracy: 0.0001)
        XCTAssertEqual(region.bounds.size.z, 0.8, accuracy: 0.0001)
    }

    func testNoisyFloorStopsGrowthWithoutSemanticLabels() throws {
        var mesh = Mesh()
        mesh.box(center: SIMD3(0,0.5,0), size: SIMD3(1.2,1,0.6))
        func p(_ x: Int, _ z: Int) -> SIMD3<Float> {
            SIMD3(Float(x) * 0.2, Float((x * 17 + z * 13) % 9) * 0.0007, Float(z) * 0.2)
        }
        for x in -20..<20 { for z in -20..<20 { mesh.quad(p(x,z), p(x+1,z), p(x+1,z+1), p(x,z+1)) } }
        let index = try mesh.index()
        let selection = try index.grow(from: 0).selection
        XCTAssertTrue(index.supportPlanes.contains { $0.kind == .floor })
        XCTAssertTrue(selection.ids.allSatisfy { $0 < 12 }, "No floor triangles may enlarge the object")
        let region = try index.region(selection: selection, front: SIMD3(0,0,1), partial: false)
        XCTAssertEqual(region.bounds.size.x, 1.2, accuracy: 0.001)
        XCTAssertEqual(region.bounds.size.y, 1, accuracy: 0.001)
    }

    func testChairPartsJoinAtTriangleInteriorsFromEitherTapDirection() throws {
        var mesh = Mesh()
        mesh.box(center: SIMD3(0,0.54,0), size: SIMD3(0.65,0.08,0.65))
        for x: Float in [-0.22, 0.22] { for z: Float in [-0.22, 0.22] {
            mesh.box(center: SIMD3(x,0.25,z), size: SIMD3(0.05,0.5,0.05))
        } }
        mesh.box(center: SIMD3(0,0.84,-0.3), size: SIMD3(0.65,0.54,0.05))
        let chairCount = mesh.faces.count
        mesh.floor()
        let index = try mesh.index()
        let fromSeat = try index.grow(from: 8).selection
        let fromLeg = try index.grow(from: 12).selection
        XCTAssertEqual(fromSeat.ids, fromLeg.ids, "Joining must be symmetric, independent of where the user taps")
        XCTAssertTrue(fromSeat.ids.contains(24) && fromSeat.ids.contains(36) && fromSeat.ids.contains(48) && fromSeat.ids.contains(60))
        XCTAssertTrue(fromSeat.ids.allSatisfy { $0 < chairCount })
        let region = try index.region(selection: fromSeat, front: SIMD3(0,0,1), partial: false, automaticOrientation: true)
        XCTAssertEqual(region.bounds.size.x, 0.65, accuracy: 0.001)
        XCTAssertEqual(region.bounds.size.y, 1.11, accuracy: 0.001)
        XCTAssertEqual(region.bounds.size.z, 0.65, accuracy: 0.001)
    }

    func testFloorDoesNotJoinSeparateNearbyObjects() throws {
        var mesh = Mesh()
        mesh.box(center: SIMD3(0,0.5,0), size: SIMD3(0.6,1,0.6))
        mesh.box(center: SIMD3(0.75,0.5,0), size: SIMD3(0.6,1,0.6))
        mesh.floor()
        let index = try mesh.index()
        XCTAssertTrue(try index.grow(from: 0).selection.ids.allSatisfy { $0 < 12 })
        XCTAssertTrue(try index.grow(from: 12).selection.ids.allSatisfy { (12..<24).contains($0) })
    }

    func testSmallReconstructionGapJoinsButActualGapSeparates() throws {
        for (gap, connected): (Float, Bool) in [(0.012, true), (0.09, false)] {
            var mesh = Mesh()
            mesh.box(center: SIMD3(0,0.5,0), size: SIMD3(1,1,0.6))
            mesh.box(center: SIMD3(0,1.1 + gap,0), size: SIMD3(1,0.2,0.6))
            mesh.floor()
            let index = try mesh.index()
            let result = try index.grow(from: 0)
            XCTAssertEqual(result.selection.ids.contains(12), connected)
            XCTAssertEqual(result.bridgedGap, connected)
        }
    }

    func testAutomaticOrientationUsesObjectFootprintWhenTapDirectionIsWrong() throws {
        for angle: Float in [0.23, 0.51, -0.43] {
            var mesh = Mesh()
            mesh.box(center: SIMD3(0,0.5,0), size: SIMD3(1.2,1,0.6), angle: angle); mesh.floor()
            let index = try mesh.index()
            let region = try index.region(selection: index.grow(from: 8).selection, front: SIMD3(0,0,1), partial: false, automaticOrientation: true)
            XCTAssertEqual(region.bounds.size.x, 1.2, accuracy: 0.0001)
            XCTAssertEqual(region.bounds.size.z, 0.6, accuracy: 0.0001)
            XCTAssertGreaterThan(simd_dot(region.bounds.front, SIMD3(sin(angle),0,cos(angle))), 0.9999)
        }
    }

    func testWallOpeningSupportsAutomaticProjectionWithoutInventingRearFace() throws {
        var mesh = Mesh()
        mesh.quad(SIMD3(-0.6,1,0.6), SIMD3(0.6,1,0.6), SIMD3(0.6,2,0.6), SIMD3(-0.6,2,0.6))
        mesh.wallWithOpening()
        let index = try mesh.index()
        let region = try index.region(selection: index.grow(from: 0).selection, front: SIMD3(0,0,1), partial: false, automaticOrientation: true)
        XCTAssertEqual(region.selection?.ids, [0,1])
        XCTAssertNil(region.dimensions.first { $0.axis == .depth }?.metres)
        XCTAssertEqual(try XCTUnwrap(region.wallProjection).metres, 0.6, accuracy: 0.001)
        XCTAssertEqual(region.displayBounds.size.z, 0.6, accuracy: 0.001)
        XCTAssertEqual(region.bounds.bottom, 1, accuracy: 0.001)
        XCTAssertEqual(region.bounds.size.y, 1, accuracy: 0.001)
        XCTAssertNil(region.dimensions.first { $0.axis == .depth }?.wallContactConfirmed)
        XCTAssertEqual(region, try JSONDecoder().decode(AutomaticMeasuredRegion.self, from: JSONEncoder().encode(region)))
        XCTAssertNoThrow(try region.validate())
    }

    func testWallCabinetWithScannedSidesKeepsObservedDepthAndRaisedBottom() throws {
        var mesh = Mesh()
        mesh.box(center: SIMD3(0,1.5,0.3), size: SIMD3(1.2,1,0.6)); mesh.wallWithOpening()
        let index = try mesh.index()
        let region = try index.region(selection: index.grow(from: 0).selection, front: SIMD3(0,0,1), partial: false, automaticOrientation: true)
        XCTAssertTrue(region.selection!.ids.allSatisfy { $0 < 12 })
        XCTAssertEqual(region.bounds.bottom, 1, accuracy: 0.001)
        XCTAssertEqual(region.dimensions.first { $0.axis == .depth }?.evidence, .observedSpan)
        XCTAssertEqual(region.bounds.size.z, 0.6, accuracy: 0.001)
        XCTAssertFalse(region.usesWallProjectionForDisplay)
    }

    private func cloudBox(center: SIMD3<Float>, size: SIMD3<Float>) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        for fixed in 0..<3 {
            let u = (fixed + 1) % 3, v = (fixed + 2) % 3
            let nu = Int(ceil(size[u] / 0.04)), nv = Int(ceil(size[v] / 0.04))
            for side: Float in [-0.5,0.5] { for x in 0...nu { for y in 0...nv {
                var p = center
                p[fixed] += side * size[fixed]; p[u] += (Float(x)/Float(nu) - 0.5) * size[u]
                p[v] += (Float(y)/Float(nv) - 0.5) * size[v]; result.append(p)
            } } }
        }
        return result
    }

    func testPointCloudDetectsNoisyFloorAndSeparatesNearbyObject() throws {
        let object = cloudBox(center: SIMD3(0,0.5,0), size: SIMD3(1.2,1,0.6))
        let second = cloudBox(center: SIMD3(1.05,0.4,0), size: SIMD3(0.6,0.8,0.6))
        var points = object + second
        for x in -50...50 { for z in -50...50 {
            points.append(SIMD3(Float(x)*0.05, Float((x*13+z*7)%7)*0.0005, Float(z)*0.05))
        } }
        let index = try ObjectSelectionIndex(points: points, triangles: [])
        let seed = try XCTUnwrap(index.nearest(to: SIMD3(0,0.5,0.3)))
        let result = try index.grow(from: seed)
        XCTAssertTrue(index.supportPlanes.contains { $0.kind == .floor })
        XCTAssertTrue(result.selection.ids.allSatisfy { $0 < object.count })
        let region = try index.region(selection: result.selection, front: SIMD3(0,0,1), partial: false, automaticOrientation: true)
        XCTAssertEqual(region.bounds.size.x, 1.2, accuracy: 0.002)
        XCTAssertEqual(region.bounds.size.y, 1, accuracy: 0.045)
        XCTAssertEqual(region.bounds.size.z, 0.6, accuracy: 0.002)
        XCTAssertEqual(region.dimensions.first { $0.axis == .width }?.evidence, .partial)
    }

    func testRotatedNoisyPointCloudWallIsDetectedAroundCabinet() throws {
        let angle: Float = 0.41
        let rotation = simd_quatf(angle: angle, axis: SIMD3(0,1,0))
        func world(_ p: SIMD3<Float>) -> SIMD3<Float> { rotation.act(p) + SIMD3(2,0,-1) }
        var points: [SIMD3<Float>] = []
        for x in -15...15 { for y in 25...50 { points.append(world(SIMD3(Float(x)*0.04, Float(y)*0.04, 0.6))) } }
        let objectCount = points.count
        for x in -50...50 { for y in 0...75 {
            let px = Float(x)*0.04, py = Float(y)*0.04
            if abs(px) < 0.8 && py > 0.7 && py < 2.3 { continue }
            points.append(world(SIMD3(px, py, Float((x*11+y*3)%9)*0.0006)))
        } }
        let index = try ObjectSelectionIndex(points: points, triangles: [])
        let seed = try XCTUnwrap(index.nearest(to: world(SIMD3(0,1.5,0.6))))
        let region = try index.region(selection: index.grow(from: seed).selection, front: rotation.act(SIMD3(0,0,1)), partial: false, automaticOrientation: true)
        XCTAssertTrue(region.selection!.ids.allSatisfy { $0 < objectCount })
        XCTAssertEqual(try XCTUnwrap(region.wallProjection).metres, 0.6, accuracy: 0.02)
        XCTAssertEqual(region.bounds.size.x, 1.2, accuracy: 0.002)
        XCTAssertEqual(region.bounds.size.y, 1, accuracy: 0.002)
    }

    func testDenseDuplicateCloudDoesNotLoseSourcePoints() throws {
        let points = Array(repeating: SIMD3<Float>(0,1,0), count: 5_000)
        let index = try ObjectSelectionIndex(points: points, triangles: [])
        XCTAssertEqual(try index.grow(from: 0).selection.ids.count, points.count)
    }

    func testRoundFootprintRemainsFiniteAndEnclosesAllPoints() throws {
        let points = (0..<2048).map { i -> SIMD3<Float> in
            let angle = Float(i) * 2 * .pi / 2048
            return SIMD3(cos(angle), Float(i % 2), sin(angle))
        }
        let front = ObjectFootprint.front(points: points, preferred: SIMD3(0,0,1))
        let bounds = try UprightMeasurementBounds.fit(points: points, front: front)
        XCTAssertEqual(bounds.size.x, 2, accuracy: 0.001)
        XCTAssertEqual(bounds.size.z, 2, accuracy: 0.001)
    }

    func testMalformedWallProjectionIsRejectedAndLegacyRegionStillLoads() throws {
        var mesh = Mesh(); mesh.box(center: SIMD3(0,0.5,0), size: SIMD3(1.2,1,0.6))
        let index = try mesh.index()
        var region = try index.region(selection: index.grow(from: 0).selection, front: SIMD3(0,0,1), partial: false)
        XCTAssertNil(try JSONDecoder().decode(AutomaticMeasuredRegion.self, from: JSONEncoder().encode(region)).wallProjection)
        region.wallProjection = AutomaticMeasuredRegion.WallProjection(metres: .nan, wallPoint: .zero)
        XCTAssertThrowsError(try region.validate())
        region.wallProjection = AutomaticMeasuredRegion.WallProjection(metres: 1, wallPoint: SIMD3(0,0.5,-0.7))
        XCTAssertNoThrow(try region.validate())
        region.wallProjection = AutomaticMeasuredRegion.WallProjection(metres: 1, wallPoint: .zero)
        XCTAssertThrowsError(try region.validate())
    }
}
