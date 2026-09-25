import Foundation
import XCTest
@testable import StorageCore

final class CoordinateExportTests: XCTestCase {
    private var directory: URL!
    // 90° about Z, scale 2, translation (5,7,11), column-major.
    private let transform: [Double] = [0, 2, 0, 0, -2, 0, 0, 0, 0, 0, 2, 0, 5, 7, 11, 1]
    private static let fixtureBase64 = "UEsDBBQAAAAAAAAAIQAeRu2EGQIAABkCAAAMABYAZml4dHVyZS51c2RhhhkSAAAAAAAAAAAAAAAAAAAAAAAAACN1c2RhIDEuMAooCiAgICBkZWZhdWx0UHJpbSA9ICJGaXh0dXJlIgogICAgdXBBeGlzID0gIlkiCiAgICBtZXRlcnNQZXJVbml0ID0gMQopCmRlZiBYZm9ybSAiRml4dHVyZSIgewogICAgZG91YmxlMyB4Zm9ybU9wOnRyYW5zbGF0ZSA9ICgwLjI1LCAtMC41LCAxKQogICAgdW5pZm9ybSB0b2tlbltdIHhmb3JtT3BPcmRlciA9IFsieGZvcm1PcDp0cmFuc2xhdGUiXQogICAgZGVmIE1lc2ggIlRldHJhaGVkcm9uIiB7CiAgICAgICAgaW50W10gZmFjZVZlcnRleENvdW50cyA9IFszLCAzLCAzLCAzXQogICAgICAgIGludFtdIGZhY2VWZXJ0ZXhJbmRpY2VzID0gWzAsIDIsIDEsIDAsIDEsIDMsIDAsIDMsIDIsIDEsIDIsIDNdCiAgICAgICAgcG9pbnQzZltdIHBvaW50cyA9IFsoMCwgMCwgMCksICgxLCAwLCAwKSwgKDAsIDIsIDApLCAoMCwgMCwgMyldCiAgICAgICAgY29sb3IzZltdIHByaW12YXJzOmRpc3BsYXlDb2xvciA9IFsoMSwgMCwgMCldCiAgICAgICAgdW5pZm9ybSB0b2tlbiBzdWJkaXZpc2lvblNjaGVtZSA9ICJub25lIgogICAgfQp9ClBLAQIUABQAAAAAAAAAIQAeRu2EGQIAABkCAAAMABYAAAAAAAAAAACAAQAAAABmaXh0dXJlLnVzZGGGGRIAAAAAAAAAAAAAAAAAAAAAAAAAUEsFBgAAAAABAAEAUAAAAFkCAAAAAA=="

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoordinateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func source() throws -> URL {
        let url = directory.appendingPathComponent("source.usdz")
        try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64)).write(to: url)
        return url
    }
    private func export() throws -> URL {
        let output = directory.appendingPathComponent("aligned.usdz")
        try AlignedUSDZ.write(source: source(), to: output, transform: transform)
        return output
    }
    func testIdentityDoesNotMovePoint() throws {
        XCTAssertEqual(try CoordinateMath.point(SIMD3(1, -2, 3), by: CoordinateMath.identity), SIMD3(1, -2, 3))
    }
    func testScaleRotationTranslationOrder() throws {
        XCTAssertEqual(try CoordinateMath.point(SIMD3(1, 2, 3), by: transform), SIMD3(1, 9, 17))
    }
    func testZUpPreservesRightHandedAxes() {
        XCTAssertEqual(CoordinateMath.zUp(SIMD3(1, 2, 3)), SIMD3(1, -3, 2))
    }
    func testSTLMillimetresAreScaledExactlyOnce() {
        XCTAssertEqual(CoordinateMath.zUp(SIMD3(1, 2, 3), millimetres: true), SIMD3(1000, -3000, 2000))
    }
    func testRejectsTruncatedTransform() { XCTAssertThrowsError(try CoordinateMath.validated([1, 2])) }
    func testRejectsNaNAndInfinity() {
        for value in [Double.nan, Double.infinity] {
            var m = transform; m[12] = value
            XCTAssertThrowsError(try CoordinateMath.validated(m))
        }
    }
    func testRejectsSingularTransform() {
        var m = transform; m[10] = 0
        XCTAssertThrowsError(try CoordinateMath.validated(m))
    }
    func testRejectsPerspectiveTransform() {
        var m = transform; m[3] = 1
        XCTAssertThrowsError(try CoordinateMath.validated(m))
    }
    func testUSDTranslationIsInLastRow() throws {
        XCTAssertTrue(try CoordinateMath.usdMatrix(transform).hasSuffix("(5.0, 7.0, 11.0, 1.0))"))
    }
    func testProvenanceRoundTrip() throws {
        let original = CoordinateProvenance(sourceKind: "lidar", scaleStatus: .lidarMetric,
            alignmentMethod: "local frame", captureToLocal: transform, localDatum: "not a surveyed elevation")
        XCTAssertEqual(try JSONDecoder().decode(CoordinateProvenance.self, from: JSONEncoder().encode(original)), original)
    }
    func testMissingOptionalProvenanceDecodesOlderRecord() throws {
        struct OldCompatible: Codable { let name: String; let provenance: CoordinateProvenance? }
        XCTAssertNil(try JSONDecoder().decode(OldCompatible.self, from: Data(#"{"name":"old"}"#.utf8)).provenance)
    }
    func testCancellationAndReset() throws {
        let flag = ExportCancellation()
        try flag.check(); flag.cancel()
        XCTAssertThrowsError(try flag.check())
        flag.reset(); try flag.check()
    }
    func testCancelledExportLeavesNoOutputAndPreservesSource() throws {
        let input = try source(), original = try Data(contentsOf: input)
        let output = directory.appendingPathComponent("cancelled.usdz")
        XCTAssertThrowsError(try AlignedUSDZ.write(source: input, to: output, transform: transform, cancelled: { true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: input), original)
    }
    func testInvalidTransformNeverCreatesOutput() throws {
        let output = directory.appendingPathComponent("bad.usdz")
        XCTAssertThrowsError(try AlignedUSDZ.write(source: source(), to: output, transform: [0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testExistingDestinationIsNotOverwritten() throws {
        let output = directory.appendingPathComponent("existing.usdz"), original = Data("keep".utf8)
        try original.write(to: output)
        XCTAssertThrowsError(try AlignedUSDZ.write(source: source(), to: output, transform: transform))
        XCTAssertEqual(try Data(contentsOf: output), original)
    }
    func testInvalidArchiveIsRejected() throws {
        let input = directory.appendingPathComponent("invalid.usdz")
        try Data("not a zip".utf8).write(to: input)
        XCTAssertThrowsError(try AlignedUSDZ.write(source: input, to: directory.appendingPathComponent("out.usdz"), transform: transform))
    }
    func testArchiveAlignmentAndOriginalPayload() throws {
        let output = try export(), bytes = try Data(contentsOf: output)
        func uint16(_ start: Int) -> Int { Int(bytes[start]) | Int(bytes[start+1]) << 8 }
        func uint32(_ start: Int) -> Int { uint16(start) | uint16(start+2) << 16 }
        var offset = 0, files: [String: Data] = [:]
        while uint32(offset) == 0x04034b50 {
            XCTAssertEqual(uint16(offset + 8), 0)
            let nameLength = uint16(offset + 26), extraLength = uint16(offset + 28), size = uint32(offset + 18)
            let name = String(decoding: bytes[(offset + 30)..<(offset + 30 + nameLength)], as: UTF8.self)
            let start = offset + 30 + nameLength + extraLength
            XCTAssertEqual(start % 64, 0)
            files[name] = bytes.subdata(in: start..<(start + size))
            offset = start + size
        }
        XCTAssertEqual(Set(files.keys), Set(["aligned.usda", "source.usdz"]))
        XCTAssertEqual(files["source.usdz"], Data(base64Encoded: Self.fixtureBase64))
        XCTAssertEqual(uint32(offset), 0x02014b50)
    }
    #if canImport(SceneKit)
    func testSceneKitLoadsCorrectedGeometry() throws {
        let input = try source(), output = directory.appendingPathComponent("checked.usdz")
        try AlignedUSDZ.write(source: input, to: output, transform: transform)
        try SceneCoordinateValidation.verify(source: input, exported: output, transform: transform)
        let bounds = try SceneCoordinateValidation.bounds(url: output)
        XCTAssertEqual(bounds.minimum.x, 2, accuracy: 0.0001)
        XCTAssertEqual(bounds.minimum.y, 7.5, accuracy: 0.0001)
        XCTAssertEqual(bounds.minimum.z, 13, accuracy: 0.0001)
        XCTAssertEqual(bounds.maximum.x, 6, accuracy: 0.0001)
        XCTAssertEqual(bounds.maximum.y, 9.5, accuracy: 0.0001)
        XCTAssertEqual(bounds.maximum.z, 19, accuracy: 0.0001)
    }
    func testUncorrectedGeometryFailsVerification() throws {
        let input = try source()
        XCTAssertThrowsError(try SceneCoordinateValidation.verify(source: input, exported: input, transform: transform))
    }
    #endif
    func testEmitIndependentReaderFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["EXPORT_FIXTURE_DIR"] else { return }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: export(), to: folder.appendingPathComponent("aligned.usdz"))
    }
    func testOBJNormalsRotateWithoutTranslationOrScale() throws {
        XCTAssertEqual(try ExportText.zUpLine("vn 0 1 0"), "vn 0.0 -0.0 1.0")
    }
    func testOBJVertexColourIsPreserved() throws {
        XCTAssertEqual(try ExportText.zUpLine("v 1 2 3 0.1 0.2 0.3"), "v 1.0 -3.0 2.0 0.1 0.2 0.3")
    }
    func testOBJTextureCoordinatesAreUnchanged() throws {
        XCTAssertEqual(try ExportText.zUpLine("vt 0.25 0.75"), "vt 0.25 0.75")
    }
    func testOBJInvalidCoordinatesAreRejected() {
        XCTAssertThrowsError(try ExportText.zUpLine("v nan 1 2"))
        XCTAssertThrowsError(try ExportText.zUpLine("vn 1 2"))
    }
    func testLineReaderHandlesCRLFUnicodeAndNoFinalNewline() throws {
        let file = directory.appendingPathComponent("lines.obj")
        try Data("# blåbær\r\nv 1 2 3\nlast".utf8).write(to: file)
        var result: [String] = []
        try ExportText.lines(file) { result.append($0) }
        XCTAssertEqual(result, ["# blåbær", "v 1 2 3", "last"])
    }
}
