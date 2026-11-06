import Foundation
import UIKit

/// Bounded, validated model writes. The complete asset set is staged before a
/// save exposes its model, and all write failures propagate to capture recovery.
class OBJExporter {
    enum ExportError: Error, LocalizedError {
        case noMeshData, fileWriteError(String), invalidData
        var errorDescription: String? {
            switch self {
            case .noMeshData: return "No mesh data to export"
            case .fileWriteError(let detail): return "Failed to write file: \(detail)"
            case .invalidData: return "Invalid mesh data"
            }
        }
    }

    static func export(meshData: MeshData, fileName: String, includeNormals: Bool = true,
                       includeColors: Bool = true, directory: URL? = nil) throws -> URL {
        try validate(meshData)
        let exportDir = directory ?? getDefaultExportDirectory()
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let name = sanitizeFileName(fileName)
        let objName = name + ".obj", mtlName = name + ".mtl"
        try ExportAssetTransaction.write(names: [mtlName, objName], directory: exportDir) { stage in
            let out = try StreamWriter(url: stage.appendingPathComponent(objName))
            try out.write("# TinyScanner by TinyCorp - OBJ Export\n# Vertices: \(meshData.vertexCount)\n# Faces: \(meshData.faceCount)\n")
            try out.write("mtllib \(mtlName)\no \(name)\n")
            let colored = includeColors && !meshData.colors.isEmpty
            for i in meshData.vertices.indices {
                let v = meshData.vertices[i]
                if colored {
                    let c = meshData.colors[i]
                    try out.write("v \(v.x) \(v.y) \(v.z) \(c.x) \(c.y) \(c.z)\n")
                } else { try out.write("v \(v.x) \(v.y) \(v.z)\n") }
            }
            let hasNormals = includeNormals && !meshData.normals.isEmpty
            if hasNormals {
                for n in meshData.normals { try out.write("vn \(n.x) \(n.y) \(n.z)\n") }
            }
            try out.write("usemtl scan_material\n")
            for face in meshData.faces {
                let a = Int(face[0]) + 1, b = Int(face[1]) + 1, c = Int(face[2]) + 1
                try out.write(hasNormals ? "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n" : "f \(a) \(b) \(c)\n")
            }
            try out.close()
            let material = try StreamWriter(url: stage.appendingPathComponent(mtlName))
            try material.write("# TinyScanner by TinyCorp - Material Library\n\nnewmtl scan_material\nKa 0.2 0.2 0.2\nKd 0.8 0.8 0.8\nKs 0.05 0.05 0.05\nNs 5.0\nd 1.0\nillum 2\n")
            try material.close()
        }
        return exportDir.appendingPathComponent(objName)
    }

    /// Per-face-corner UVs use OBJ's bottom-left texture convention.
    static func exportTextured(meshData: MeshData, fileName: String, baked: BakedTexture,
                               directory: URL? = nil) throws -> URL {
        guard meshData.faceCount > 0 else { throw ExportError.noMeshData }
        try validate(meshData, cornerUVs: baked.cornerUVs)
        guard let jpeg = baked.atlasImage.jpegData(compressionQuality: 0.92), !jpeg.isEmpty else {
            throw ExportError.fileWriteError("The texture image could not be encoded.")
        }
        let exportDir = directory ?? getDefaultExportDirectory()
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let name = sanitizeFileName(fileName)
        let objName = name + ".obj", mtlName = name + ".mtl", texName = name + "_texture.jpg"
        try ExportAssetTransaction.write(names: [texName, mtlName, objName], directory: exportDir) { stage in
            let texture = try StreamWriter(url: stage.appendingPathComponent(texName))
            try texture.write(jpeg); try texture.close()
            let out = try StreamWriter(url: stage.appendingPathComponent(objName))
            try out.write("# TinyScanner by TinyCorp - Textured OBJ Export\n# Vertices: \(meshData.vertexCount)  Faces: \(meshData.faceCount)\n")
            try out.write("mtllib \(mtlName)\no \(name)\n")
            for v in meshData.vertices { try out.write("v \(v.x) \(v.y) \(v.z)\n") }
            let hasNormals = !meshData.normals.isEmpty
            if hasNormals {
                for n in meshData.normals { try out.write("vn \(n.x) \(n.y) \(n.z)\n") }
            }
            for uv in baked.cornerUVs { try out.write("vt \(uv.x) \(uv.y)\n") }
            try out.write("usemtl scan_material\n")
            for (fi, face) in meshData.faces.enumerated() {
                let v0 = Int(face[0]) + 1, v1 = Int(face[1]) + 1, v2 = Int(face[2]) + 1
                let t0 = fi * 3 + 1, t1 = fi * 3 + 2, t2 = fi * 3 + 3
                try out.write(hasNormals ? "f \(v0)/\(t0)/\(v0) \(v1)/\(t1)/\(v1) \(v2)/\(t2)/\(v2)\n"
                    : "f \(v0)/\(t0) \(v1)/\(t1) \(v2)/\(t2)\n")
            }
            try out.close()
            let material = try StreamWriter(url: stage.appendingPathComponent(mtlName))
            try material.write("# TinyScanner by TinyCorp - Material Library\n\nnewmtl scan_material\nKa 1.0 1.0 1.0\nKd 1.0 1.0 1.0\nKs 0.0 0.0 0.0\nd 1.0\nillum 1\nmap_Kd \(texName)\n")
            try material.close()
        }
        return exportDir.appendingPathComponent(objName)
    }

