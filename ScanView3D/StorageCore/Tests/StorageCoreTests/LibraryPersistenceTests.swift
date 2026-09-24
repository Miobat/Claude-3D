import Foundation
import XCTest
@testable import StorageCore

final class LibraryPersistenceTests: XCTestCase {
    private struct Record: Codable, Equatable {
        var name: String
        var optionalNewField: [String]?
    }
    private enum TestFailure: Error { case diskFull, copyInterrupted }
    private var directory: URL!
    private var index: URL { directory.appendingPathComponent("projects.json") }
    private let fm = FileManager.default
    private let original = [Record(name: "Existing scan")]

    override func setUpWithError() throws {
        directory = fm.temporaryDirectory.appendingPathComponent("StorageCoreTests-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try fm.removeItem(at: directory)
    }

    private func seededStore() throws -> LibraryPersistence<[Record]> {
        try JSONEncoder().encode(original).write(to: index)
        let store = LibraryPersistence<[Record]>(indexURL: index)
        XCTAssertEqual(try store.load(default: []), original)
        return store
    }

    private func file(_ name: String, contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testNewLibraryCanCommitAndReload() throws {
        let store = LibraryPersistence<[Record]>(indexURL: index)
        XCTAssertEqual(try store.load(default: []), [])
        try store.commit(original)
        XCTAssertEqual(try LibraryPersistence<[Record]>(indexURL: index).load(default: []), original)
    }

    func testLegacyJSONMissingOptionalFieldsLoads() throws {
        try Data(#"[{"name":"Existing scan"}]"#.utf8).write(to: index)
        let store = LibraryPersistence<[Record]>(indexURL: index)
        XCTAssertEqual(try store.load(default: []), original)
        try store.commit(original)
    }

    func testCommitBeforeLoadIsRefused() throws {
        let store = LibraryPersistence<[Record]>(indexURL: index)
        XCTAssertThrowsError(try store.commit([]))
        XCTAssertFalse(fm.fileExists(atPath: index.path))
    }

    func testCorruptIndexCannotBeOverwritten() throws {
        let corrupt = Data("{interrupted".utf8)
        try corrupt.write(to: index)
        let store = LibraryPersistence<[Record]>(indexURL: index)
        XCTAssertThrowsError(try store.load(default: []))
        XCTAssertTrue(store.isReadOnly)
        XCTAssertThrowsError(try store.commit([]))
        XCTAssertEqual(try Data(contentsOf: index), corrupt)
    }

    func testMissingIndexWithBackupIsNotTreatedAsNewLibrary() throws {
        let store = try seededStore()
        try store.commit([Record(name: "Changed")])
        try fm.removeItem(at: index)
        let reopened = LibraryPersistence<[Record]>(indexURL: index)
        XCTAssertThrowsError(try reopened.load(default: []))
        XCTAssertThrowsError(try reopened.commit([]))
        XCTAssertEqual(try JSONDecoder().decode([Record].self, from: Data(contentsOf: store.backupURL)), original)
    }

    func testBackupContainsPreviousCommittedIndex() throws {
        let store = try seededStore()
        let before = try Data(contentsOf: index)
        try store.commit([Record(name: "Changed")])
        XCTAssertEqual(try Data(contentsOf: store.backupURL), before)
    }

    func testFailedIndexWritePreservesLibraryAndCanRetry() throws {
        _ = try seededStore()
        let before = try Data(contentsOf: index)
        var fail = true
        let store = LibraryPersistence<[Record]>(indexURL: index, write: { data, url in
            if url.lastPathComponent == "projects.json", fail { throw TestFailure.diskFull }
            try data.write(to: url, options: .atomic)
        })
        _ = try store.load(default: [])
        XCTAssertThrowsError(try store.commit([]))
        XCTAssertEqual(try Data(contentsOf: index), before)
        fail = false
        try store.commit([])
        XCTAssertEqual(try store.load(default: original), [])
    }

    func testFailedBackupWriteDoesNotChangePrimary() throws {
        _ = try seededStore()
        let before = try Data(contentsOf: index)
        let store = LibraryPersistence<[Record]>(indexURL: index, write: { _, _ in throw TestFailure.diskFull })
        _ = try store.load(default: [])
        XCTAssertThrowsError(try store.commit([]))
        XCTAssertEqual(try Data(contentsOf: index), before)
    }

    func testExternalIndexChangeLocksFurtherWrites() throws {
        let store = try seededStore()
        let external = Data("external change".utf8)
        try external.write(to: index)
        XCTAssertThrowsError(try store.commit([]))
        XCTAssertTrue(store.isReadOnly)
        XCTAssertEqual(try Data(contentsOf: index), external)
    }

    func testCopyFailurePreservesSourcesAndRemovesPartialDestinations() throws {
        let source1 = try file("model", contents: "model bytes")
        let source2 = try file("texture", contents: "texture bytes")
        let dest1 = directory.appendingPathComponent("new-model")
        let dest2 = directory.appendingPathComponent("new-texture")
        let store = LibraryPersistence<[Record]>(indexURL: index, copy: { source, destination in
            try self.fm.copyItem(at: source, to: destination)
            if source == source2 { throw TestFailure.copyInterrupted }
        })
        _ = try store.load(default: [])
        var committed = false
        XCTAssertThrowsError(try store.copyAndCommit([(source1, dest1), (source2, dest2)]) { committed = true })
        XCTAssertFalse(committed)
        XCTAssertEqual(try String(contentsOf: source1, encoding: .utf8), "model bytes")
        XCTAssertEqual(try String(contentsOf: source2, encoding: .utf8), "texture bytes")
        XCTAssertFalse(fm.fileExists(atPath: dest1.path))
        XCTAssertFalse(fm.fileExists(atPath: dest2.path))
    }

    func testIndexFailureRollsBackNewCopiesOnly() throws {
        let store = try seededStore()
        let source = try file("model", contents: "original")
        let destination = directory.appendingPathComponent("new-model")
        XCTAssertThrowsError(try store.copyAndCommit([(source, destination)]) { throw TestFailure.diskFull })
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
        XCTAssertEqual(try store.load(default: []), original)
    }

    func testExistingDestinationIsNeverOverwrittenOrRemoved() throws {
        let store = try seededStore()
        let source = try file("model", contents: "source")
        let destination = try file("existing", contents: "unrelated")
        XCTAssertThrowsError(try store.copyAndCommit([(source, destination)]) { XCTFail("Must not commit") })
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "unrelated")
    }

    func testMissingSourceAbortsBeforeAnyCopy() throws {
        let store = try seededStore()
        let source = try file("model", contents: "source")
        let destination = directory.appendingPathComponent("new-model")
        XCTAssertThrowsError(try store.copyAndCommit([
            (source, destination),
            (directory.appendingPathComponent("missing"), directory.appendingPathComponent("new-texture"))
        ]) { XCTFail("Must not commit") })
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
    }

    func testSuccessfulTransactionCopiesFoldersBeforeCommitting() throws {
        let store = try seededStore()
        let photos = directory.appendingPathComponent("photos")
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: photos.appendingPathComponent("frame.jpg"))
        let destination = directory.appendingPathComponent("new-photos")
        try store.copyAndCommit([(photos, destination)]) {
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("frame.jpg")), Data("photo".utf8))
            try store.commit([Record(name: "Moved")])
        }
        // Cleanup is deliberately after commit and belongs to the caller.
        XCTAssertTrue(fm.fileExists(atPath: photos.path))
        XCTAssertEqual(try store.load(default: []), [Record(name: "Moved")])
    }

    func testDuplicateDestinationPreflightPreservesSource() throws {
        let store = try seededStore()
        let source = try file("model", contents: "source")
        let destination = directory.appendingPathComponent("new-model")
        XCTAssertThrowsError(try store.copyAndCommit([(source, destination), (source, destination)]) { XCTFail("Must not commit") })
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
    }
}
