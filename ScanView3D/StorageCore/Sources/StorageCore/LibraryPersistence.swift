import Foundation

/// The app compiles this source directly; the package tests the same implementation.
/// Callers serialize access, and publish their new state only after commit succeeds.
final class LibraryPersistence<Value: Codable> {
    enum Failure: LocalizedError {
        case readOnly, changedOnDisk, destinationExists, missingItem, invalidLibrary

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
            case .invalidLibrary:
                return "The library contains unsafe or conflicting file references. Existing data has been preserved; no files were changed."
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
    private let validate: (Value) throws -> Void
    private let maximumIndexBytes: Int

    init(indexURL: URL, fileManager: FileManager = .default,
         write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
         copy: @escaping (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
         maximumIndexBytes: Int = 128 * 1024 * 1024,
         validate: @escaping (Value) throws -> Void = { _ in }) {
        self.indexURL = indexURL
        self.backupURL = indexURL.deletingPathExtension().appendingPathExtension("backup.json")
        self.fileManager = fileManager
        self.write = write
        self.copy = copy
        self.validate = validate
        self.maximumIndexBytes = maximumIndexBytes
    }

    func load(default empty: Value) throws -> Value {
        isReadOnly = true
        if !LibraryFileSafety.exists(indexURL) {
            // A missing primary with an existing backup is not a new installation.
            guard !LibraryFileSafety.exists(backupURL) else { throw Failure.readOnly }
            committedData = nil
            isReadOnly = false
            return empty
        }
        let data = try readIndex()
        let value = try JSONDecoder().decode(Value.self, from: data)
        try validate(value)
        committedData = data
        isReadOnly = false
        return value
    }

    func commit(_ value: Value) throws {
        guard !isReadOnly else { throw Failure.readOnly }
        let current = LibraryFileSafety.exists(indexURL) ? try readIndex() : nil
        guard current == committedData else {
            isReadOnly = true
            throw Failure.changedOnDisk
        }
        try validate(value)
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumIndexBytes else { throw Failure.invalidLibrary }
        _ = try LibraryFileSafety.child(backupURL.lastPathComponent, of: backupURL.deletingLastPathComponent())
        // Keep the last successfully decoded index, never a corrupt input. A backup
        // is metadata recovery, not an undo for intentionally deleted scan files.
        if let previous = committedData { try write(previous, backupURL) }
        try write(data, indexURL)
        committedData = data
    }

    private func readIndex() throws -> Data {
        try LibraryFileSafety.validateTree(indexURL)
        let size = try indexURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size >= 0, size <= maximumIndexBytes else { throw Failure.invalidLibrary }
        let data = try Data(contentsOf: indexURL)
        guard data.count <= maximumIndexBytes else { throw Failure.invalidLibrary }
        return data
    }

    /// Copy-on-write transaction: source files survive every failure before the
    /// index commit. A process interruption can leave extra copies, never remove
    /// the only indexed copy. Destinations must be private to this operation.
    func copyAndCommit(_ items: [(source: URL, destination: URL)], commit: () throws -> Void) throws {
        guard !isReadOnly else { throw Failure.readOnly }
        var seen = Set<String>()
        for item in items {
            guard LibraryFileSafety.exists(item.source) else { throw Failure.missingItem }
            try LibraryFileSafety.validateTree(item.source)
            guard seen.insert(item.destination.standardizedFileURL.path).inserted,
                  !LibraryFileSafety.exists(item.destination) else { throw Failure.destinationExists }
        }
        var created: [URL] = []
        do {
            for item in items {
                guard !LibraryFileSafety.exists(item.destination) else { throw Failure.destinationExists }
                do {
                    try copy(item.source, item.destination)
                    created.append(item.destination)
                } catch {
                    // Copy can create a partial target, but file-exists means the
                    // target belonged to someone else: never clean it up.
                    if (error as? CocoaError)?.code != .fileWriteFileExists { created.append(item.destination) }
                    throw error
                }
            }
            try commit()
        } catch {
            for url in created.reversed() { try? fileManager.removeItem(at: url) }
            throw error
        }
    }
}

/// Filenames in the library are data, never paths. Reject unsafe aliases before
/// any read/copy/delete, including symlinks supplied through Files/file sharing.
enum LibraryFileSafety {
    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw CocoaError(.fileReadInvalidFileName)
        }
    }

    static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func child(_ name: String, of directory: URL) throws -> URL {
        try validateName(name)
        let child = directory.appendingPathComponent(name)
        // resolvingSymlinks also catches broken aliases and symlinked ancestors.
        let expected = directory.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(name).path
        guard child.resolvingSymlinksInPath().standardizedFileURL.path == expected else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        if exists(child) {
            let attributes = try FileManager.default.attributesOfItem(atPath: child.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw CocoaError(.fileReadInvalidFileName)
            }
        }
        return child
    }

    static func validateTree(_ url: URL, depth: Int = 0) throws {
        guard depth <= 64 else { throw CocoaError(.fileReadCorruptFile) }
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard let kind = attributes[.type] as? FileAttributeType,
              kind == .typeRegular || kind == .typeDirectory else { throw CocoaError(.fileReadCorruptFile) }
        if kind == .typeDirectory {
            // Enumerate without following symbolic links; every entry is checked.
            let entries = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for entry in entries { try validateTree(entry, depth: depth + 1) }
        }
    }
}