    /// Binary PLY is streamed; saving must not allocate a second whole-mesh
    /// byte array just as the capture approaches its memory limit.
    static func exportPLY(meshData: MeshData, fileName: String, directory: URL? = nil) throws -> URL {
        try validate(meshData)
        let exportDir = directory ?? getDefaultExportDirectory()
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let name = sanitizeFileName(fileName) + ".ply"
        try ExportAssetTransaction.write(names: [name], directory: exportDir) { stage in
            let out = try StreamWriter(url: stage.appendingPathComponent(name))
            let hasColors = !meshData.colors.isEmpty
            var header = "ply\nformat binary_little_endian 1.0\ncomment TinyScanner by TinyCorp Export\n"
            header += "element vertex \(meshData.vertexCount)\nproperty float x\nproperty float y\nproperty float z\n"
            header += "property float nx\nproperty float ny\nproperty float nz\n"
            if hasColors { header += "property uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar alpha\n" }
            header += "element face \(meshData.faceCount)\nproperty list uchar uint vertex_indices\nend_header\n"
            try out.write(header)
            var record = Data(); record.reserveCapacity(28)
            for i in meshData.vertices.indices {
                let v = meshData.vertices[i]
                let n = meshData.normals.isEmpty ? SIMD3<Float>(0, 1, 0) : meshData.normals[i]
                record.removeAll(keepingCapacity: true)
                for value in [v.x, v.y, v.z, n.x, n.y, n.z] { appendUInt32(value.bitPattern, to: &record) }
                if hasColors {
                    let c = meshData.colors[i]
                    record.append(contentsOf: [c.x, c.y, c.z, c.w].map { UInt8(min(max($0 * 255, 0), 255)) })
                }
                try out.write(record)
            }
            for face in meshData.faces {
                record.removeAll(keepingCapacity: true); record.append(3)
                for index in face { appendUInt32(index, to: &record) }
                try out.write(record)
            }
            try out.close()
        }
        return exportDir.appendingPathComponent(name)
    }

    static func exportPointCloudPLY(meshData: MeshData, fileName: String, directory: URL? = nil,
                                    replacingExisting: Bool = false) throws -> URL {
        guard !meshData.vertices.isEmpty else { throw ExportError.noMeshData }
        let exportDir = directory ?? getDefaultExportDirectory()
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let plyURL = exportDir.appendingPathComponent("\(sanitizeFileName(fileName)).ply")
        try PointCloudPLYWriter.write(positions: meshData.vertices, colors: meshData.colors, to: plyURL,
                                      replacingExisting: replacingExisting)
        return plyURL
    }

    private static func validate(_ mesh: MeshData, cornerUVs: [SIMD2<Float>]? = nil) throws {
        guard !mesh.vertices.isEmpty else { throw ExportError.noMeshData }
        try MeshExportValidation.validate(vertices: mesh.vertices, normals: mesh.normals,
                                          colors: mesh.colors, faces: mesh.faces, cornerUVs: cornerUVs)
    }
    private static func appendUInt32(_ value: UInt32, to bytes: inout Data) {
        bytes.append(contentsOf: [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
                                  UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
    }
    private static func getDefaultExportDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppConstants.exportDirectory)
    }
    private static func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: ":/\\?%*|\"<>#").union(.whitespacesAndNewlines).union(.controlCharacters)
        let result = name.components(separatedBy: invalid).joined(separator: "_")
        return result.isEmpty ? "Scan" : String(result.prefix(120))
    }
}
