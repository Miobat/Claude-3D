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
        self.voxelSize = max(voxelSize, 0.005) // minimum 5mm voxels
        self.truncation = self.voxelSize * 4.0
        self.origin = boundsMin - SIMD3<Float>(self.voxelSize, self.voxelSize, self.voxelSize)

        let extent = boundsMax - boundsMin + SIMD3<Float>(self.voxelSize * 2, self.voxelSize * 2, self.voxelSize * 2)
        self.resolutionX = max(2, min(Int(ceil(extent.x / self.voxelSize)), 128))
        self.resolutionY = max(2, min(Int(ceil(extent.y / self.voxelSize)), 128))
        self.resolutionZ = max(2, min(Int(ceil(extent.z / self.voxelSize)), 128))

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

    // MARK: - Extract Mesh (Surface Nets)

    /// Extract a clean mesh using surface nets - simpler and more robust than marching cubes
    func extractMesh() -> MeshData {
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var faces: [[UInt32]] = []
        var colors: [SIMD4<Float>] = []

        // Surface nets: place one vertex per cell that contains a sign change,
        // then connect adjacent cells with quads/triangles

        // Step 1: Find cells with sign changes and place a vertex at the average edge crossing
        var cellVertexIndex = [Int: Int]() // cell flat index -> vertex index

        for z in 0..<(resolutionZ - 1) {
            for y in 0..<(resolutionY - 1) {
                for x in 0..<(resolutionX - 1) {
                    let v000 = getVoxel(x, y, z)
                    guard v000.weight > 0.5 else { continue }

                    // Check the 3 edges from this corner (x+1, y+1, z+1)
                    let neighbors = [
                        getVoxel(x+1, y, z),
                        getVoxel(x, y+1, z),
                        getVoxel(x, y, z+1)
                    ]

                    var hasSignChange = false
                    for n in neighbors {
                        if n.weight > 0.5 && v000.tsdf * n.tsdf < 0 {
                            hasSignChange = true
                            break
                        }
                    }
                    guard hasSignChange else { continue }

                    // Place vertex at cell center (simple but effective)
                    let pos = SIMD3<Float>(
                        origin.x + (Float(x) + 0.5) * voxelSize,
                        origin.y + (Float(y) + 0.5) * voxelSize,
                        origin.z + (Float(z) + 0.5) * voxelSize
                    )

                    let normal = calculateGradient(at: pos)
                    let color = SIMD4<Float>(v000.colorR, v000.colorG, v000.colorB, 1.0)

                    let idx = vertices.count
                    let cellKey = x + y * resolutionX + z * resolutionX * resolutionY
                    cellVertexIndex[cellKey] = idx
                    vertices.append(pos)
                    normals.append(normal)
                    colors.append(color)
                }
            }
        }

        // Step 2: Connect adjacent cells with triangles
        for z in 0..<(resolutionZ - 1) {
            for y in 0..<(resolutionY - 1) {
                for x in 0..<(resolutionX - 1) {
                    let cellKey = x + y * resolutionX + z * resolutionX * resolutionY

                    guard let v0 = cellVertexIndex[cellKey] else { continue }

                    // Check X-edge: connect (x,y,z) with (x, y+1, z), (x, y, z+1), (x, y+1, z+1)
                    let voxHere = getVoxel(x, y, z)
                    let voxX = getVoxel(x+1, y, z)
                    if voxHere.weight > 0.5 && voxX.weight > 0.5 && voxHere.tsdf * voxX.tsdf < 0 {
                        let k1 = x + (y+1) * resolutionX + z * resolutionX * resolutionY
                        let k2 = x + y * resolutionX + (z+1) * resolutionX * resolutionY
                        let k3 = x + (y+1) * resolutionX + (z+1) * resolutionX * resolutionY
                        if let v1 = cellVertexIndex[k1], let v2 = cellVertexIndex[k2], let v3 = cellVertexIndex[k3] {
                            faces.append([UInt32(v0), UInt32(v1), UInt32(v3)])
                            faces.append([UInt32(v0), UInt32(v3), UInt32(v2)])
                        }
                    }

                    // Check Y-edge
                    let voxY = getVoxel(x, y+1, z)
                    if voxHere.weight > 0.5 && voxY.weight > 0.5 && voxHere.tsdf * voxY.tsdf < 0 {
                        let k1 = (x+1) + y * resolutionX + z * resolutionX * resolutionY
                        let k2 = x + y * resolutionX + (z+1) * resolutionX * resolutionY
                        let k3 = (x+1) + y * resolutionX + (z+1) * resolutionX * resolutionY
                        if let v1 = cellVertexIndex[k1], let v2 = cellVertexIndex[k2], let v3 = cellVertexIndex[k3] {
                            faces.append([UInt32(v0), UInt32(v2), UInt32(v3)])
                            faces.append([UInt32(v0), UInt32(v3), UInt32(v1)])
                        }
                    }

                    // Check Z-edge
                    let voxZ = getVoxel(x, y, z+1)
                    if voxHere.weight > 0.5 && voxZ.weight > 0.5 && voxHere.tsdf * voxZ.tsdf < 0 {
                        let k1 = (x+1) + y * resolutionX + z * resolutionX * resolutionY
                        let k2 = x + (y+1) * resolutionX + z * resolutionX * resolutionY
                        let k3 = (x+1) + (y+1) * resolutionX + z * resolutionX * resolutionY
                        if let v1 = cellVertexIndex[k1], let v2 = cellVertexIndex[k2], let v3 = cellVertexIndex[k3] {
                            faces.append([UInt32(v0), UInt32(v1), UInt32(v3)])
                            faces.append([UInt32(v0), UInt32(v3), UInt32(v2)])
                        }
                    }
                }
            }
        }

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
    static func depthFusionProcess(_ meshData: MeshData, voxelSize: Float = 0.015) -> MeshData {
        // Need meaningful mesh data for fusion to work
        guard meshData.vertexCount >= 100 else {
            DebugLogger.shared.warn("Too few vertices for fusion (\(meshData.vertexCount)), using high quality processing", category: "Mesh")
            return postProcess(meshData, level: .high)
        }

        let extent = meshData.boundingBoxMax - meshData.boundingBoxMin
        let maxExtent = max(extent.x, max(extent.y, extent.z))

        // Skip if extent is invalid or too small
        guard maxExtent > 0.05 && maxExtent < 100.0 else {
            DebugLogger.shared.warn("Invalid mesh extent (\(maxExtent)m), using high quality processing", category: "Mesh")
            return postProcess(meshData, level: .high)
        }

        // Auto-calculate voxel size: aim for ~80^3 grid max
        let autoVoxelSize = maxExtent / 80.0
        let effectiveVoxelSize = max(max(voxelSize, autoVoxelSize), 0.01)

        let estX = Int(ceil(extent.x / effectiveVoxelSize)) + 2
        let estY = Int(ceil(extent.y / effectiveVoxelSize)) + 2
        let estZ = Int(ceil(extent.z / effectiveVoxelSize)) + 2
        let estTotal = estX * estY * estZ

        if estTotal > 2_000_000 {
            DebugLogger.shared.warn("Grid too large (\(estTotal) voxels), using high quality processing", category: "Mesh")
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
