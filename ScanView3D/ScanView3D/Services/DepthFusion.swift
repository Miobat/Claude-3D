import Foundation
import UIKit
import SceneKit
#if !targetEnvironment(simulator)
import ARKit
#endif

/// Depth frame fusion using a voxel grid (simplified TSDF approach)
/// Fuses multiple depth frames into a single clean mesh
class DepthFusion {

    // MARK: - Voxel Grid

    struct Voxel {
        var tsdf: Float = 1.0        // Truncated signed distance
        var weight: Float = 0        // Accumulated weight
        var colorR: Float = 0
        var colorG: Float = 0
        var colorB: Float = 0
    }

    private var grid: [Voxel]
    private let resolutionX: Int
    private let resolutionY: Int
    private let resolutionZ: Int
    private let voxelSize: Float
    private let origin: SIMD3<Float>
    private let truncation: Float

    // MARK: - Init

    /// Create a voxel grid for depth fusion
    /// - Parameters:
    ///   - bounds: The world-space bounding box to cover
    ///   - voxelSize: Size of each voxel in meters (smaller = more detail, more memory)
    init(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, voxelSize: Float = 0.02) {
        self.voxelSize = voxelSize
        self.truncation = voxelSize * 4.0
        self.origin = boundsMin - SIMD3<Float>(voxelSize, voxelSize, voxelSize) // small padding

        let extent = boundsMax - boundsMin + SIMD3<Float>(voxelSize * 2, voxelSize * 2, voxelSize * 2)
        self.resolutionX = min(Int(ceil(extent.x / voxelSize)), 256)
        self.resolutionY = min(Int(ceil(extent.y / voxelSize)), 256)
        self.resolutionZ = min(Int(ceil(extent.z / voxelSize)), 256)

        let totalVoxels = resolutionX * resolutionY * resolutionZ
        self.grid = [Voxel](repeating: Voxel(), count: totalVoxels)
    }

    var totalVoxels: Int { resolutionX * resolutionY * resolutionZ }

    // MARK: - Integrate Mesh Data

    /// Integrate raw mesh data from ARKit into the voxel grid
    func integrateMesh(_ meshData: MeshData) {
        for i in 0..<meshData.vertices.count {
            let vertex = meshData.vertices[i]
            let normal = i < meshData.normals.count ? meshData.normals[i] : SIMD3<Float>(0, 1, 0)
            let color = i < meshData.colors.count ? meshData.colors[i] : SIMD4<Float>(0.7, 0.7, 0.7, 1.0)

            // Find the voxel this vertex falls into
            let vx = Int((vertex.x - origin.x) / voxelSize)
            let vy = Int((vertex.y - origin.y) / voxelSize)
            let vz = Int((vertex.z - origin.z) / voxelSize)

            // Update the voxel and its neighbors within truncation distance
            let radius = Int(ceil(truncation / voxelSize))
            for dx in max(0, vx - radius)..<min(resolutionX, vx + radius + 1) {
                for dy in max(0, vy - radius)..<min(resolutionY, vy + radius + 1) {
                    for dz in max(0, vz - radius)..<min(resolutionZ, vz + radius + 1) {
                        let voxelCenter = SIMD3<Float>(
                            origin.x + (Float(dx) + 0.5) * voxelSize,
                            origin.y + (Float(dy) + 0.5) * voxelSize,
                            origin.z + (Float(dz) + 0.5) * voxelSize
                        )

                        // Signed distance from this voxel to the surface
                        let diff = voxelCenter - vertex
                        let sdf = dot(diff, normal)

                        // Only update if within truncation band
                        guard abs(sdf) < truncation else { continue }

                        let tsdf = min(1.0, sdf / truncation)
                        let w: Float = 1.0

                        let idx = dx + dy * resolutionX + dz * resolutionX * resolutionY
                        guard idx >= 0 && idx < grid.count else { continue }

                        // Weighted running average
                        let oldWeight = grid[idx].weight
                        let newWeight = oldWeight + w
                        grid[idx].tsdf = (grid[idx].tsdf * oldWeight + tsdf * w) / newWeight
                        grid[idx].colorR = (grid[idx].colorR * oldWeight + color.x * w) / newWeight
                        grid[idx].colorG = (grid[idx].colorG * oldWeight + color.y * w) / newWeight
                        grid[idx].colorB = (grid[idx].colorB * oldWeight + color.z * w) / newWeight
                        grid[idx].weight = min(newWeight, 50.0) // cap weight
                    }
                }
            }
        }
    }

