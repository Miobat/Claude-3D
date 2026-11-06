import Foundation

enum ExportText {
    /// Bounded UTF-8 line reader; do not split multibyte characters at chunks.
    static func lines(_ url: URL, _ consume: (String) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var pending = Data()
        var skipLeadingLF = false
        while var chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
            if skipLeadingLF, chunk.first == 10 { chunk.removeFirst() }
            skipLeadingLF = false
            pending.append(chunk)
            while let newline = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                guard pending.distance(from: pending.startIndex, to: newline) <= 1 << 20 else { throw CoordinateError.incompleteExport }
                guard let line = String(data: pending[..<newline], encoding: .utf8) else { throw CoordinateError.incompleteExport }
                try consume(line)
                let carriageReturn = pending[newline] == 13
                pending.removeSubrange(...newline)
                if carriageReturn {
                    if pending.first == 10 { pending.removeFirst() }
                    else if pending.isEmpty { skipLeadingLF = true }
                }
            }
            guard pending.count <= 1 << 20 else { throw CoordinateError.incompleteExport }
        }
        if !pending.isEmpty {
            guard let line = String(data: pending, encoding: .utf8) else { throw CoordinateError.incompleteExport }
            try consume(line)
        }
    }
    static func zUpLine(_ line: String) throws -> String {
        let parts = line.split(whereSeparator: { $0.isWhitespace })
        guard let kind = parts.first, kind == "v" || kind == "vn" else { return line }
        guard parts.count >= 4, let x = Double(parts[1]), let y = Double(parts[2]), let z = Double(parts[3]),
              x.isFinite, y.isFinite, z.isFinite else { throw CoordinateError.incompleteExport }
        let p = CoordinateMath.zUp(SIMD3(x, y, z))
        let trailing = parts.dropFirst(4).joined(separator: " ")
        return "\(kind) \(p.x) \(p.y) \(p.z)" + (trailing.isEmpty ? "" : " " + trailing)
    }

    /// Scene loaders must never follow external or parent-directory references
    /// from an imported text asset. Packaging supports one leaf per directive,
    /// not search paths, map options or filename quoting.
    static func safeAssetName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 240 &&
        name == (name as NSString).lastPathComponent &&
        !name.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" || $0 == ":" || $0 == "\"" || $0 == "#" }) &&
        !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func objMaterialReferences(_ url: URL) throws -> [String] {
        var result: [String] = []
        try lines(url) { line in
            let fields = line.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(whereSeparator: { $0.isWhitespace })
            guard let token = fields.first else { return }
            let keyword = token.lowercased()
            // Unsupported external references are not safe to pass to SceneKit.
            guard !["call", "csh", "shadow_obj", "trace_obj", "maplib"].contains(String(keyword)) else {
                throw CoordinateError.incompleteExport
            }
            if keyword == "mtllib" {
                guard fields.count == 2, safeAssetName(String(fields[1])) else { throw CoordinateError.incompleteExport }
                let name = String(fields[1])
                if !result.contains(name) {
                    guard result.count < 16 else { throw CoordinateError.incompleteExport }
                    result.append(name)
                }
            }
        }
        return result
    }

    static func materialTextureReferences(_ url: URL) throws -> [String] {
        var result: [String] = []
        try lines(url) { line in
            let fields = line.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(whereSeparator: { $0.isWhitespace })
            guard let token = fields.first else { return }
            let keyword = token.lowercased()
            if keyword.hasPrefix("map_") || ["bump", "disp", "decal", "refl", "norm"].contains(String(keyword)) {
                guard fields.count == 2, safeAssetName(String(fields[1])) else { throw CoordinateError.incompleteExport }
                let name = String(fields[1])
                if !result.contains(name) {
                    guard result.count < 32 else { throw CoordinateError.incompleteExport }
                    result.append(name)
                }
            }
        }
        return result
    }

    /// Bound allocation declarations BEFORE handing an imported PLY to SceneKit.
    /// This is a header preflight, not a replacement for the native geometry and
    /// finite-position validation performed after parsing the copied model.
    static func validatePLYHeader(_ url: URL) throws {
        struct Element {
            let name: String
            let count: UInt64
            var minimumStride: UInt64 = 0
            var properties: Set<String> = []
            var scalarCoordinates: Set<String> = []
        }
        let widths: [String: UInt64] = ["char": 1, "int8": 1, "uchar": 1, "uint8": 1,
            "short": 2, "int16": 2, "ushort": 2, "uint16": 2,
            "int": 4, "int32": 4, "uint": 4, "uint32": 4,
            "float": 4, "float32": 4, "double": 8, "float64": 8]
        let listCounts: Set<String> = ["char", "int8", "uchar", "uint8", "short", "int16", "ushort", "uint16", "int", "int32", "uint", "uint32"]
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let fileSize = try input.seekToEnd()
        try input.seek(toOffset: 0)
        let prefix = try input.read(upToCount: 65_536) ?? Data()
        var offset = prefix.startIndex, lineNumber = 0
        var format: String?, bodyOffset: Int?
        var elements: [Element] = []
        while offset < prefix.endIndex {
            guard let end = prefix[offset...].firstIndex(where: { $0 == 10 || $0 == 13 }),
                  let line = String(data: prefix[offset..<end], encoding: .utf8) else { throw CoordinateError.incompleteExport }
            var next = end + 1
            if prefix[end] == 13, next < prefix.endIndex, prefix[next] == 10 { next += 1 }
            offset = next; lineNumber += 1
            if lineNumber == 1 {
                guard line == "ply" else { throw CoordinateError.incompleteExport }
                continue
            }
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let keyword = fields.first else { continue }
            switch keyword {
            case "comment", "obj_info": continue
            case "format":
                guard format == nil, elements.isEmpty, fields.count == 3, fields[2] == "1.0",
                      ["ascii", "binary_little_endian", "binary_big_endian"].contains(fields[1]) else { throw CoordinateError.incompleteExport }
                format = fields[1]
            case "element":
                guard format != nil, fields.count == 3, let count = UInt64(fields[2]), count <= 5_000_000,
                      elements.count < 16, !elements.contains(where: { $0.name == fields[1] }) else { throw CoordinateError.incompleteExport }
                elements.append(Element(name: fields[1], count: count))
            case "property":
                guard !elements.isEmpty, elements[elements.count - 1].properties.count < 64 else { throw CoordinateError.incompleteExport }
                let name: String, width: UInt64, scalar: Bool
                if fields.count == 3, let size = widths[fields[1]] {
                    name = fields[2]; width = size; scalar = true
                } else if fields.count == 5, fields[1] == "list", listCounts.contains(fields[2]),
                          let countSize = widths[fields[2]], widths[fields[3]] != nil {
                    name = fields[4]; width = countSize; scalar = false
                } else { throw CoordinateError.incompleteExport }
                let index = elements.count - 1
                guard elements[index].properties.insert(name).inserted else { throw CoordinateError.incompleteExport }
                elements[index].minimumStride += width
                if scalar, ["x", "y", "z"].contains(name) { elements[index].scalarCoordinates.insert(name) }
            case "end_header":
                guard fields.count == 1 else { throw CoordinateError.incompleteExport }
                bodyOffset = offset
            default: throw CoordinateError.incompleteExport
            }
            if bodyOffset != nil { break }
        }
        guard let format, let bodyOffset, let vertices = elements.first(where: { $0.name == "vertex" }),
              vertices.count > 0, vertices.scalarCoordinates == Set(["x", "y", "z"]),
              elements.allSatisfy({ $0.count == 0 || $0.minimumStride > 0 }),
              UInt64(bodyOffset) <= fileSize else { throw CoordinateError.incompleteExport }
        var minimumBytes: UInt64 = 0
        for element in elements {
            // Even an ASCII record consumes at least one byte. For binary list
            // properties only the count scalar is a lower bound; native parsing
            // still validates each actual list and face index afterward.
            let stride = format == "ascii" ? 1 : element.minimumStride
            let product = element.count.multipliedReportingOverflow(by: stride)
            let sum = minimumBytes.addingReportingOverflow(product.partialValue)
            guard !product.overflow, !sum.overflow else { throw CoordinateError.incompleteExport }
            minimumBytes = sum.partialValue
        }
        guard minimumBytes <= fileSize - UInt64(bodyOffset) else { throw CoordinateError.incompleteExport }
    }
}

