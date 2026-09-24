import Foundation

/// The app compiles this source directly; the package tests the same implementation.
/// Callers serialize access, and publish their new state only after commit succeeds.
final class LibraryPersistence<Value: Codable> {
    enum Failure: LocalizedError {
        case readOnly, changedOnDisk, destinationExists, missingItem

        var errorDescription: String? {
            switch self {
            case .readOnly:
                return "The library could not be read. Saving is disabled to protect your existing scans. The original index and scan files have been preserved."
            case .changedOnDisk:
                return "The library changed on disk. Reopen the app before making more changes."
            case .destinationExists:
                return "A destination file already exists. Nothing was overwritten."
            case .missingItem:
                return "A required scan file or project is missing. The operation was cancelled."
            }
        }
    }

    let indexURL: URL
    let backupURL: URL
    private(set) var isReadOnly = true
    private var committedData: Data?
    private let fileManager: FileManager
    // Injectable I/O allows deterministic disk-full and partial-copy regression tests.
    private let write: (Data, URL) throws -> Void
    private let copy: (URL, URL) throws -> Void

    init(indexURL: URL, fileManager: FileManager = .default,
         write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
         copy: @escaping (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) {
        self.indexURL = indexURL
        self.backupURL = indexURL.deletingPathExtension().appendingPathExtension("backup.json")
        self.fileManager = fileManager
        self.write = write
        self.copy = copy
    }

    func load(default empty: Value) throws -> Value {
        isReadOnly = true
        if !fileManager.fileExists(atPath: indexURL.path) {
            // A missing primary with an existing backup is not a new installation.
            guard !fileManager.fileExists(atPath: backupURL.path) else { throw Failure.readOnly }
            committedData = nil
            isReadOnly = false
            return empty
        }
        let data = try Data(contentsOf: indexURL)
        let value = try JSONDecoder().decode(Value.self, from: data)
        committedData = data
        isReadOnly = false
        return value
    }

    func commit(_ value: Value) throws {
        guard !isReadOnly else { throw Failure.readOnly }
        let current = fileManager.fileExists(atPath: indexURL.path) ? try Data(contentsOf: indexURL) : nil
        guard current == committedData else {
            isReadOnly = true
            throw Failure.changedOnDisk
        }
        let data = try JSONEncoder().encode(value)
        // Keep the last successfully decoded index, never a corrupt input. A backup
        // is metadata recovery, not an undo for intentionally deleted scan files.
        if let previous = committedData { try write(previous, backupURL) }
        try write(data, indexURL)
        committedData = data
    }

    /// Copy-on-write transaction: source files survive every failure before the
    /// index commit. A process interruption can leave extra copies, never remove
    /// the only indexed copy. Destinations must be private to this operation.
    func copyAndCommit(_ items: [(source: URL, destination: URL)], commit: () throws -> Void) throws {
        guard !isReadOnly else { throw Failure.readOnly }
        var seen = Set<String>()
        for item in items {
            guard fileManager.fileExists(atPath: item.source.path) else { throw Failure.missingItem }
            guard seen.insert(item.destination.standardizedFileURL.path).inserted,
                  !fileManager.fileExists(atPath: item.destination.path) else { throw Failure.destinationExists }
        }
        var created: [URL] = []
        do {
            for item in items {
                // Include the current target: copyItem may leave a partial copy on failure.
                created.append(item.destination)
                try copy(item.source, item.destination)
            }
            try commit()
        } catch {
            for url in created.reversed() { try? fileManager.removeItem(at: url) }
            throw error
        }
    }
}
