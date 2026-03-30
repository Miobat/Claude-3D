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

    /// Export MeshData to OBJ file format with vertex colors
    static func export(
        meshData: MeshData,
        fileName: String,
        includeNormals: Bool = true,
        includeColors: Bool = true,
        textureAtlas: TextureAtlasResult? = nil,
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

        // Validate texture atlas - check if UVs are actually usable
        var validTextureAtlas: TextureAtlasResult?
        var textureFileName: String?

        if let atlas = textureAtlas {
            // Count how many vertices have valid (non-zero) UVs
            let validUVCount = atlas.uvCoordinates.filter { $0.x > 0.001 || $0.y > 0.001 }.count
            let validRatio = Float(validUVCount) / Float(max(atlas.uvCoordinates.count, 1))

            // Only use texture if at least 40% of vertices have valid UVs
            if validRatio > 0.4 && atlas.uvCoordinates.count == meshData.vertices.count {
                validTextureAtlas = atlas
                textureFileName = "\(sanitizedName)_texture.jpg"
                let textureURL = exportDir.appendingPathComponent(textureFileName!)
                if let jpegData = atlas.atlasImage.jpegData(compressionQuality: 0.85) {
                    try? jpegData.write(to: textureURL)
                }
            }
        }

        let hasValidTexture = validTextureAtlas != nil

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

        // Write texture coordinates only if we have valid texture
        if hasValidTexture, let atlas = validTextureAtlas {
            for uv in atlas.uvCoordinates {
                objContent += String(format: "vt %.6f %.6f\n", uv.x, 1.0 - uv.y)
            }
            objContent += "\n"
        }

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

            if hasValidTexture, let atlas = validTextureAtlas {
                // Check if ALL vertices of this face have valid UVs
                let allValid = face.allSatisfy { idx in
                    let uv = atlas.uvCoordinates[Int(idx)]
                    return uv.x > 0.001 || uv.y > 0.001
                }

                if allValid && hasNormals {
                    objContent += String(format: "f %d/%d/%d %d/%d/%d %d/%d/%d\n",
                                        face[0]+1, face[0]+1, face[0]+1,
                                        face[1]+1, face[1]+1, face[1]+1,
                                        face[2]+1, face[2]+1, face[2]+1)
                } else if hasNormals {
                    // No valid texture - use vertex/normal only
                    objContent += String(format: "f %d//%d %d//%d %d//%d\n",
                                        face[0]+1, face[0]+1,
                                        face[1]+1, face[1]+1,
                                        face[2]+1, face[2]+1)
                } else {
                    objContent += String(format: "f %d %d %d\n",
                                        face[0]+1, face[1]+1, face[2]+1)
                }
            } else if hasNormals {
                objContent += String(format: "f %d//%d %d//%d %d//%d\n",
                                    face[0]+1, face[0]+1,
                                    face[1]+1, face[1]+1,
                                    face[2]+1, face[2]+1)
            } else {
                objContent += String(format: "f %d %d %d\n",
                                    face[0]+1, face[1]+1, face[2]+1)
            }
        }

        try objContent.write(to: objURL, atomically: true, encoding: .utf8)

        // Write MTL file
        var mtlContent = """
        # ScanView 3D - Material Library

        newmtl scan_material
        Ka 0.2 0.2 0.2
        Kd 0.8 0.8 0.8
        Ks 0.05 0.05 0.05
        Ns 5.0
        d 1.0
        illum 2

        """

        if let texName = textureFileName {
            mtlContent += "map_Kd \(texName)\n"
        }

        try? mtlContent.write(to: mtlURL, atomically: true, encoding: .utf8)

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
