import Foundation

/// Streams an aligned USDZ wrapper with the original USDZ nested unchanged.
/// USDZ permits nested archives and requires stored (uncompressed) entries whose
/// payloads start at a multiple of 64 bytes. No material/texture re-encoding.
enum AlignedUSDZ {
    private struct Entry {
        let name: String
        let data: Data?
        let file: URL?
        let size: UInt32
        let crc: UInt32
        var offset: UInt32 = 0
    }
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var c = UInt32(value)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    private static func updateCRC(_ initial: UInt32, _ data: Data) -> UInt32 {
        var c = initial
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 255)] ^ (c >> 8) }
        return c
    }
    static func layer(transform: [Double]) throws -> Data {
        let matrix = try CoordinateMath.usdMatrix(transform)
        return Data("""
        #usda 1.0
        (
            defaultPrim = "AlignedScan"
            upAxis = "Y"
            metersPerUnit = 1
        )
        def Xform "AlignedScan" {
            matrix4d xformOp:transform = \(matrix)
            uniform token[] xformOpOrder = ["xformOp:transform"]
            def Xform "Source" (
                prepend references = @source.usdz@
            ) {}
        }

        """.utf8)
    }
    /// The output must be new. On any error only this attempt's output is removed.
    static func write(source: URL, to output: URL, transform: [Double], cancelled: () -> Bool = { false }) throws {
        let root = try layer(transform: transform)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard try input.read(upToCount: 4) == Data([0x50, 0x4b, 3, 4]) else { throw CoordinateError.unsupportedArchive }
        try input.seek(toOffset: 0)
        var size: UInt64 = 0, crc: UInt32 = 0xffffffff
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            if cancelled() { throw CancellationError() }
            size += UInt64(chunk.count)
            guard size < UInt64(UInt32.max) - 4096 else { throw CoordinateError.archiveTooLarge }
            crc = updateCRC(crc, chunk)
        }
        var entries = [Entry(name: "aligned.usda", data: root, file: nil, size: UInt32(root.count), crc: updateCRC(0xffffffff, root) ^ 0xffffffff),
                       Entry(name: "source.usdz", data: nil, file: source, size: UInt32(size), crc: crc ^ 0xffffffff)]
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw CoordinateError.incompleteExport }
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: output) } }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        var offset: UInt64 = 0
        func put(_ data: Data) throws {
            guard offset + UInt64(data.count) < UInt64(UInt32.max) else { throw CoordinateError.archiveTooLarge }
            try handle.write(contentsOf: data)
            offset += UInt64(data.count)
        }
        for index in entries.indices {
            if cancelled() { throw CancellationError() }
            entries[index].offset = UInt32(offset)
            let entry = entries[index], name = Data(entry.name.utf8)
            // Include a well-formed ZIP extra-field header, even when padding is small.
            let extraLength = 4 + Int((64 - ((offset + 30 + UInt64(name.count) + 4) % 64)) % 64)
            var header = Data()
            header.le(UInt32(0x04034b50)); header.le(UInt16(20)); header.le(UInt16(0)); header.le(UInt16(0))
            header.le(UInt16(0)); header.le(UInt16(33)); header.le(entry.crc); header.le(entry.size); header.le(entry.size)
            header.le(UInt16(name.count)); header.le(UInt16(extraLength)); header.append(name)
            header.le(UInt16(0x1986)); header.le(UInt16(extraLength - 4)); header.append(Data(repeating: 0, count: extraLength - 4))
            try put(header)
            if let data = entry.data { try put(data) }
            else {
                try input.seek(toOffset: 0)
                var copied: UInt64 = 0, copiedCRC: UInt32 = 0xffffffff
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                    if cancelled() { throw CancellationError() }
                    copied += UInt64(chunk.count); copiedCRC = updateCRC(copiedCRC, chunk)
                    try put(chunk)
                }
                guard copied == size, copiedCRC ^ 0xffffffff == entry.crc else { throw CoordinateError.incompleteExport }
            }
        }
        let directoryStart = offset
        for entry in entries {
            let name = Data(entry.name.utf8)
            var central = Data()
            central.le(UInt32(0x02014b50)); central.le(UInt16(20)); central.le(UInt16(20))
            central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(33))
            central.le(entry.crc); central.le(entry.size); central.le(entry.size)
            central.le(UInt16(name.count)); central.le(UInt16(0)); central.le(UInt16(0))
            central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt32(0)); central.le(entry.offset)
            central.append(name); try put(central)
        }
        let directorySize = offset - directoryStart
        var end = Data()
        end.le(UInt32(0x06054b50)); end.le(UInt16(0)); end.le(UInt16(0))
        end.le(UInt16(entries.count)); end.le(UInt16(entries.count))
        end.le(UInt32(directorySize)); end.le(UInt32(directoryStart)); end.le(UInt16(0))
        try put(end)
        try handle.synchronize()
        success = true
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
