import Foundation

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
    init(directory: URL, write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.directory = directory
        self.write = write
    }
    private struct Record: Codable {
        let manifest: Manifest
        let payloadFile: String?
    }
    func save(_ manifest: Manifest, payload: Payload?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let newPayloadFile = payload == nil ? nil : "mesh-\(UUID().uuidString).plist"
        let manifestURL = directory.appendingPathComponent("checkpoint.json")
        let previous: Record?
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            previous = try JSONDecoder().decode(Record.self, from: Data(contentsOf: manifestURL))
        } else { previous = nil }
        let payloadFile = newPayloadFile ?? previous?.payloadFile
        do {
            if let payload, let payloadFile {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                try write(encoder.encode(payload), directory.appendingPathComponent(payloadFile))
            }
            try write(JSONEncoder().encode(Record(manifest: manifest, payloadFile: payloadFile)), directory.appendingPathComponent("checkpoint.json"))
        } catch {
            if let newPayloadFile { try? FileManager.default.removeItem(at: directory.appendingPathComponent(newPayloadFile)) }
            throw error
        }
        if let old = previous?.payloadFile, old != payloadFile, Self.safe(old) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
        }
    }
    func load() throws -> (Manifest, Payload?) {
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: directory.appendingPathComponent("checkpoint.json")))
        guard let file = record.payloadFile else { return (record.manifest, nil) }
        guard Self.safe(file) else { throw CocoaError(.fileReadCorruptFile) }
        return (record.manifest, try PropertyListDecoder().decode(Payload.self, from: Data(contentsOf: directory.appendingPathComponent(file))))
    }
    func readManifest() throws -> Manifest {
        try JSONDecoder().decode(Record.self, from: Data(contentsOf: directory.appendingPathComponent("checkpoint.json"))).manifest
    }
    private static func safe(_ name: String) -> Bool {
        name.hasPrefix("mesh-") && name.hasSuffix(".plist") && !name.contains("/") && !name.contains("\\") && !name.contains("..")
    }
}
