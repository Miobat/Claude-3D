import Foundation
import XCTest
@testable import StorageCore

final class TerrainCaptureTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TerrainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testSpacingPresetsAreCentimetresNotMillimetres() {
        XCTAssertEqual(TerrainSpacing.allCases.map(\.rawValue), [50, 100, 200])
        XCTAssertEqual(TerrainSpacing.allCases.map(\.metres), [0.05, 0.1, 0.2])
        XCTAssertEqual(TerrainSpacing.allCases.map(\.label), ["5 cm", "10 cm", "20 cm"])
    }
    func testInvalidSpacingDefaultsSafely() {
        for value in [Float.nan, .infinity, -100, 0, 5, 20, 999] {
            XCTAssertEqual(TerrainSpacing.validated(value), .standard)
        }
        XCTAssertEqual(TerrainSpacing.validated(50), .detailed)
        XCTAssertEqual(TerrainSpacing.validated(200), .overview)
    }
    func testNoMinimumBudgetOverridesLowMemory() {
        for memory in [Double.nan, .infinity, -10, 0, 599, 600] {
            let limits = TerrainCapture.limits(spacing: .standard, availableMB: memory)
            XCTAssertEqual(limits.points, 0)
            XCTAssertEqual(limits.coverageCells, 0)
        }
    }
    func testCoverageAndPointsShareBoundedMemory() {
        for memory in [Double(601), 800, 1200, 3000, 100_000] {
            for spacing in TerrainSpacing.allCases {
                let limits = TerrainCapture.limits(spacing: spacing, availableMB: memory)
                XCTAssertEqual(limits.voxelSize, spacing.metres)
                XCTAssertEqual(limits.points, limits.coverageCells)
                XCTAssertLessThanOrEqual(limits.points, 2_000_000)
                XCTAssertLessThanOrEqual(Double(limits.points + limits.coverageCells) * CaptureBudget.bytesPerEntry,
                                         (memory - 600) * 1_048_576 * 0.35)
            }
        }
    }
    func testNegativeVoxelKeysUseFloorNotTruncation() {
        XCTAssertEqual(TerrainCapture.key(SIMD3(-0.01, 0, 0.19), spacing: 0.1), SIMD3(-1, 0, 1))
        XCTAssertEqual(TerrainCapture.key(SIMD3(-0.11, 0.11, 0), spacing: 0.1), SIMD3(-2, 1, 0))
    }
    func testInvalidVoxelInputsCannotOverflowIntegerKeys() {
        for point in [SIMD3<Float>(.nan, 0, 0), SIMD3(.infinity, 1, 2), SIMD3(1e20, 1, 2)] {
            XCTAssertNil(TerrainCapture.key(point, spacing: 0.05))
        }
        for spacing in [Float(0), -1, .nan, .infinity] {
            XCTAssertNil(TerrainCapture.key(.zero, spacing: spacing))
        }
    }
    func testCoarserSamplingRetainsFewerMeasuredPointsOnSlope() throws {
        var source: [SIMD3<Float>] = []
        for z in 0..<200 { for x in 0..<200 {
            let px = Float(x) * 0.01 + 0.003, pz = Float(z) * 0.01 + 0.003
            source.append(SIMD3(px, 0.2 * px, pz))
        } }
        var counts: [Int] = []
        for spacing in TerrainSpacing.allCases {
            var retained: [SIMD3<Int32>: SIMD3<Float>] = [:]
            for p in source {
                let key = try XCTUnwrap(TerrainCapture.key(p, spacing: spacing.metres))
                if retained[key] == nil { retained[key] = p }
            }
            counts.append(retained.count)
            XCTAssertTrue(retained.values.allSatisfy { abs($0.y - 0.2 * $0.x) < 1e-6 })
            XCTAssertTrue(Set(retained.values).isSubset(of: Set(source)))
        }
        XCTAssertGreaterThan(counts[0], counts[1] * 3)
        XCTAssertGreaterThan(counts[1], counts[2] * 3)
    }
    func testRecentringPreservesSlopeScaleAndGravity() throws {
        let m = try TerrainCapture.localFrame(minimum: SIMD3(-4, -2, -6), maximum: SIMD3(8, 1, 10))
        XCTAssertEqual(Array(m.prefix(12)), Array(CoordinateMath.identity.prefix(12)))
        let a = SIMD3<Double>(-4, -2, -6), b = SIMD3<Double>(8, 1, 10)
        let pa = try CoordinateMath.point(a, by: m), pb = try CoordinateMath.point(b, by: m)
        XCTAssertEqual(pa, SIMD3(-6, 0, -8))
        XCTAssertEqual(pb - pa, b - a)
        XCTAssertEqual((pb.y - pa.y) / (pb.x - pa.x), 0.25)
    }
    func testInvalidBoundsAreRejected() {
        XCTAssertThrowsError(try TerrainCapture.localFrame(minimum: SIMD3(1, 0, 0), maximum: .zero))
        XCTAssertThrowsError(try TerrainCapture.localFrame(minimum: SIMD3(.nan, 0, 0), maximum: .zero))
    }
    func testTerrainMetadataRoundTripsAndRejectsNewerVersions() throws {
        var meta = TerrainCaptureMetadata(spacing: .detailed, captureRangeMetres: 3)
        XCTAssertEqual(try JSONDecoder().decode(TerrainCaptureMetadata.self, from: JSONEncoder().encode(meta)), meta)
        meta.version = 2
        XCTAssertThrowsError(try meta.validate())
        meta.version = 1
        for range in [Float.nan, 0.29, 5.01] { meta.captureRangeMetres = range; XCTAssertThrowsError(try meta.validate()) }
    }
    func testManifestIsExplicitAboutUnknownCoverageAndAlreadyBakedCoordinates() throws {
        let value = try TerrainExportManifest(metadata: .init(spacing: .standard, captureRangeMetres: 5),
            modelFile: "model.ply", modelSHA256: String(repeating: "a", count: 64), pointCount: 10)
        let restored = try JSONDecoder().decode(TerrainExportManifest.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored.schemaVersion, 1)
        XCTAssertEqual(restored.units, "metres")
        XCTAssertEqual(restored.upAxis, "Y")
        XCTAssertTrue(restored.transformsAlreadyApplied)
        XCTAssertTrue(restored.registrationRequired)
        XCTAssertFalse(restored.interpolated)
        XCTAssertEqual(restored.groundClassification, "unclassified")
        XCTAssertEqual(restored.coverage, "retainedSamplesOnly")
        XCTAssertEqual(restored.spacingMetres, 0.1)
    }
    func testManifestRejectsInvalidModelIdentity() {
        let metadata = TerrainCaptureMetadata(spacing: .detailed, captureRangeMetres: 1)
        for path in ["../model.ply", "C:\\model.ply", "model.obj"] {
            XCTAssertThrowsError(try TerrainExportManifest(metadata: metadata, modelFile: path,
                modelSHA256: String(repeating: "a", count: 64), pointCount: 1))
        }
        XCTAssertThrowsError(try TerrainExportManifest(metadata: metadata, modelFile: "model.ply", modelSHA256: "bad", pointCount: 1))
        XCTAssertThrowsError(try TerrainExportManifest(metadata: metadata, modelFile: "model.ply",
            modelSHA256: String(repeating: "a", count: 64), pointCount: 0))
    }
    private func body(_ url: URL) throws -> (String, Data) {
        let data = try Data(contentsOf: url)
        let end = try XCTUnwrap(data.range(of: Data("end_header\n".utf8)))
        return (String(decoding: data[..<end.upperBound], as: UTF8.self), Data(data[end.upperBound...]))
    }
    private func float(_ data: Data, _ offset: Int) -> Float {
        var b: UInt32 = 0
        for i in 0..<4 { b |= UInt32(data[offset + i]) << (i * 8) }
        return Float(bitPattern: b)
    }
    func testStreamedPLYUsesExactXYZAndRGBWithoutFaces() throws {
        let url = directory.appendingPathComponent("model.ply")
        let points: [SIMD3<Float>] = [SIMD3(-1.25, 0.125, 4), SIMD3(10, 2, -3)]
        try PointCloudPLYWriter.write(positions: points, colors: [SIMD4(1, 0.5, 0, 1), SIMD4(-1, 2, 1, 1)], to: url)
        let (header, bytes) = try body(url)
        XCTAssertTrue(header.contains("binary_little_endian"))
        XCTAssertFalse(header.contains("element face"))
        XCTAssertEqual(bytes.count, 30)
        for i in points.indices { for axis in 0..<3 {
            XCTAssertEqual(float(bytes, i * 15 + axis * 4), points[i][axis])
        } }
        XCTAssertEqual(Array(bytes[12..<15]), [255, 127, 0])
        XCTAssertEqual(Array(bytes[27..<30]), [0, 255, 255])
    }
    func testStreamedPLYCrossesManyBufferBoundariesWithoutLosingPoints() throws {
        let points = (0..<100_000).map { SIMD3<Float>(Float($0) / 10, Float($0 % 7), -Float($0)) }
        let url = directory.appendingPathComponent("large.ply")
        try PointCloudPLYWriter.write(positions: points, colors: [], to: url)
        let (header, bytes) = try body(url)
        XCTAssertFalse(header.contains("property uchar"))
        XCTAssertEqual(bytes.count, points.count * 12)
        for i in [0, 5459, 5460, 5461, 99999] { for axis in 0..<3 {
            XCTAssertEqual(float(bytes, i * 12 + axis * 4), points[i][axis])
        } }
    }
    func testInvalidPLYLeavesNoPartialFiles() throws {
        let url = directory.appendingPathComponent("bad.ply")
        XCTAssertThrowsError(try PointCloudPLYWriter.write(positions: [], colors: [], to: url))
        XCTAssertThrowsError(try PointCloudPLYWriter.write(positions: [.zero, .zero], colors: [SIMD4(1, 1, 1, 1)], to: url))
        XCTAssertThrowsError(try PointCloudPLYWriter.write(positions: [SIMD3(.nan, 0, 0)], colors: [], to: url))
        XCTAssertThrowsError(try PointCloudPLYWriter.write(positions: [.zero], colors: [SIMD4(.infinity, 0, 0, 1)], to: url))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
    func testPLYRefusesAccidentalOverwrite() throws {
        let url = directory.appendingPathComponent("keep.ply"), original = Data("keep me".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(try PointCloudPLYWriter.write(positions: [.zero], colors: [], to: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["keep.ply"])
    }
    func testSplatRetryReplacesOnlyAfterSuccessfulStream() throws {
        let url = directory.appendingPathComponent("points3D.ply"), original = Data("original".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(try PointCloudPLYWriter.write(positions: [SIMD3(.nan, 0, 0)], colors: [], to: url, replacingExisting: true))
        XCTAssertEqual(try Data(contentsOf: url), original)
        try PointCloudPLYWriter.write(positions: [SIMD3(2, 3, 4)], colors: [], to: url, replacingExisting: true)
        let (_, bytes) = try body(url)
        XCTAssertEqual(float(bytes, 0), 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["points3D.ply"])
    }
}
