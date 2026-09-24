import Foundation
import UIKit

/// Exports mesh data to Wavefront OBJ and PLY formats
class OBJExporter {

    enum ExportError: Error, LocalizedError {
        case noMeshData
        case fileWriteError(String)
        case invalidData

        var errorDescription: String? {
            switch self {
            case .noMeshData:
                return "No mesh data to export"
            case .fileWriteError(let detail):
                return "Failed to write file: \(detail)"
            case .invalidData:
                return "Invalid mesh data"
            }
        }
    }

    /// Export MeshData to OBJ with per-vertex colours (no texture).
    static func export(
        meshData: MeshData,
        fileName: String,
        includeNormals: Bool = true,
        includeColors: Bool = true,
        directory: URL? = nil
    ) throws -> URL {
        guard !meshData.vertices.isEmpty else { throw ExportError.noMeshData }

        let exportDir = directory ?? getDefaultExportDirectory()
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let name = sanitizeFileName(fileName)
        let objURL = exportDir.appendingPathComponent("\(name).obj")
        let mtlURL = exportDir.appendingPathComponent("\(name).mtl")

        let out = try StreamWriter(url: objURL)
        out.write("# ScanView 3D - OBJ Export\n# Vertices: \(meshData.vertexCount)\n# Faces: \(meshData.faceCount)\n")
        out.write("mtllib \(name).mtl\no \(name)\n")
        let colored = includeColors && meshData.colors.count == meshData.vertices.count
        for i in 0..<meshData.vertices.count {
            let v = meshData.vertices[i]
            if colored {
                let c = meshData.colors[i]
                out.write("v \(v.x) \(v.y) \(v.z) \(c.x) \(c.y) \(c.z)\n")
            } else {
                out.write("v \(v.x) \(v.y) \(v.z)\n")
            }
        }
        let hasNormals = includeNormals && !meshData.normals.isEmpty
        if hasNormals {
            for n in meshData.normals { out.write("vn \(n.x) \(n.y) \(n.z)\n") }
        }
        out.write("usemtl scan_material\n")
        for face in meshData.faces where face.count == 3 {
            let a = Int(face[0]) + 1, b = Int(face[1]) + 1, c = Int(face[2]) + 1
            out.write(hasNormals ? "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n" : "f \(a) \(b) \(c)\n")
        }
        try out.close()

        let mtl = "# ScanView 3D - Material Library\n\nnewmtl scan_material\nKa 0.2 0.2 0.2\nKd 0.8 0.8 0.8\nKs 0.05 0.05 0.05\nNs 5.0\nd 1.0\nillum 2\n"
        try? mtl.write(to: mtlURL, atomically: true, encoding: .utf8)
        return objURL
    }

    /// Export a UV-textured OBJ from a baked atlas (per-face-corner UVs).
    /// Produces <name>.obj + <name>.mtl + <name>_texture.jpg.
    static func exportTextured(
        meshData: MeshData,
        fileName: String,
        baked: BakedTexture,
        directory: URL? = nil
    ) throws -> URL {
        guard !meshData.vertices.isEmpty, meshData.faceCount > 0 else { throw ExportError.noMeshData }

        let exportDir = directory ?? getDefaultExportDirectory()
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let name = sanitizeFileName(fileName)
        let objURL = exportDir.appendingPathComponent("\(name).obj")
        let mtlURL = exportDir.appendingPathComponent("\(name).mtl")
        let texName = "\(name)_texture.jpg"

        if let jpeg = baked.atlasImage.jpegData(compressionQuality: 0.92) {
            try jpeg.write(to: exportDir.appendingPathComponent(texName))
        }

        let out = try StreamWriter(url: objURL)
        out.write("# ScanView 3D - Textured OBJ Export\n# Vertices: \(meshData.vertexCount)  Faces: \(meshData.faceCount)\n")
        out.write("mtllib \(name).mtl\no \(name)\n")
        for v in meshData.vertices { out.write("v \(v.x) \(v.y) \(v.z)\n") }
        let hasNormals = !meshData.normals.isEmpty
        if hasNormals {
            for n in meshData.normals { out.write("vn \(n.x) \(n.y) \(n.z)\n") }
        }
        // One texture coordinate per face corner, in face order (origin bottom-left).
        for uv in baked.cornerUVs { out.write("vt \(uv.x) \(uv.y)\n") }
        out.write("usemtl scan_material\n")
        for (fi, face) in meshData.faces.enumerated() where face.count == 3 {
            let v0 = Int(face[0]) + 1, v1 = Int(face[1]) + 1, v2 = Int(face[2]) + 1
            let t0 = fi * 3 + 1, t1 = fi * 3 + 2, t2 = fi * 3 + 3
            out.write(hasNormals ? "f \(v0)/\(t0)/\(v0) \(v1)/\(t1)/\(v1) \(v2)/\(t2)/\(v2)\n"
                                 : "f \(v0)/\(t0) \(v1)/\(t1) \(v2)/\(t2)\n")
        }
        try out.close()

        let mtl = "# ScanView 3D - Material Library\n\nnewmtl scan_material\nKa 1.0 1.0 1.0\nKd 1.0 1.0 1.0\nKs 0.0 0.0 0.0\nd 1.0\nillum 1\nmap_Kd \(texName)\n"
        try? mtl.write(to: mtlURL, atomically: true, encoding: .utf8)
        return objURL
    }