/// Validates the parallel arrays before writing or handing them to a native
/// viewer. A malformed face must not be silently skipped while the header and
/// semantic sidecars still claim it was saved.
enum MeshExportValidation {
    static func validate(vertices: [SIMD3<Float>], normals: [SIMD3<Float>],
                         colors: [SIMD4<Float>], faces: [[UInt32]],
                         cornerUVs: [SIMD2<Float>]? = nil) throws {
        guard !vertices.isEmpty,
              vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              normals.isEmpty || (normals.count == vertices.count && normals.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })),
              colors.isEmpty || (colors.count == vertices.count && colors.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })),
              faces.allSatisfy({ $0.count == 3 && $0.allSatisfy({ UInt64($0) < UInt64(vertices.count) }) }) else {
            throw CoordinateError.incompleteExport
        }
        if let uv = cornerUVs {
            guard faces.count <= Int.max / 3, uv.count == faces.count * 3,
                  uv.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw CoordinateError.incompleteExport }
        }
    }
}

/// Stage the complete asset set before exposing any destination. Failures roll
/// back only files promoted by this attempt; existing files are never removed.
/// A process kill may leave unindexed files, but cannot replace indexed assets.
enum ExportAssetTransaction {
    static func write(names: [String], directory: URL,
                      move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
                      body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        guard !names.isEmpty, Set(names).count == names.count,
              names.allSatisfy(ExportText.safeAssetName) else { throw CoordinateError.incompleteExport }
        for name in names where fm.fileExists(atPath: directory.appendingPathComponent(name).path) {
            throw CocoaError(.fileWriteFileExists)
        }
        let staging = directory.appendingPathComponent(".mesh-\(UUID().uuidString).partial", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        try body(staging)
        for name in names {
            let file = staging.appendingPathComponent(name)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? 0) > 0 else { throw CoordinateError.incompleteExport }
        }
        var promoted: [URL] = []
        do {
            for name in names {
                let destination = directory.appendingPathComponent(name)
                try move(staging.appendingPathComponent(name), destination)
                promoted.append(destination)
            }
        } catch {
            for file in promoted.reversed() { try? fm.removeItem(at: file) }
            throw error
        }
    }
}

