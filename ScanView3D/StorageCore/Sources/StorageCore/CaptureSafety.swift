import Foundation
import CryptoKit

/// Worker results may only mutate the capture that accepted them.
final class CaptureEpoch {
    private let lock = NSLock()
    private var value = UUID()
    var current: UUID {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        value = UUID()
    }
    @discardableResult
    func withCurrent(_ token: UUID, _ work: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value == token else { return false }
        work()
        return true
    }
    func isCurrent(_ token: UUID) -> Bool { current == token }
}

/// The same memory decision applies to Fast texture frames and HQ/Splat photos.
/// Pausing photos is sticky until the next capture; accepted work still drains.
enum CaptureMemoryPolicy {
    enum Action: Equatable { case continueCapture, pausePhotos, pauseCapture }
    static func action(availableMB: Double, textureMB: Double, photosEnabled: Bool) -> Action {
        guard availableMB.isFinite, availableMB >= 200 else { return .pauseCapture }
        if photosEnabled && (availableMB < 400 || !textureMB.isFinite || textureMB > 800) { return .pausePhotos }
        return .continueCapture
    }
}

/// Approximate phone position, not a project origin, CRS transform or survey control.
struct CaptureLocation: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let altitude: Double?
    let verticalAccuracy: Double?
    let timestamp: Date
    let reducedAccuracy: Bool

    static func validated(latitude: Double, longitude: Double, horizontalAccuracy: Double,
                          altitude: Double, verticalAccuracy: Double, timestamp: Date,
                          requestedAt: Date, now: Date, reducedAccuracy: Bool = false) -> CaptureLocation? {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              horizontalAccuracy.isFinite, horizontalAccuracy >= 0,
              timestamp.timeIntervalSince1970.isFinite,
              timestamp >= requestedAt, now.timeIntervalSince(timestamp) <= 30,
              timestamp.timeIntervalSince(now) <= 2 else { return nil }
        let hasAltitude = altitude.isFinite && verticalAccuracy.isFinite && verticalAccuracy >= 0
        return CaptureLocation(latitude: latitude, longitude: longitude, horizontalAccuracy: horizontalAccuracy,
                               altitude: hasAltitude ? altitude : nil, verticalAccuracy: hasAltitude ? verticalAccuracy : nil,
                               timestamp: timestamp, reducedAccuracy: reducedAccuracy)
    }
}

/// Publish a checkpoint only after its payload is durable. Failed writes preserve
/// the previous checkpoint. Callers serialize all operations on a private queue.
final class CaptureCheckpointStore<Manifest: Codable, Payload: Codable> {
    let directory: URL
    private let write: (Data, URL) throws -> Void
    private let maximumPayloadBytes: Int
    private let maximumManifestBytes: Int
    init(directory: URL, maximumPayloadBytes: Int = 512 * 1_048_576, maximumManifestBytes: Int = 1_048_576,
         write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.directory = directory
        self.maximumPayloadBytes = max(0, maximumPayloadBytes)
        self.maximumManifestBytes = max(0, maximumManifestBytes)
        self.write = write
    }
    private struct Record: Codable {
        let manifest: Manifest
        let payloadFile: String?
        // Missing version is the original format. New records bind the payload
        // bytes, so a readable but corrupted/replaced plist cannot become a scan.
        let version: Int?
        let payloadBytes: Int?
        let payloadSHA256: String?
    }
    func save(_ manifest: Manifest, payload: Payload?) throws {
        try validateDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try validateDirectory()
        let newPayloadFile = payload == nil ? nil : "mesh-\(UUID().uuidString).plist"
        let manifestURL = directory.appendingPathComponent("checkpoint.json")
        let previous: Record?
        if try exists(manifestURL) {
            previous = try readRecord()
        } else { previous = nil }
        let payloadFile = newPayloadFile ?? previous?.payloadFile
        var bytes: Int?
        var digest: String?
        var wroteCandidate = false
        do {
            if let payload, let payloadFile {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(payload)
                guard data.count <= maximumPayloadBytes else { throw CocoaError(.fileWriteOutOfSpace) }
                let url = directory.appendingPathComponent(payloadFile)
                guard !(try exists(url)) else { throw CocoaError(.fileWriteFileExists) }
                bytes = data.count; digest = Self.hash(data)
                wroteCandidate = true
                try write(data, url)
                // Do not switch the manifest after a partial/silent payload write.
                let saved = try readFile(url, maximumBytes: maximumPayloadBytes)
                guard saved.count == bytes, Self.hash(saved) == digest else { throw CocoaError(.fileReadCorruptFile) }
            } else if let previous, previous.payloadFile != nil {
                let data = try readPayload(previous)
                bytes = data.count; digest = Self.hash(data)
            }
            let record = Record(manifest: manifest, payloadFile: payloadFile, version: 2,
                                payloadBytes: bytes, payloadSHA256: digest)
            let encoded = try JSONEncoder().encode(record)
            guard encoded.count <= maximumManifestBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            try write(encoded, manifestURL)
        } catch {
            if wroteCandidate, let newPayloadFile { try? FileManager.default.removeItem(at: directory.appendingPathComponent(newPayloadFile)) }
            throw error
        }
        if let old = previous?.payloadFile, old != payloadFile, Self.safe(old) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
        }
    }
    func load() throws -> (Manifest, Payload?) {
        let record = try readRecord()
        guard record.payloadFile != nil else { return (record.manifest, nil) }
        return (record.manifest, try PropertyListDecoder().decode(Payload.self, from: readPayload(record)))
    }
    func readManifest() throws -> Manifest {
        try readRecord().manifest
    }
    private func readRecord() throws -> Record {
        try validateDirectory()
        let data = try readFile(directory.appendingPathComponent("checkpoint.json"), maximumBytes: maximumManifestBytes)
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.version == nil || record.version == 2,
              record.payloadFile.map(Self.safe) ?? true else { throw CocoaError(.fileReadCorruptFile) }
        if record.version == 2, record.payloadFile != nil {
            guard let bytes = record.payloadBytes, bytes > 0, bytes <= maximumPayloadBytes,
                  let hash = record.payloadSHA256, hash.count == 64,
                  hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw CocoaError(.fileReadCorruptFile) }
        } else if record.payloadBytes != nil || record.payloadSHA256 != nil {
            throw CocoaError(.fileReadCorruptFile)
        }
        return record
    }
    private func readPayload(_ record: Record) throws -> Data {
        guard let file = record.payloadFile, Self.safe(file) else { throw CocoaError(.fileReadCorruptFile) }
        let data = try readFile(directory.appendingPathComponent(file), maximumBytes: maximumPayloadBytes)
        if record.version == 2 {
            guard data.count == record.payloadBytes, Self.hash(data) == record.payloadSHA256 else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return data
    }
    private func readFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              let size = values.fileSize, size > 0, size <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 0, data.count <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
    private func validateDirectory() throws {
        // Do not follow a replaced checkpoint folder or recovery root. System
        // ancestors (e.g. macOS /var) may legitimately resolve through symlinks.
        for url in [directory, directory.deletingLastPathComponent()] {
            guard try exists(url) else { continue }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw CocoaError(.fileReadCorruptFile) }
        }
    }
    private func exists(_ url: URL) throws -> Bool {
        // fileExists follows links and misses dangling ones. Attributes do not.
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return true }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return false }
    }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func safe(_ name: String) -> Bool {
        name.hasPrefix("mesh-") && name.hasSuffix(".plist") && !name.contains("/") && !name.contains("\\") && !name.contains("..")
    }
}
