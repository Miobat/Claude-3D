import Foundation

/// Exports mesh data to Wavefront OBJ format
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

    /// Export MeshData to OBJ file format
    /// Returns the URL of the saved file
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

        // Ensure directory exists
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

        if includeColors {
            objContent += "mtllib \(sanitizedName).mtl\n"
        }

        objContent += "o \(sanitizedName)\n\n"

        // Write vertices with optional vertex colors (non-standard but widely supported)
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

        // Write faces (1-indexed in OBJ format)
        if includeColors {
            objContent += "usemtl scan_material\n"
        }

        let hasNormals = includeNormals && !meshData.normals.isEmpty
        for face in meshData.faces {
            if face.count == 3 {
                if hasNormals {
                    objContent += String(format: "f %d//%d %d//%d %d//%d\n",
                                        face[0] + 1, face[0] + 1,
                                        face[1] + 1, face[1] + 1,
                                        face[2] + 1, face[2] + 1)
                } else {
                    objContent += String(format: "f %d %d %d\n",
                                        face[0] + 1, face[1] + 1, face[2] + 1)
                }
            }
        }

        // Write OBJ file
        do {
            try objContent.write(to: objURL, atomically: true, encoding: .utf8)
        } catch {
            throw ExportError.fileWriteError(error.localizedDescription)
        }

        // Write MTL file
        if includeColors {
            let mtlContent = """
            # ScanView 3D - Material Library
            # Exported: \(Date().formattedString)

            newmtl scan_material
            Ka 0.2 0.2 0.2
            Kd 0.8 0.8 0.8
            Ks 0.1 0.1 0.1
            Ns 10.0
            d 1.0
            illum 2

            """

            do {
                try mtlContent.write(to: mtlURL, atomically: true, encoding: .utf8)
            } catch {
                // MTL failure is non-critical
                print("Warning: Could not write MTL file: \(error)")
            }
        }

        return objURL
    }

    /// Export MeshData to PLY format (better color support)
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

        var content = ""

        // PLY header
        content += "ply\n"
        content += "format ascii 1.0\n"
        content += "comment ScanView 3D Export\n"
        content += "element vertex \(meshData.vertexCount)\n"
        content += "property float x\n"
        content += "property float y\n"
        content += "property float z\n"
        content += "property float nx\n"
        content += "property float ny\n"
        content += "property float nz\n"

        if !meshData.colors.isEmpty {
            content += "property uchar red\n"
            content += "property uchar green\n"
            content += "property uchar blue\n"
            content += "property uchar alpha\n"
        }

        content += "element face \(meshData.faceCount)\n"
        content += "property list uchar uint vertex_indices\n"
        content += "end_header\n"

        // Vertex data
        for i in 0..<meshData.vertexCount {
            let v = meshData.vertices[i]
            let n = i < meshData.normals.count ? meshData.normals[i] : SIMD3<Float>(0, 1, 0)

            if i < meshData.colors.count {
                let c = meshData.colors[i]
                let r = UInt8(min(max(c.x * 255, 0), 255))
                let g = UInt8(min(max(c.y * 255, 0), 255))
                let b = UInt8(min(max(c.z * 255, 0), 255))
                let a = UInt8(min(max(c.w * 255, 0), 255))
                content += String(format: "%.6f %.6f %.6f %.6f %.6f %.6f %d %d %d %d\n",
                                 v.x, v.y, v.z, n.x, n.y, n.z, r, g, b, a)
            } else {
                content += String(format: "%.6f %.6f %.6f %.6f %.6f %.6f\n",
                                 v.x, v.y, v.z, n.x, n.y, n.z)
            }
        }

        // Face data
        for face in meshData.faces {
            if face.count == 3 {
                content += "3 \(face[0]) \(face[1]) \(face[2])\n"
            }
        }

        do {
            try content.write(to: plyURL, atomically: true, encoding: .utf8)
        } catch {
            throw ExportError.fileWriteError(error.localizedDescription)
        }

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
