import Foundation
import XCTest
@testable import StorageCore

final class ExportSafetyTests: XCTestCase {
    private var directory: URL!
    private let triangle: [SIMD3<Float>] = [.zero, SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExportSafety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func textFile(_ text: String, name: String = "input.obj") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func entries() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() }

    func testMeshValidationAcceptsAbsentOptionalAttributes() throws {
        try MeshExportValidation.validate(vertices: triangle, normals: [], colors: [], faces: [[0, 1, 2]])
    }
    func testMeshValidationRejectsInvalidFaceCountsAndIndices() {
        let invalidFaces: [[[UInt32]]] = [[[0, 1]], [[0, 1, 2, 0]], [[0, 1, 3]], [[0, 1, .max]]]
        for faces in invalidFaces {
            XCTAssertThrowsError(try MeshExportValidation.validate(vertices: triangle, normals: [], colors: [], faces: faces))
        }
    }
    func testMeshValidationRejectsTruncatedParallelArraysAndUVs() {
        XCTAssertThrowsError(try MeshExportValidation.validate(vertices: triangle, normals: [.zero], colors: [], faces: [[0, 1, 2]]))
        XCTAssertThrowsError(try MeshExportValidation.validate(vertices: triangle, normals: [], colors: [.zero], faces: [[0, 1, 2]]))
        XCTAssertThrowsError(try MeshExportValidation.validate(vertices: triangle, normals: [], colors: [], faces: [[0, 1, 2]], cornerUVs: [.zero]))
    }
    func testMeshValidationRejectsNonfiniteComponentsIncludingAlpha() {
        var invalid = triangle; invalid[0].x = .nan
        XCTAssertThrowsError(try MeshExportValidation.validate(vertices: invalid, normals: [], colors: [], faces: []))
        XCTAssertThrowsError(try MeshExportValidation.validate(vertices: triangle, normals: Array(repeating: SIMD3(.infinity, 0, 0), count: 3), colors: [], faces: []))
        XCTAssertThrowsError(try MeshExportValidation.validate(vertices: triangle, normals: [], colors: Array(repeating: SIMD4(1, 1, 1, .nan), count: 3), faces: []))
        XCTAssertThrowsError(try MeshExportValidation.validate(vertices: triangle, normals: [], colors: [], faces: [[0, 1, 2]], cornerUVs: Array(repeating: SIMD2(.nan, 0), count: 3)))
    }
    func testStagedAssetSetCommitsTogetherAndCleansStaging() throws {
        try ExportAssetTransaction.write(names: ["model.mtl", "model.obj"], directory: directory) { stage in
            try Data("material".utf8).write(to: stage.appendingPathComponent("model.mtl"))
            try Data("model".utf8).write(to: stage.appendingPathComponent("model.obj"))
            XCTAssertEqual(try entries().filter { !$0.hasPrefix(".mesh-") }, [])
        }
        XCTAssertEqual(try entries(), ["model.mtl", "model.obj"])
    }
    func testStagedWriteFailureLeavesNoPartialAssets() throws {
        XCTAssertThrowsError(try ExportAssetTransaction.write(names: ["model.obj", "model.mtl"], directory: directory) { stage in
            try Data("partial".utf8).write(to: stage.appendingPathComponent("model.obj"))
            throw CocoaError(.fileWriteOutOfSpace)
        })
        XCTAssertEqual(try entries(), [])
    }
    func testStagedMissingCompanionCannotPublishModel() throws {
        XCTAssertThrowsError(try ExportAssetTransaction.write(names: ["model.obj", "model.mtl"], directory: directory) { stage in
            try Data("model".utf8).write(to: stage.appendingPathComponent("model.obj"))
        })
        XCTAssertEqual(try entries(), [])
    }
    func testStagedCollisionNeverRemovesExistingData() throws {
        let original = try textFile("existing", name: "model.mtl")
        var ran = false
        XCTAssertThrowsError(try ExportAssetTransaction.write(names: ["model.obj", "model.mtl"], directory: directory) { _ in ran = true })
        XCTAssertFalse(ran)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "existing")
        XCTAssertEqual(try entries(), ["model.mtl"])
    }
    func testFailedPromotionRollsBackOnlyNewAssets() throws {
        let original = try textFile("keep", name: "unrelated.obj")
        var moves = 0
        XCTAssertThrowsError(try ExportAssetTransaction.write(names: ["model.mtl", "model.obj"], directory: directory, move: { from, to in
            moves += 1
            if moves == 2 { throw CocoaError(.fileWriteOutOfSpace) }
            try FileManager.default.moveItem(at: from, to: to)
        }) { stage in
            for name in ["model.obj", "model.mtl"] { try Data("new".utf8).write(to: stage.appendingPathComponent(name)) }
        })
        XCTAssertEqual(try entries(), ["unrelated.obj"])
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "keep")
    }
    func testStreamIsBoundedAndByteExact() throws {
        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
        var received = Data(), largest = 0, closes = 0
        let writer = StreamWriter(chunkSize: 1024, write: { largest = max(largest, $0.count); received.append($0) }, close: { closes += 1 })
        try writer.write(payload); try writer.close(); try writer.close()
        XCTAssertEqual(received, payload)
        XCTAssertEqual(largest, 1024)
        XCTAssertEqual(closes, 1)
        XCTAssertThrowsError(try writer.write("after close"))
    }
    func testMidstreamFailureThrowsWithoutRetryingPartialWrite() throws {
        var attempts = 0, closes = 0
        let writer = StreamWriter(chunkSize: 4, write: { _ in attempts += 1; throw CocoaError(.fileWriteOutOfSpace) }, close: { closes += 1 })
        XCTAssertThrowsError(try writer.write("12345"))
        XCTAssertThrowsError(try writer.write("retry"))
        XCTAssertThrowsError(try writer.close())
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(closes, 1)
    }
    func testSynchronizationFailurePropagatesAndCloses() throws {
        var closes = 0
        let writer = StreamWriter(write: { _ in }, synchronize: { throw CocoaError(.fileWriteOutOfSpace) }, close: { closes += 1 })
        try writer.write("complete but not durable")
        XCTAssertThrowsError(try writer.close())
        XCTAssertEqual(closes, 1)
    }
    func testStreamRefusesToTruncateExistingFile() throws {
        let url = try textFile("keep")
        XCTAssertThrowsError(try StreamWriter(url: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep")
    }
    func testImportReferencesPermitSupportedLocalAssetsAndComments() throws {
        let obj = try textFile("\u{FEFF}mtllib scan.mtl # material\r\nv 0 0 0\nmtllib scan.mtl\n")
        XCTAssertEqual(try ExportText.objMaterialReferences(obj), ["scan.mtl"])
        let mtl = try textFile("newmtl sample\nmap_Kd scan_texture.jpg # image\n", name: "scan.mtl")
        XCTAssertEqual(try ExportText.materialTextureReferences(mtl), ["scan_texture.jpg"])
    }
    func testImportRejectsTraversalAbsoluteRemoteAndUnsupportedReferences() throws {
        for name in ["../private.mtl", "/private.mtl", "https://host/file.mtl", "folder\\file.mtl", "one.mtl two.mtl", "file\u{0}.mtl"] {
            XCTAssertThrowsError(try ExportText.objMaterialReferences(textFile("mtllib \(name)\n")))
        }
        for command in ["call other.obj", "csh command", "shadow_obj other.obj", "trace_obj other.obj", "maplib other.map"] {
            XCTAssertThrowsError(try ExportText.objMaterialReferences(textFile(command)))
        }
        XCTAssertThrowsError(try ExportText.materialTextureReferences(textFile("map_Kd ../photo.jpg")))
        XCTAssertThrowsError(try ExportText.materialTextureReferences(textFile("map_Kd -s 1 1 1 photo.jpg")))
    }
    func testCarriageReturnCannotHideExternalReference() throws {
        XCTAssertThrowsError(try ExportText.objMaterialReferences(textFile("v 0 0 0\rmtllib ../private.mtl\r")))
        let text = String(repeating: "x", count: 65_535) + "\r\nnext\rlast"
        var lines: [String] = []
        try ExportText.lines(textFile(text)) { lines.append($0) }
        XCTAssertEqual(lines, [String(repeating: "x", count: 65_535), "next", "last"])
    }
    func testLineLimitAlsoAppliesWhenOversizedLineEndsInNewline() throws {
        let url = try textFile(String(repeating: "x", count: (1 << 20) + 1) + "\n")
        var emitted = false
        XCTAssertThrowsError(try ExportText.lines(url) { _ in emitted = true })
        XCTAssertFalse(emitted)
    }
    func testReferenceListsAreBounded() throws {
        let text = (0..<17).map { "mtllib material\($0).mtl" }.joined(separator: "\n")
        XCTAssertThrowsError(try ExportText.objMaterialReferences(textFile(text)))
    }
    func testPLYHeaderPreflightAcceptsASCIIAndBothBinaryOrders() throws {
        let properties = "element vertex 3\nproperty float x\nproperty float y\nproperty float z\n"
        let faces = "element face 1\nproperty list uchar uint vertex_indices\n"
        for format in ["ascii", "binary_little_endian", "binary_big_endian"] {
            let header = "ply\nformat \(format) 1.0\ncomment fixture\n" + properties + faces + "end_header\n"
            var data = Data(header.utf8)
            data.append(format == "ascii" ? Data("0 0 0\n1 0 0\n0 1 0\n3 0 1 2\n".utf8) : Data(repeating: 0, count: 3 * 12 + 13))
            let url = directory.appendingPathComponent("input.ply")
            try data.write(to: url)
            try ExportText.validatePLYHeader(url)
        }
    }
    func testPLYHeaderPreflightAcceptsPointCloudColoursAndCRLF() throws {
        let header = "ply\r\nformat binary_little_endian 1.0\r\nelement vertex 1\r\nproperty float x\r\nproperty float y\r\nproperty float z\r\nproperty uchar red\r\nproperty uchar green\r\nproperty uchar blue\r\nend_header\r\n"
        let url = directory.appendingPathComponent("point.ply")
        try (Data(header.utf8) + Data(repeating: 0, count: 15)).write(to: url)
        try ExportText.validatePLYHeader(url)
    }
    func testPLYHeaderPreflightRejectsUnboundedNegativeAndOverflowCounts() throws {
        for count in ["5000001", "18446744073709551616", "-1"] {
            let file = try textFile("ply\nformat ascii 1.0\nelement vertex \(count)\nproperty float x\nproperty float y\nproperty float z\nend_header\n0 0 0\n")
            XCTAssertThrowsError(try ExportText.validatePLYHeader(file))
        }
    }
    func testPLYHeaderPreflightRejectsTruncatedBinaryPayload() throws {
        let file = try textFile("ply\nformat binary_little_endian 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\nend_header\n")
        XCTAssertThrowsError(try ExportText.validatePLYHeader(file))
    }
    func testPLYHeaderPreflightRejectsInvalidLayoutsAndMissingCoordinates() throws {
        for properties in ["property nonsense x\nproperty float y\nproperty float z\n",
                           "property float x\nproperty float y\n",
                           "property float x\nproperty float x\nproperty float y\nproperty float z\n",
                           "property list float uint x\nproperty float y\nproperty float z\n"] {
            let file = try textFile("ply\nformat ascii 1.0\nelement vertex 1\n" + properties + "end_header\n0 0 0\n")
            XCTAssertThrowsError(try ExportText.validatePLYHeader(file))
        }
    }
    func testPLYHeaderPreflightRejectsOversizedHeaderAndFakeMagic() throws {
        XCTAssertThrowsError(try ExportText.validatePLYHeader(textFile("not a ply\nend_header\n")))
        let file = try textFile("ply\nformat ascii 1.0\ncomment " + String(repeating: "x", count: 65_536) + "\nend_header\n")
        XCTAssertThrowsError(try ExportText.validatePLYHeader(file))
    }
}
