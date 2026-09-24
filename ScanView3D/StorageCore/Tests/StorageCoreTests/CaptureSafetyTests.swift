import Foundation
import XCTest
@testable import StorageCore

final class CaptureSafetyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var directory: URL!
    private let fm = FileManager.default
    private typealias Store = CaptureCheckpointStore<String, [Double]>
    private enum InjectedFailure: Error { case diskFull }

    override func setUpWithError() throws {
        directory = fm.temporaryDirectory.appendingPathComponent("CaptureSafetyTests-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: directory) }

    private func fix(latitude: Double = 60, longitude: Double = 10, horizontal: Double = 4,
                     altitude: Double = 120, vertical: Double = 8, age: Double = 1,
                     requestAge: Double = 10, reduced: Bool = false) -> CaptureLocation? {
        CaptureLocation.validated(latitude: latitude, longitude: longitude, horizontalAccuracy: horizontal,
            altitude: altitude, verticalAccuracy: vertical, timestamp: now.addingTimeInterval(-age),
            requestedAt: now.addingTimeInterval(-requestAge), now: now, reducedAccuracy: reduced)
    }

    func testAcceptsCurrentValidFix() {
        XCTAssertEqual(fix()?.latitude, 60)
        XCTAssertEqual(fix()?.horizontalAccuracy, 4)
        XCTAssertEqual(fix()?.altitude, 120)
        XCTAssertEqual(fix()?.verticalAccuracy, 8)
    }
    func testRejectsNegativeHorizontalAccuracy() { XCTAssertNil(fix(horizontal: -1)) }
    func testRejectsCachedFixFromBeforeThisCapture() { XCTAssertNil(fix(age: 11, requestAge: 10)) }
    func testRejectsStaleFixEvenIfCaptureStartedEarlier() { XCTAssertNil(fix(age: 31, requestAge: 90)) }
    func testAllowsExactFreshnessBoundary() { XCTAssertNotNil(fix(age: 30, requestAge: 90)) }
    func testRejectsFutureFix() { XCTAssertNil(fix(age: -3)) }
    func testRejectsNonfinitePositionAndAccuracy() {
        XCTAssertNil(fix(latitude: .nan))
        XCTAssertNil(fix(longitude: .infinity))
        XCTAssertNil(fix(horizontal: .nan))
        XCTAssertNil(fix(horizontal: .infinity))
    }
    func testRejectsOutOfRangeCoordinates() {
        XCTAssertNil(fix(latitude: 91))
        XCTAssertNil(fix(longitude: -181))
    }
    func testInvalidVerticalAccuracyDoesNotInvalidateHorizontalFix() {
        let value = fix(vertical: -1)
        XCTAssertNotNil(value)
        XCTAssertNil(value?.altitude)
        XCTAssertNil(value?.verticalAccuracy)
    }
    func testInvalidAltitudeIsOmitted() {
        XCTAssertNil(fix(altitude: .nan)?.altitude)
        XCTAssertNil(fix(vertical: .infinity)?.altitude)
    }
    func testReducedAccuracyIsRetainedNotPresentedAsPrecise() {
        let value = fix(horizontal: 1200, reduced: true)
        XCTAssertEqual(value?.horizontalAccuracy, 1200)
        XCTAssertEqual(value?.reducedAccuracy, true)
    }
    func testLocationMetadataRoundTrips() throws {
        let value = try XCTUnwrap(fix())
        XCTAssertEqual(try JSONDecoder().decode(CaptureLocation.self, from: JSONEncoder().encode(value)), value)
    }
    func testZeroAccuracyAndSeaLevelAreValid() {
        XCTAssertEqual(fix(horizontal: 0, altitude: 0, vertical: 0)?.altitude, 0)
    }

    func testCurrentWorkerCanCommit() {
        let epoch = CaptureEpoch()
        var changed = false
        XCTAssertTrue(epoch.withCurrent(epoch.current) { changed = true })
        XCTAssertTrue(changed)
    }
    func testResetRejectsOldWorkerAndAcceptsNewWorker() {
        let epoch = CaptureEpoch()
        let old = epoch.current
        epoch.invalidate()
        var values: [String] = []
        XCTAssertFalse(epoch.withCurrent(old) { values.append("old") })
        XCTAssertTrue(epoch.withCurrent(epoch.current) { values.append("new") })
        XCTAssertEqual(values, ["new"])
    }
    func testRapidResetsNeverReuseAnOldToken() {
        let epoch = CaptureEpoch()
        var tokens: [UUID] = []
        for _ in 0..<100 { tokens.append(epoch.current); epoch.invalidate() }
        for token in tokens { XCTAssertFalse(epoch.isCurrent(token)) }
    }
    func testLateBackgroundCallbackCannotMutateNewSession() {
        let epoch = CaptureEpoch()
        let old = epoch.current
        let ready = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "worker returned")
        DispatchQueue.global().async {
            ready.signal()
            release.wait()
            XCTAssertFalse(epoch.withCurrent(old) { XCTFail("Old capture mutated new capture") })
            finished.fulfill()
        }
        XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
        epoch.invalidate()
        release.signal()
        wait(for: [finished], timeout: 2)
    }

    func testCheckpointCanBeReopenedAfterStoreRecreation() throws {
        try Store(directory: directory).save("stopped", payload: [1, 2, 3])
        let recovered = try Store(directory: directory).load()
        XCTAssertEqual(recovered.0, "stopped")
        XCTAssertEqual(recovered.1, [1, 2, 3])
    }
    func testPhotoOnlyCaptureHasDurableManifestWithoutMesh() throws {
        let store = Store(directory: directory)
        try store.save("photos available", payload: nil)
        XCTAssertEqual(try store.readManifest(), "photos available")
        XCTAssertNil(try store.load().1)
    }
    func testMetadataOnlyCheckpointKeepsPriorGeometry() throws {
        let store = Store(directory: directory)
        try store.save("geometry", payload: [1, 2])
        try store.save("new metadata", payload: nil)
        XCTAssertEqual(try store.load().0, "new metadata")
        XCTAssertEqual(try store.load().1, [1, 2])
    }
    func testPayloadWriteFailurePreservesPriorCheckpoint() throws {
        let store = Store(directory: directory)
        try store.save("previous", payload: [1])
        let failing = Store(directory: directory, write: { _, _ in throw InjectedFailure.diskFull })
        XCTAssertThrowsError(try failing.save("next", payload: [2]))
        XCTAssertEqual(try store.load().0, "previous")
        XCTAssertEqual(try store.load().1, [1])
    }
    func testManifestWriteFailurePreservesPriorMeshAndCleansNewPayload() throws {
        let store = Store(directory: directory)
        try store.save("previous", payload: [1])
        let before = try fm.contentsOfDirectory(atPath: directory.path).sorted()
        let failing = Store(directory: directory, write: { data, url in
            if url.lastPathComponent == "checkpoint.json" { throw InjectedFailure.diskFull }
            try data.write(to: url, options: .atomic)
        })
        XCTAssertThrowsError(try failing.save("next", payload: [2]))
        XCTAssertEqual(try store.load().0, "previous")
        XCTAssertEqual(try store.load().1, [1])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: directory.path).sorted(), before)
    }
    func testSuccessfulCheckpointReplacesOnlyPriorPayload() throws {
        let store = Store(directory: directory)
        try store.save("one", payload: [1])
        let unrelated = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        try store.save("two", payload: [2])
        XCTAssertEqual(try store.load().1, [2])
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("mesh-") }.count, 1)
    }
    func testMissingPayloadDoesNotPretendCaptureIsEmpty() throws {
        let store = Store(directory: directory)
        try store.save("scan", payload: [1])
        let payload = try XCTUnwrap(fm.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix("mesh-") })
        try fm.removeItem(at: directory.appendingPathComponent(payload))
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try store.readManifest(), "scan")
    }
    func testCorruptManifestIsPreservedAndCannotBeOverwritten() throws {
        let path = directory.appendingPathComponent("checkpoint.json")
        let data = Data("{broken".utf8)
        try data.write(to: path)
        let store = Store(directory: directory)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save("replacement", payload: [2]))
        XCTAssertEqual(try Data(contentsOf: path), data)
    }
    func testPayloadPathTraversalIsRejected() throws {
        let data = Data(#"{"manifest":"scan","payloadFile":"../outside.plist"}"#.utf8)
        try data.write(to: directory.appendingPathComponent("checkpoint.json"))
        XCTAssertThrowsError(try Store(directory: directory).load())
    }
}
