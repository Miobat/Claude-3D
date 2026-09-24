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
        guard !meshData.vertices.isEmpty else {
            throw ExportError.noMeshData
        }

        let exportDir = directory ?? getDefaultExportDirectory()
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let sanitizedName = sanitizeFileName(fileName)
        let objURL = exportDir.appendingPathComponent("\(sanitizedName).obj")
        let mtlURL = exportDir.appendingPathComponent("\(sanitizedName).mtl")

        // Build OBJ content
        var objContent = ""
        objContent += "# ScanView 3D - OBJ Export\n"
        objContent += "# Exported: \(Date().formattedString)\n"
        objContent += "# Vertices: \(meshData.vertexCount)\n"
        objContent += "# Faces: \(meshData.faceCount)\n"
        objContent += "\n"
        objContent += "mtllib \(sanitizedName).mtl\n"
        objContent += "o \(sanitizedName)\n\n"

        // Write vertices with vertex colors (always include for fallback)
        for i in 0..<meshData.vertices.count {
            let v = meshData.vertices[i]
            if includeColors && i < meshData.colors.count {
                let c = meshData.colors[i]
                objContent += String(format: "v %.6f %.6f %.6f %.4f %.4f %.4f\n",
                                    v.x, v.y, v.z, c.x, c.y, c.z)
            } else {
                objContent += String(format: "v %.6f %.6f %.6f\n", v.x, v.y, v.z)
            }
        }
        objContent += "\n"

        // Write normals
        if includeNormals && !meshData.normals.isEmpty {
            for normal in meshData.normals {
                objContent += String(format: "vn %.6f %.6f %.6f\n", normal.x, normal.y, normal.z)
            }
            objContent += "\n"
        }

        // Write faces
        objContent += "usemtl scan_material\n"

        let hasNormals = includeNormals && !meshData.normals.isEmpty
        for face in meshData.faces {
            guard face.count == 3 else { continue }
            let a = Int(face[0]) + 1, b = Int(face[1]) + 1, c = Int(face[2]) + 1
            if hasNormals {
                objContent += "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n"
            } else {
                objContent += "f \(a) \(b) \(c)\n"
            }
        }

        try objContent.write(to: objURL, atomically: true, encoding: .utf8)

        // Write MTL file
        let mtlContent = """
        # ScanView 3D - Material Library

        newmtl scan_material
        Ka 0.2 0.2 0.2
        Kd 0.8 0.8 0.8
        Ks 0.05 0.05 0.05
        Ns 5.0
        d 1.0
        illum 2

        """

        try? mtlContent.write(to: mtlURL, atomically: true, encoding: .utf8)

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
        guard !meshData.vertices.isEmpty, meshData.faceCount > 0 else {
            throw ExportError.noMeshData
        }

        let exportDir = directory ?? getDefaultExportDirectory()
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let name = sanitizeFileName(fileName)
        let objURL = exportDir.appendingPathComponent("\(name).obj")
        let mtlURL = exportDir.appendingPathComponent("\(name).mtl")
        let texName = "\(name)_texture.jpg"
        let texURL = exportDir.appendingPathComponent(texName)

        if let jpeg = baked.atlasImage.jpegData(compressionQuality: 0.92) {
            try jpeg.write(to: texURL)
        }

        var obj = ""
        obj += "# ScanView 3D - Textured OBJ Export\n"
        obj += "# Exported: \(Date().formattedString)\n"
        obj += "# Vertices: \(meshData.vertexCount)  Faces: \(meshData.faceCount)\n"
        obj += "mtllib \(name).mtl\n"
        obj += "o \(name)\n\n"

        // Positions
        for v in meshData.vertices {
            obj += String(format: "v %.6f %.6f %.6f\n", v.x, v.y, v.z)
        }

        // Normals
        let hasNormals = !meshData.normals.isEmpty
        if hasNormals {
            for n in meshData.normals {
                obj += String(format: "vn %.6f %.6f %.6f\n", n.x, n.y, n.z)
            }
        }

        // Texture coordinates: one per face-corner, in face order (bottom-left origin)
        for uv in baked.cornerUVs {
            obj += String(format: "vt %.6f %.6f\n", uv.x, uv.y)
        }

        obj += "usemtl scan_material\n"

        // Faces: v/vt/vn — vt index is per-corner (fi*3+k), v/vn share the vertex index
        for (fi, face) in meshData.faces.enumerated() {
            guard face.count == 3 else { continue }
            let v0 = Int(face[0]) + 1, v1 = Int(face[1]) + 1, v2 = Int(face[2]) + 1
            let t0 = fi * 3 + 1, t1 = fi * 3 + 2, t2 = fi * 3 + 3
            if hasNormals {
                obj += "f \(v0)/\(t0)/\(v0) \(v1)/\(t1)/\(v1) \(v2)/\(t2)/\(v2)\n"
            } else {
                obj += "f \(v0)/\(t0) \(v1)/\(t1) \(v2)/\(t2)\n"
            }
        }

        try obj.write(to: objURL, atomically: true, encoding: .utf8)

        let mtl = """
        # ScanView 3D - Material Library

        newmtl scan_material
        Ka 1.0 1.0 1.0
        Kd 1.0 1.0 1.0
        Ks 0.0 0.0 0.0
        d 1.0
        illum 1
        map_Kd \(texName)
        """
        try? mtl.write(to: mtlURL, atomically: true, encoding: .utf8)

        return objURL
    }

    /// Export MeshData to binary PLY format (much smaller files than ASCII)
    static func exportPLY(
        meshData: MeshData,
        fileName: String,
        directory: URL? = nil
    ) throws -> URL {
        guard !meshData.vertices.isEmpty else {
            throw ExportError.noMeshData
        }

        let exportDir = directory ?? getDefaultExportDirectory()
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let sanitizedName = sanitizeFileName(fileName)
        let plyURL = exportDir.appendingPathComponent("\(sanitizedName).ply")

        let hasColors = !meshData.colors.isEmpty

        // Build header as ASCII string
        var header = "ply\n"
        header += "format binary_little_endian 1.0\n"
        header += "comment ScanView 3D Export\n"
        header += "element vertex \(meshData.vertexCount)\n"
        header += "property float x\n"
        header += "property float y\n"
        header += "property float z\n"
        header += "property float nx\n"
        header += "property float ny\n"
        header += "property float nz\n"
        if hasColors {
            header += "property uchar red\n"
            header += "property uchar green\n"
            header += "property uchar blue\n"
            header += "property uchar alpha\n"
        }
        header += "element face \(meshData.faceCount)\n"
        header += "property list uchar uint vertex_indices\n"
        header += "end_header\n"

        var data = Data(header.utf8)

        // Write binary vertex data (much more compact than ASCII)
        for i in 0..<meshData.vertexCount {
            let v = meshData.vertices[i]
            let n = i < meshData.normals.count ? meshData.normals[i] : SIMD3<Float>(0, 1, 0)

            // 6 floats: x, y, z, nx, ny, nz
            var values: [Float] = [v.x, v.y, v.z, n.x, n.y, n.z]
            data.append(contentsOf: values.withUnsafeBytes { Data($0) })

            if hasColors {
                let c = i < meshData.colors.count ? meshData.colors[i] : SIMD4<Float>(0.7, 0.7, 0.7, 1.0)
                var rgba: [UInt8] = [
                    UInt8(min(max(c.x * 255, 0), 255)),
                    UInt8(min(max(c.y * 255, 0), 255)),
                    UInt8(min(max(c.z * 255, 0), 255)),
                    UInt8(min(max(c.w * 255, 0), 255))
                ]
                data.append(contentsOf: rgba)
            }
        }

        // Write binary face data
        for face in meshData.faces {
            if face.count == 3 {
                var count: UInt8 = 3
                data.append(contentsOf: withUnsafeBytes(of: &count) { Data($0) })
                var indices = face.map { UInt32($0) }
                data.append(contentsOf: indices.withUnsafeBytes { Data($0) })
            }
        }

        try data.write(to: plyURL)
        return plyURL
    }

    /// Export a colored point cloud as a binary PLY (vertices + RGB, no faces).
    static func exportPointCloudPLY(
        meshData: MeshData,
        fileName: String,
        directory: URL? = nil
    ) throws -> URL {
        guard !meshData.vertices.isEmpty else { throw ExportError.noMeshData }

        let exportDir = directory ?? getDefaultExportDirectory()
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let sanitizedName = sanitizeFileName(fileName)
        let plyURL = exportDir.appendingPathComponent("\(sanitizedName).ply")

        let hasColors = !meshData.colors.isEmpty
        var header = "ply\n"
        header += "format binary_little_endian 1.0\n"
        header += "comment ScanView 3D Point Cloud\n"
        header += "element vertex \(meshData.vertices.count)\n"
        header += "property float x\n"
        header += "property float y\n"
        header += "property float z\n"
        if hasColors {
            header += "property uchar red\n"
            header += "property uchar green\n"
            header += "property uchar blue\n"
        }
        header += "end_header\n"

        var data = Data(header.utf8)
        for i in 0..<meshData.vertices.count {
            let v = meshData.vertices[i]
            var xyz: [Float] = [v.x, v.y, v.z]
            data.append(contentsOf: xyz.withUnsafeBytes { Data($0) })
            if hasColors {
                let c = i < meshData.colors.count ? meshData.colors[i] : SIMD4<Float>(0.7, 0.7, 0.7, 1)
                let rgb: [UInt8] = [
                    UInt8(min(max(c.x * 255, 0), 255)),
                    UInt8(min(max(c.y * 255, 0), 255)),
                    UInt8(min(max(c.z * 255, 0), 255))
                ]
                data.append(contentsOf: rgb)
            }
        }

        try data.write(to: plyURL)
        return plyURL
    }

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