/// All flushes use throwing I/O, including mid-stream writes. The old
/// nonthrowing FileHandle.write could raise an Objective-C exception on full
/// storage instead of leaving capture recovery available to the save flow.
final class StreamWriter {
    private var buffer = Data()
    private let chunkSize: Int
    private let writeBytes: (Data) throws -> Void
    private let synchronize: () throws -> Void
    private let closeHandle: () throws -> Void
    private var closed = false
    private var failure: Error?

    convenience init(url: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        guard fm.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: url)
        self.init(write: { try handle.write(contentsOf: $0) },
                  synchronize: { try handle.synchronize() }, close: { try handle.close() })
    }

    // Injectable sink verifies failures at flush/sync rather than relying on
    // nondeterministic simulator disk exhaustion.
    init(chunkSize: Int = 65_536, write: @escaping (Data) throws -> Void,
         synchronize: @escaping () throws -> Void = {}, close: @escaping () throws -> Void = {}) {
        self.chunkSize = max(1, chunkSize)
        self.writeBytes = write; self.synchronize = synchronize; self.closeHandle = close
        buffer.reserveCapacity(self.chunkSize)
    }
    deinit { if !closed { try? closeHandle() } }

    func write(_ text: String) throws { try write(Data(text.utf8)) }
    func write(_ bytes: Data) throws {
        if let failure { throw failure }
        guard !closed else { throw CocoaError(.fileWriteUnknown) }
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let end = min(bytes.endIndex, offset + min(chunkSize - buffer.count, bytes.endIndex - offset))
            buffer.append(bytes[offset..<end]); offset = end
            if buffer.count == chunkSize { try flush() }
        }
    }
    private func flush() throws {
        if !buffer.isEmpty {
            do { try writeBytes(buffer); buffer.removeAll(keepingCapacity: true) }
            catch { failure = error; throw error }
        }
    }
    func close() throws {
        guard !closed else { return }
        defer { if !closed { try? closeHandle(); closed = true } }
        if let failure { throw failure }
        try flush()
        try synchronize()
        try closeHandle()
        closed = true
    }
}