    // MARK: - Extract Mesh (Marching Cubes)

    /// Extract a clean mesh from the voxel grid using marching cubes
    func extractMesh() -> MeshData {
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var faces: [[UInt32]] = []
        var colors: [SIMD4<Float>] = []

        // For each voxel cell, check if surface crosses it (TSDF changes sign)
        for z in 0..<(resolutionZ - 1) {
            for y in 0..<(resolutionY - 1) {
                for x in 0..<(resolutionX - 1) {
                    extractCellVertices(x: x, y: y, z: z,
                                       vertices: &vertices, normals: &normals,
                                       faces: &faces, colors: &colors)
                }
            }
        }

        // Calculate bounding box
        var minB = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxB = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        for v in vertices {
            minB = min(minB, v)
            maxB = max(maxB, v)
        }

        return MeshData(
            vertices: vertices,
            normals: normals,
            faces: faces,
            colors: colors,
            boundingBoxMin: vertices.isEmpty ? origin : minB,
            boundingBoxMax: vertices.isEmpty ? origin + SIMD3(Float(resolutionX), Float(resolutionY), Float(resolutionZ)) * voxelSize : maxB
        )
    }

    // MARK: - Cell Extraction (Simplified Marching Cubes)

    private func extractCellVertices(x: Int, y: Int, z: Int,
                                     vertices: inout [SIMD3<Float>],
                                     normals: inout [SIMD3<Float>],
                                     faces: inout [[UInt32]],
                                     colors: inout [SIMD4<Float>]) {
        // Get 8 corner values
        let corners = [
            getVoxel(x, y, z),
            getVoxel(x+1, y, z),
            getVoxel(x+1, y+1, z),
            getVoxel(x, y+1, z),
            getVoxel(x, y, z+1),
            getVoxel(x+1, y, z+1),
            getVoxel(x+1, y+1, z+1),
            getVoxel(x, y+1, z+1)
        ]

        // Skip cells where all corners have zero weight (unobserved)
        let minWeight: Float = 1.0
        guard corners.allSatisfy({ $0.weight >= minWeight }) else { return }

        // Check each edge for zero-crossing
        let edges: [(Int, Int)] = [
            (0,1), (1,2), (2,3), (3,0),  // bottom face
            (4,5), (5,6), (6,7), (7,4),  // top face
            (0,4), (1,5), (2,6), (3,7)   // vertical edges
        ]

        let cornerPositions: [SIMD3<Float>] = [
            worldPos(x, y, z), worldPos(x+1, y, z), worldPos(x+1, y+1, z), worldPos(x, y+1, z),
            worldPos(x, y, z+1), worldPos(x+1, y, z+1), worldPos(x+1, y+1, z+1), worldPos(x, y+1, z+1)
        ]

        for (i, j) in edges {
            let v0 = corners[i].tsdf
            let v1 = corners[j].tsdf

            // Surface crosses this edge (sign change)
            guard v0 * v1 < 0 else { continue }

            // Interpolate position along edge
            let t = v0 / (v0 - v1)
            let pos = cornerPositions[i] + t * (cornerPositions[j] - cornerPositions[i])

            // Interpolate color
            let c0 = corners[i]
            let c1 = corners[j]
            let r = c0.colorR + t * (c1.colorR - c0.colorR)
            let g = c0.colorG + t * (c1.colorG - c0.colorG)
            let b = c0.colorB + t * (c1.colorB - c0.colorB)

            // Calculate normal from TSDF gradient
            let normal = calculateGradient(at: pos)

            vertices.append(pos)
            normals.append(normal)
            colors.append(SIMD4<Float>(r, g, b, 1.0))
        }

        // Form triangles from the edge crossings (simplified - create triangle fans)
        let baseIdx = UInt32(vertices.count - vertices.count) // This needs proper marching cubes tables
        // For simplicity, group edge crossings into triangles
        let newVertCount = vertices.count
        let startIdx = newVertCount - edges.filter { corners[$0.0].tsdf * corners[$0.1].tsdf < 0 }.count

        if vertices.count - startIdx >= 3 {
            // Simple fan triangulation of the crossing points
            for i in stride(from: startIdx + 2, to: vertices.count, by: 1) {
                faces.append([UInt32(startIdx), UInt32(i - 1), UInt32(i)])
            }
        }
    }

