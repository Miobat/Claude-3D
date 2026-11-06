import XCTest
import simd
@testable import StorageCore

final class GeometryBufferTests: XCTestCase {
    func testValidInterleavedLayoutAndEmptyBuffers() {
        XCTAssertTrue(GeometryBufferReader.containsVectors(dataCount: 41, count: 2, offset: 1, stride: 28))
        XCTAssertTrue(GeometryBufferReader.containsVectors(dataCount: 0, count: 0, offset: 0, stride: 12))
        XCTAssertFalse(GeometryBufferReader.containsVectors(dataCount: 40, count: 2, offset: 1, stride: 28))
    }

    func testNegativeAndOverflowingVertexDescriptorsFailClosed() {
        for count in [-1, Int.max] {
            XCTAssertFalse(GeometryBufferReader.containsVectors(dataCount: 12, count: count, offset: 0, stride: 12))
        }
        for offset in [-1, Int.max] {
            XCTAssertFalse(GeometryBufferReader.containsVectors(dataCount: 12, count: 1, offset: offset, stride: 12))
        }
        for stride in [-1, 0, 11, Int.max] {
            XCTAssertFalse(GeometryBufferReader.containsVectors(dataCount: 24, count: 2, offset: 0, stride: stride))
        }
    }

    func testIndexDescriptorsRejectTruncationUnsupportedWidthsAndOverflow() {
        for width in [1, 2, 4] {
            XCTAssertTrue(GeometryBufferReader.containsIndices(dataCount: width * 6, primitiveCount: 2,
                indicesPerPrimitive: 3, bytesPerIndex: width))
            XCTAssertFalse(GeometryBufferReader.containsIndices(dataCount: width * 6 - 1, primitiveCount: 2,
                indicesPerPrimitive: 3, bytesPerIndex: width))
        }
        for width in [-1, 0, 3, 8, Int.max] {
            XCTAssertFalse(GeometryBufferReader.containsIndices(dataCount: 12, primitiveCount: 1,
                indicesPerPrimitive: 3, bytesPerIndex: width))
        }
        XCTAssertFalse(GeometryBufferReader.containsIndices(dataCount: 12, primitiveCount: Int.max,
            indicesPerPrimitive: 3, bytesPerIndex: 4))
        XCTAssertFalse(GeometryBufferReader.containsIndices(dataCount: 12, primitiveCount: -1,
            indicesPerPrimitive: 3, bytesPerIndex: 4))
        XCTAssertFalse(GeometryBufferReader.containsIndices(dataCount: 12, primitiveCount: 1,
            indicesPerPrimitive: Int.max, bytesPerIndex: 4))
    }

    func testUnalignedPositionsPreserveTransformAndOriginalCoordinates() {
        var data = Data([255])
        append(SIMD3<Float>(1, 2, 3), to: &data)
        data.append(contentsOf: [0, 0, 0, 0])
        append(SIMD3<Float>(4, 5, 6), to: &data)
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(10, -2, 1, 1)
        XCTAssertEqual(GeometryBufferReader.positions(data: data, count: 2, offset: 1, stride: 16, transform: transform),
            [SIMD3(11, 0, 4), SIMD3(14, 3, 7)])
    }

    func testTruncatedAndNonfinitePositionsNeverBecomePickable() {
        XCTAssertNil(GeometryBufferReader.positions(data: Data(repeating: 0, count: 11), count: 1,
            offset: 0, stride: 12, transform: matrix_identity_float4x4))
        for value in [Float.nan, Float.infinity, -Float.infinity] {
            var data = Data(); append(SIMD3<Float>(0, value, 0), to: &data)
            XCTAssertNil(GeometryBufferReader.positions(data: data, count: 1, offset: 0, stride: 12,
                transform: matrix_identity_float4x4))
        }
    }

    func testNonfiniteTransformedPositionsAreRejected() {
        var data = Data(); append(SIMD3<Float>(1, 2, 3), to: &data)
        var transform = matrix_identity_float4x4; transform.columns.3.x = .infinity
        XCTAssertNil(GeometryBufferReader.positions(data: data, count: 1, offset: 0, stride: 12, transform: transform))
    }

    func testViewerRejectsExtremeNonfiniteAndReversedBounds() {
        for value in [Float.nan, Float.infinity, Float.greatestFiniteMagnitude, 1_000_001] {
            XCTAssertNil(ViewerGeometryLimits.bounds(low: .zero, high: SIMD3(value, 1, 1)))
            XCTAssertNil(ViewerGeometryLimits.grid(low: .zero, high: SIMD3(value, 1, 1)))
        }
        XCTAssertNil(ViewerGeometryLimits.bounds(low: SIMD3(2, 0, 0), high: SIMD3(1, 1, 1)))
        XCTAssertNil(ViewerGeometryLimits.bounds(low: SIMD3(-1_000_001, 0, 0), high: .zero))
    }

    func testViewerGridPreservesOrdinaryRoomAndSiteSpacing() throws {
        let examples: [(Float, Float)] = [(10, 0.5), (20, 1), (100, 5)]
        for (extent, spacing) in examples {
            let grid = try XCTUnwrap(ViewerGeometryLimits.grid(low: .zero, high: SIMD3(extent, 3, extent)))
            XCTAssertEqual(grid.spacing, spacing)
            XCTAssertEqual(grid.half, extent * 0.75)
            XCTAssertEqual(grid.halfLines, 15)
        }
    }

    func testViewerGridIsBoundedEvenAtLargestSupportedCoordinates() throws {
        let low = SIMD3<Float>(repeating: -ViewerGeometryLimits.maximumAbsoluteCoordinate)
        let high = -low
        let bounds = try XCTUnwrap(ViewerGeometryLimits.bounds(low: low, high: high))
        let grid = try XCTUnwrap(ViewerGeometryLimits.grid(low: low, high: high))
        XCTAssertEqual(bounds.center, .zero)
        XCTAssertTrue(grid.half.isFinite && grid.spacing.isFinite)
        XCTAssertLessThanOrEqual(grid.halfLines, ViewerGeometryLimits.maximumGridHalfLines)
        XCTAssertLessThanOrEqual((2 * grid.halfLines + 1) * 2, 258)
        XCTAssertGreaterThanOrEqual(grid.half, max(bounds.extent.x, bounds.extent.z) * 0.75)
    }

    func testSinglePointBoundsRemainViewableWithoutDivisionByZero() throws {
        let grid = try XCTUnwrap(ViewerGeometryLimits.grid(low: .zero, high: .zero))
        XCTAssertEqual(grid.spacing, 0.5)
        XCTAssertEqual(grid.half, 2)
        XCTAssertEqual(grid.halfLines, 4)
    }

    private func append(_ point: SIMD3<Float>, to data: inout Data) {
        for component in [point.x, point.y, point.z] {
            var value = component
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
    }
}
