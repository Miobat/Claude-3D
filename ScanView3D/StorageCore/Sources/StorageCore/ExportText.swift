import Foundation

enum ExportText {
    /// Bounded UTF-8 line reader; do not split multibyte characters at chunks.
    static func lines(_ url: URL, _ consume: (String) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var pending = Data()
        while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                guard let line = String(data: pending[..<newline], encoding: .utf8) else { throw CoordinateError.incompleteExport }
                try consume(line.trimmingCharacters(in: .newlines))
                pending.removeSubrange(...newline)
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
}