    private func getVoxel(_ x: Int, _ y: Int, _ z: Int) -> Voxel {
        guard x >= 0 && x < resolutionX && y >= 0 && y < resolutionY && z >= 0 && z < resolutionZ else {
            return Voxel()
        }
        return grid[x + y * resolutionX + z * resolutionX * resolutionY]
    }

    private func worldPos(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Float> {
        return origin + SIMD3<Float>(Float(x), Float(y), Float(z)) * voxelSize
    }

    private func calculateGradient(at pos: SIMD3<Float>) -> SIMD3<Float> {
        let h = voxelSize * 0.5
        let dx = sampleTSDF(at: pos + SIMD3(h, 0, 0)) - sampleTSDF(at: pos - SIMD3(h, 0, 0))
        let dy = sampleTSDF(at: pos + SIMD3(0, h, 0)) - sampleTSDF(at: pos - SIMD3(0, h, 0))
        let dz = sampleTSDF(at: pos + SIMD3(0, 0, h)) - sampleTSDF(at: pos - SIMD3(0, 0, h))
        let grad = SIMD3<Float>(dx, dy, dz)
        let len = length(grad)
        return len > 0.0001 ? grad / len : SIMD3<Float>(0, 1, 0)
    }

    private func sampleTSDF(at pos: SIMD3<Float>) -> Float {
        let fx = (pos.x - origin.x) / voxelSize
        let fy = (pos.y - origin.y) / voxelSize
        let fz = (pos.z - origin.z) / voxelSize
        let ix = min(max(Int(fx), 0), resolutionX - 1)
        let iy = min(max(Int(fy), 0), resolutionY - 1)
        let iz = min(max(Int(fz), 0), resolutionZ - 1)
        return grid[ix + iy * resolutionX + iz * resolutionX * resolutionY].tsdf
    }
}

/// Applies depth fusion to produce a cleaner mesh from raw ARKit data
extension MeshProcessor {

    /// Fuse raw mesh through a voxel grid for cleaner results
    /// This is the key quality differentiator - produces continuous, smooth surfaces
    static func depthFusionProcess(_ meshData: MeshData, voxelSize: Float = 0.015) -> MeshData {
        guard meshData.vertexCount > 0 else { return meshData }

        // Determine appropriate voxel size based on mesh extent
        let extent = meshData.boundingBoxMax - meshData.boundingBoxMin
        let maxExtent = max(extent.x, max(extent.y, extent.z))

        // Clamp voxel size to prevent excessive memory usage
        // Max ~128^3 = ~2M voxels for safety
        let minVoxelSize = maxExtent / 128.0
        let effectiveVoxelSize = max(voxelSize, minVoxelSize)

        // Check if the grid would be too large (> 4M voxels)
        let estX = Int(ceil(extent.x / effectiveVoxelSize))
        let estY = Int(ceil(extent.y / effectiveVoxelSize))
        let estZ = Int(ceil(extent.z / effectiveVoxelSize))
        let estTotal = estX * estY * estZ
        if estTotal > 4_000_000 {
            // Too large for fusion, fall back to standard post-processing
            DebugLogger.shared.warn("Mesh too large for fusion (\(estTotal) voxels), using standard processing", category: "Mesh")
            return postProcess(meshData, level: .high)
        }

        DebugLogger.shared.info("Starting depth fusion: \(estX)x\(estY)x\(estZ) grid, voxel=\(effectiveVoxelSize)m", category: "Mesh")

        let fusion = DepthFusion(
            boundsMin: meshData.boundingBoxMin,
            boundsMax: meshData.boundingBoxMax,
            voxelSize: effectiveVoxelSize
        )

        // Integrate the mesh into the voxel grid
        fusion.integrateMesh(meshData)

        // Extract clean mesh
        var fusedMesh = fusion.extractMesh()

        // If fusion produced too few vertices (can happen), fall back
        if fusedMesh.vertexCount < meshData.vertexCount / 10 {
            DebugLogger.shared.warn("Fusion produced too few vertices (\(fusedMesh.vertexCount)), using standard processing", category: "Mesh")
            return postProcess(meshData, level: .high)
        }

        // Apply additional cleanup to the fused mesh
        fusedMesh = removeDegenerateTriangles(fusedMesh)
        fusedMesh = removeSmallComponents(fusedMesh, minVertices: 12)

        return fusedMesh
    }
}