    /// Export MeshData to binary PLY (much smaller files than ASCII)
    static func exportPLY(meshData: MeshData, fileName: String, directory: URL? = nil) throws -> URL {
        guard !meshData.vertices.isEmpty else { throw ExportError.noMeshData }
        let exportDir = directory ?? getDefaultExportDirectory()
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let plyURL = exportDir.appendingPathComponent("\(sanitizeFileName(fileName)).ply")
        let hasColors = !meshData.colors.isEmpty

        var header = "ply\nformat binary_little_endian 1.0\ncomment ScanView 3D Export\n"
        header += "element vertex \(meshData.vertexCount)\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        header += "property float nx\nproperty float ny\nproperty float nz\n"
        if hasColors {
            header += "property uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar alpha\n"
        }
        header += "element face \(meshData.faceCount)\nproperty list uchar uint vertex_indices\nend_header\n"

        var bytes = [UInt8](header.utf8)
        bytes.reserveCapacity(bytes.count + meshData.vertexCount * 28 + meshData.faceCount * 13)
        for i in 0..<meshData.vertexCount {
            let v = meshData.vertices[i]
            let n = i < meshData.normals.count ? meshData.normals[i] : SIMD3<Float>(0, 1, 0)
            for f in [v.x, v.y, v.z, n.x, n.y, n.z] { appendFloat(f, to: &bytes) }
            if hasColors {
                let c = i < meshData.colors.count ? meshData.colors[i] : SIMD4<Float>(0.7, 0.7, 0.7, 1.0)
                bytes.append(contentsOf: [byte(c.x), byte(c.y), byte(c.z), byte(c.w)])
            }
        }
        for face in meshData.faces where face.count == 3 {
            bytes.append(3)
            for idx in face { appendUInt32(idx, to: &bytes) }
        }
        try Data(bytes).write(to: plyURL)
        return plyURL
    }

    /// Export a colored point cloud as a binary PLY (vertices + RGB, no faces).
    static func exportPointCloudPLY(meshData: MeshData, fileName: String, directory: URL? = nil) throws -> URL {
        guard !meshData.vertices.isEmpty else { throw ExportError.noMeshData }
        let exportDir = directory ?? getDefaultExportDirectory()
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let plyURL = exportDir.appendingPathComponent("\(sanitizeFileName(fileName)).ply")
        let hasColors = !meshData.colors.isEmpty

        var header = "ply\nformat binary_little_endian 1.0\ncomment ScanView 3D Point Cloud\n"
        header += "element vertex \(meshData.vertices.count)\nproperty float x\nproperty float y\nproperty float z\n"
        if hasColors { header += "property uchar red\nproperty uchar green\nproperty uchar blue\n" }
        header += "end_header\n"

        var bytes = [UInt8](header.utf8)
        bytes.reserveCapacity(bytes.count + meshData.vertices.count * 15)
        for i in 0..<meshData.vertices.count {
            let v = meshData.vertices[i]
            appendFloat(v.x, to: &bytes); appendFloat(v.y, to: &bytes); appendFloat(v.z, to: &bytes)
            if hasColors {
                let c = i < meshData.colors.count ? meshData.colors[i] : SIMD4<Float>(0.7, 0.7, 0.7, 1)
                bytes.append(contentsOf: [byte(c.x), byte(c.y), byte(c.z)])
            }
        }
        try Data(bytes).write(to: plyURL)
        return plyURL
    }

    private static func appendFloat(_ value: Float, to bytes: inout [UInt8]) {
        let bits = value.bitPattern.littleEndian
        bytes.append(UInt8(truncatingIfNeeded: bits))
        bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
        bytes.append(UInt8(truncatingIfNeeded: bits >> 16))
        bytes.append(UInt8(truncatingIfNeeded: bits >> 24))
    }

    private static func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func byte(_ v: Float) -> UInt8 { UInt8(min(max(v * 255, 0), 255)) }

    // MARK: - Helpers

    private static func getDefaultExportDirectory() -> URL {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsDir.appendingPathComponent(AppConstants.exportDirectory)
    }

    private static func sanitizeFileName(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return name
            .components(separatedBy: invalidChars)
            .joined(separator: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}

/// Writes a large text file in chunks instead of building one huge string.
final class StreamWriter {
    private let handle: FileHandle
    private var buffer = Data()
    private let chunk = 4 << 20

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        buffer.reserveCapacity(chunk + 1024)
    }

    func write(_ text: String) {
        buffer.append(contentsOf: text.utf8)
        if buffer.count >= chunk {
            handle.write(buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    func close() throws {
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        buffer.removeAll()
        try handle.close()
    }
}
