import Foundation
import SceneKit
import RealityKit
#if !targetEnvironment(simulator)
import ARKit
#endif

/// Processes raw mesh data into displayable and exportable formats
class MeshProcessor {

    // MARK: - Post-Processing Pipeline

    /// Full post-processing pipeline to clean up raw scan data
    static func postProcess(_ meshData: MeshData, level: ProcessingLevel = .standard) -> MeshData {
        var result = meshData

        switch level {
        case .quick:
            result = removeDegenerateTriangles(result)
            result = weldNearbyVertices(result, threshold: 0.005)
            result = removeSmallComponents(result, minVertices: 30)
            result = recalculateNormals(result)
        case .standard:
            result = removeDegenerateTriangles(result)
            result = weldNearbyVertices(result, threshold: 0.01)
            result = removeSmallComponents(result, minVertices: 80)
            result = recalculateNormals(result)
            result = smoothVertexPositions(result, iterations: 1, factor: 0.3)
            result = smoothNormals(result)
        case .high:
            result = removeDegenerateTriangles(result)
            result = weldNearbyVertices(result, threshold: 0.015)
            result = removeSmallComponents(result, minVertices: 150)
            result = recalculateNormals(result)
            result = smoothVertexPositions(result, iterations: 3, factor: 0.4)
            result = smoothNormals(result)
        }

        return result
    }

    enum ProcessingLevel: String, CaseIterable {
        case quick = "Quick"
        case standard = "Standard"
        case high = "High Quality"

        var description: String {
            switch self {
            case .quick: return "Light cleanup, fastest"
            case .standard: return "Clean mesh, remove debris, smooth"
            case .high: return "Aggressive cleanup, very smooth surfaces"
            }
        }

        var icon: String {
            switch self {
            case .quick: return "hare"
            case .standard: return "wand.and.stars"
            case .high: return "sparkles"
            }
        }
    }

    // MARK: - Remove Degenerate Triangles

    /// Remove triangles with zero or near-zero area
    static func removeDegenerateTriangles(_ meshData: MeshData, minArea: Float = 0.0000001) -> MeshData {
        var validFaces: [[UInt32]] = []

        for face in meshData.faces {
            guard face.count == 3 else { continue }
            let i0 = Int(face[0]), i1 = Int(face[1]), i2 = Int(face[2])
            guard i0 < meshData.vertices.count && i1 < meshData.vertices.count && i2 < meshData.vertices.count else { continue }

            // Check for duplicate indices
            guard i0 != i1 && i1 != i2 && i0 != i2 else { continue }

            let v0 = meshData.vertices[i0]
            let v1 = meshData.vertices[i1]
            let v2 = meshData.vertices[i2]

            // Calculate triangle area using cross product
            let edge1 = v1 - v0
            let edge2 = v2 - v0
            let crossProduct = cross(edge1, edge2)
            let area = length(crossProduct) * 0.5

            if area > minArea {
                validFaces.append(face)
            }
        }

        return MeshData(
            vertices: meshData.vertices,
            normals: meshData.normals,
            faces: validFaces,
            colors: meshData.colors,
            boundingBoxMin: meshData.boundingBoxMin,
            boundingBoxMax: meshData.boundingBoxMax
        )
    }

    // MARK: - Weld Nearby Vertices

    /// Merge vertices that are very close together to reduce fragmentation
    static func weldNearbyVertices(_ meshData: MeshData, threshold: Float = 0.002) -> MeshData {
        guard !meshData.vertices.isEmpty else { return meshData }

        let count = meshData.vertices.count
        var vertexMap = [Int](repeating: -1, count: count)
        var newVertices: [SIMD3<Float>] = []
        var newNormals: [SIMD3<Float>] = []
        var newColors: [SIMD4<Float>] = []

        let thresholdSq = threshold * threshold

        // Simple spatial bucketing for performance
        let bucketSize: Float = threshold * 10
        var buckets: [SIMD3<Int32>: [Int]] = [:]

        for i in 0..<count {
            let v = meshData.vertices[i]
            let bx = Int32(floor(v.x / bucketSize))
            let by = Int32(floor(v.y / bucketSize))
            let bz = Int32(floor(v.z / bucketSize))
            let key = SIMD3<Int32>(bx, by, bz)

            var merged = false

            // Check neighboring buckets
            for dx: Int32 in -1...1 {
                for dy: Int32 in -1...1 {
                    for dz: Int32 in -1...1 {
                        let neighborKey = SIMD3<Int32>(bx + dx, by + dy, bz + dz)
                        if let neighborIndices = buckets[neighborKey] {
                            for ni in neighborIndices {
                                let nv = newVertices[ni]
                                let diff = v - nv
                                if dot(diff, diff) < thresholdSq {
                                    vertexMap[i] = ni
                                    merged = true
                                    break
                                }
                            }
                        }
                        if merged { break }
                    }
                    if merged { break }
                }
                if merged { break }
            }

            if !merged {
                let newIdx = newVertices.count
                vertexMap[i] = newIdx
                newVertices.append(v)
                newNormals.append(i < meshData.normals.count ? meshData.normals[i] : SIMD3<Float>(0, 1, 0))
                newColors.append(i < meshData.colors.count ? meshData.colors[i] : SIMD4<Float>(0.7, 0.7, 0.7, 1.0))

                if buckets[key] == nil { buckets[key] = [] }
                buckets[key]!.append(newIdx)
            }
        }

        // Remap faces
        var newFaces: [[UInt32]] = []
        for face in meshData.faces {
            let mapped = face.map { UInt32(vertexMap[Int($0)]) }
            // Skip degenerate faces after welding
            if mapped.count == 3 && mapped[0] != mapped[1] && mapped[1] != mapped[2] && mapped[0] != mapped[2] {
                newFaces.append(mapped)
            }
        }

        return MeshData(
            vertices: newVertices,
            normals: newNormals,
            faces: newFaces,
            colors: newColors,
            boundingBoxMin: meshData.boundingBoxMin,
            boundingBoxMax: meshData.boundingBoxMax
        )
    }

    // MARK: - Remove Small Disconnected Components

    /// Remove small floating mesh fragments
    static func removeSmallComponents(_ meshData: MeshData, minVertices: Int = 8) -> MeshData {
        let vertexCount = meshData.vertices.count
        guard vertexCount > 0 else { return meshData }

        // Build adjacency: which vertices connect to which
        var adjacency = [[Int]](repeating: [], count: vertexCount)
        for face in meshData.faces {
            for i in 0..<face.count {
                for j in (i+1)..<face.count {
                    let a = Int(face[i]), b = Int(face[j])
                    if a < vertexCount && b < vertexCount {
                        adjacency[a].append(b)
                        adjacency[b].append(a)
                    }
                }
            }
        }

        // Find connected components using BFS
        var componentId = [Int](repeating: -1, count: vertexCount)
        var componentSizes: [Int] = []
        var currentComponent = 0

        for start in 0..<vertexCount {
            if componentId[start] >= 0 { continue }

            var queue = [start]
            var queueIdx = 0
            componentId[start] = currentComponent
            var size = 0

            while queueIdx < queue.count {
                let v = queue[queueIdx]
                queueIdx += 1
                size += 1

                for neighbor in adjacency[v] {
                    if componentId[neighbor] < 0 {
                        componentId[neighbor] = currentComponent
                        queue.append(neighbor)
                    }
                }
            }

            componentSizes.append(size)
            currentComponent += 1
        }

        // Find components large enough to keep
        let keepComponents = Set(componentSizes.enumerated()
            .filter { $0.element >= minVertices }
            .map { $0.offset })

        // Build vertex remap for kept vertices
        var vertexRemap = [Int](repeating: -1, count: vertexCount)
        var newVertices: [SIMD3<Float>] = []
        var newNormals: [SIMD3<Float>] = []
        var newColors: [SIMD4<Float>] = []

        for i in 0..<vertexCount {
            if keepComponents.contains(componentId[i]) {
                vertexRemap[i] = newVertices.count
                newVertices.append(meshData.vertices[i])
                newNormals.append(i < meshData.normals.count ? meshData.normals[i] : SIMD3<Float>(0, 1, 0))
                newColors.append(i < meshData.colors.count ? meshData.colors[i] : SIMD4<Float>(0.7, 0.7, 0.7, 1.0))
            }
        }

        // Remap faces
        var newFaces: [[UInt32]] = []
        for face in meshData.faces {
            let allKept = face.allSatisfy { vertexRemap[Int($0)] >= 0 }
            if allKept {
                newFaces.append(face.map { UInt32(vertexRemap[Int($0)]) })
            }
        }

        // Recalculate bounding box
        var minB = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxB = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        for v in newVertices {
            minB = min(minB, v)
            maxB = max(maxB, v)
        }

        return MeshData(
            vertices: newVertices,
            normals: newNormals,
            faces: newFaces,
            colors: newColors,
            boundingBoxMin: newVertices.isEmpty ? meshData.boundingBoxMin : minB,
            boundingBoxMax: newVertices.isEmpty ? meshData.boundingBoxMax : maxB
        )
    }

    // MARK: - Recalculate Normals

    /// Recalculate face normals and smooth them per-vertex
    static func recalculateNormals(_ meshData: MeshData) -> MeshData {
        var normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: meshData.vertices.count)

        for face in meshData.faces {
            guard face.count == 3 else { continue }
            let i0 = Int(face[0]), i1 = Int(face[1]), i2 = Int(face[2])
            guard i0 < meshData.vertices.count && i1 < meshData.vertices.count && i2 < meshData.vertices.count else { continue }

            let v0 = meshData.vertices[i0]
            let v1 = meshData.vertices[i1]
            let v2 = meshData.vertices[i2]

            let faceNormal = cross(v1 - v0, v2 - v0) // Not normalized - weighted by area
            normals[i0] += faceNormal
            normals[i1] += faceNormal
            normals[i2] += faceNormal
        }

        // Normalize
        for i in 0..<normals.count {
            let len = length(normals[i])
            if len > 0.0001 {
                normals[i] /= len
            } else {
                normals[i] = SIMD3<Float>(0, 1, 0)
            }
        }

        return MeshData(
            vertices: meshData.vertices,
            normals: normals,
            faces: meshData.faces,
            colors: meshData.colors,
            boundingBoxMin: meshData.boundingBoxMin,
            boundingBoxMax: meshData.boundingBoxMax
        )
    }

    // MARK: - Smooth Normals

    /// Smooth normals by averaging with neighbors
    static func smoothNormals(_ meshData: MeshData) -> MeshData {
        var adjacency = [[Int]](repeating: [], count: meshData.vertices.count)
        for face in meshData.faces {
            for i in 0..<face.count {
                for j in (i+1)..<face.count {
                    let a = Int(face[i]), b = Int(face[j])
                    adjacency[a].append(b)
                    adjacency[b].append(a)
                }
            }
        }

        var smoothed = meshData.normals
        for i in 0..<smoothed.count {
            var avg = smoothed[i]
            for neighbor in adjacency[i] {
                if neighbor < smoothed.count {
                    avg += smoothed[neighbor]
                }
            }
            let len = length(avg)
            if len > 0.0001 { smoothed[i] = avg / len }
        }

        return MeshData(
            vertices: meshData.vertices,
            normals: smoothed,
            faces: meshData.faces,
            colors: meshData.colors,
            boundingBoxMin: meshData.boundingBoxMin,
            boundingBoxMax: meshData.boundingBoxMax
        )
    }

    // MARK: - Smooth Vertex Positions (Laplacian Smoothing)

    /// Move each vertex toward the average of its neighbors to smooth the mesh surface
    static func smoothVertexPositions(_ meshData: MeshData, iterations: Int = 2, factor: Float = 0.3) -> MeshData {
        var positions = meshData.vertices
        var colors = meshData.colors

        // Build adjacency
        var adjacency = [[Int]](repeating: [], count: positions.count)
        for face in meshData.faces {
            for i in 0..<face.count {
                for j in (i+1)..<face.count {
                    let a = Int(face[i]), b = Int(face[j])
                    if a < positions.count && b < positions.count {
                        adjacency[a].append(b)
                        adjacency[b].append(a)
                    }
                }
            }
        }

        for _ in 0..<iterations {
            var newPositions = positions
            var newColors = colors

            for i in 0..<positions.count {
                let neighbors = adjacency[i]
                guard !neighbors.isEmpty else { continue }

                // Average neighbor positions
                var avgPos = SIMD3<Float>(0, 0, 0)
                var avgColor = SIMD4<Float>(0, 0, 0, 0)
                for n in neighbors {
                    avgPos += positions[n]
                    if n < colors.count { avgColor += colors[n] }
                }
                avgPos /= Float(neighbors.count)
                avgColor /= Float(neighbors.count)

                // Move vertex toward average by factor
                newPositions[i] = positions[i] + (avgPos - positions[i]) * factor
                if i < colors.count && !colors.isEmpty {
                    newColors[i] = colors[i] + (avgColor - colors[i]) * factor * 0.5
                }
            }

            positions = newPositions
            colors = newColors
        }

        // Recalculate bounding box
        var minB = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxB = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        for v in positions { minB = min(minB, v); maxB = max(maxB, v) }

        return MeshData(
            vertices: positions,
            normals: meshData.normals,
            faces: meshData.faces,
            colors: colors,
            boundingBoxMin: minB,
            boundingBoxMax: maxB
        )
    }

    // MARK: - SceneKit Conversion

    /// Convert MeshData to a SceneKit node for viewing
    static func createSceneKitNode(from meshData: MeshData, withColors: Bool = true) -> SCNNode {
        let vertices = meshData.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
        let normals = meshData.normals.map { SCNVector3($0.x, $0.y, $0.z) }

        let vertexSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)

        var sources = [vertexSource, normalSource]
        if withColors && !meshData.colors.isEmpty {
            let colorData = Data(bytes: meshData.colors, count: meshData.colors.count * MemoryLayout<SIMD4<Float>>.stride)
            let colorSource = SCNGeometrySource(
                data: colorData,
                semantic: .color,
                vectorCount: meshData.colors.count,
                usesFloatComponents: true,
                componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SIMD4<Float>>.stride
            )
            sources.append(colorSource)
        }

        var indices: [UInt32] = []
        for face in meshData.faces {
            indices.append(contentsOf: face)
        }

        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: meshData.faceCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: sources, elements: [element])

        let material = SCNMaterial()
        material.isDoubleSided = true
        material.lightingModel = .physicallyBased
        material.diffuse.contents = withColors && !meshData.colors.isEmpty ? UIColor.white : UIColor(white: 0.8, alpha: 1.0)
        material.roughness.contents = 0.6
        material.metalness.contents = 0.1

        geometry.materials = [material]

        return SCNNode(geometry: geometry)
    }

    /// Build a UV-textured SceneKit node from a baked atlas.
    /// Vertices are expanded per-face-corner so each triangle carries its own UVs.
    static func createTexturedNode(from meshData: MeshData, baked: BakedTexture) -> SCNNode {
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []
        positions.reserveCapacity(meshData.faceCount * 3)
        normals.reserveCapacity(meshData.faceCount * 3)
        uvs.reserveCapacity(meshData.faceCount * 3)

        let normalCount = meshData.normals.count
        for (fi, face) in meshData.faces.enumerated() {
            guard face.count == 3 else { continue }
            for k in 0..<3 {
                let vi = Int(face[k])
                guard vi < meshData.vertices.count else { continue }
                let v = meshData.vertices[vi]
                positions.append(SCNVector3(v.x, v.y, v.z))
                let n = vi < normalCount ? meshData.normals[vi] : SIMD3<Float>(0, 1, 0)
                normals.append(SCNVector3(n.x, n.y, n.z))
                let uvIdx = fi * 3 + k
                let uv = uvIdx < baked.cornerUVs.count ? baked.cornerUVs[uvIdx] : SIMD2<Float>(0, 0)
                uvs.append(CGPoint(x: CGFloat(uv.x), y: CGFloat(uv.y)))
            }
        }

        let vertexSource = SCNGeometrySource(vertices: positions)
        let normalSource = SCNGeometrySource(normals: normals)
        let uvSource = SCNGeometrySource(textureCoordinates: uvs)

        let indices = Array(0..<UInt32(positions.count))
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)

        let geometry = SCNGeometry(sources: [vertexSource, normalSource, uvSource], elements: [element])

        let material = SCNMaterial()
        material.isDoubleSided = true
        // Unlit so the baked photo texture shows true-to-photo (Street-View style),
        // not darkened/relit by scene lighting.
        material.lightingModel = .constant
        material.diffuse.contents = baked.atlasImage
        material.diffuse.magnificationFilter = .linear
        material.diffuse.minificationFilter = .linear
        // Nearest mip avoids cross-cell color bleed in the packed atlas.
        material.diffuse.mipFilter = .nearest
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        geometry.materials = [material]

        return SCNNode(geometry: geometry)
    }

    // MARK: - Voxel Downsampling (accuracy / detail control)

    /// Downsample a colored point set to one averaged point per cubic voxel of
    /// `leafSize` meters. Larger leaf = coarser grid = far fewer points (faster,
    /// lighter); smaller leaf = denser/heavier. Used by the pre-scan accuracy
    /// slider (5mm fine … 20mm coarse). Produces a point cloud (faces removed).
    static func voxelDownsamplePoints(_ meshData: MeshData, leafSize: Float) -> MeshData {
        guard leafSize > 0, !meshData.vertices.isEmpty else { return meshData }

        struct Accum {
            var p = SIMD3<Float>(repeating: 0)
            var c = SIMD4<Float>(repeating: 0)
            var n = SIMD3<Float>(repeating: 0)
            var count: Float = 0
        }

        var voxels: [SIMD3<Int32>: Accum] = [:]
        voxels.reserveCapacity(meshData.vertices.count / 4 + 1)

        let inv = 1.0 / leafSize
        let hasColor = !meshData.colors.isEmpty
        let hasNormal = !meshData.normals.isEmpty

        for i in 0..<meshData.vertices.count {
            let v = meshData.vertices[i]
            let key = SIMD3<Int32>(
                Int32(floor(v.x * inv)),
                Int32(floor(v.y * inv)),
                Int32(floor(v.z * inv))
            )
            var acc = voxels[key] ?? Accum()
            acc.p += v
            if hasColor && i < meshData.colors.count { acc.c += meshData.colors[i] }
            if hasNormal && i < meshData.normals.count { acc.n += meshData.normals[i] }
            acc.count += 1
            voxels[key] = acc
        }

        var newVertices: [SIMD3<Float>] = []
        var newColors: [SIMD4<Float>] = []
        var newNormals: [SIMD3<Float>] = []
        newVertices.reserveCapacity(voxels.count)

        var minB = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxB = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        for (_, acc) in voxels {
            let p = acc.p / acc.count
            newVertices.append(p)
            if hasColor {
                var c = acc.c / acc.count
                c.w = 1.0
                newColors.append(c)
            }
            if hasNormal {
                let n = acc.n / acc.count
                newNormals.append(length(n) > 1e-6 ? normalize(n) : SIMD3<Float>(0, 1, 0))
            }
            minB = min(minB, p)
            maxB = max(maxB, p)
        }

        return MeshData(
            vertices: newVertices,
            normals: newNormals,
            faces: [],
            colors: newColors,
            boundingBoxMin: minB,
            boundingBoxMax: maxB
        )
    }

    /// Replace all per-vertex colors with a uniform neutral grey. Used by the
    /// Fast "no color" option to produce a clean grey mesh for measuring / CAD
    /// export instead of the muddy per-vertex coloring.
    static func makeUniformGrey(_ meshData: MeshData, grey: Float = 0.8) -> MeshData {
        let g = SIMD4<Float>(grey, grey, grey, 1.0)
        return MeshData(
            vertices: meshData.vertices,
            normals: meshData.normals,
            faces: meshData.faces,
            colors: [SIMD4<Float>](repeating: g, count: meshData.vertices.count),
            boundingBoxMin: meshData.boundingBoxMin,
            boundingBoxMax: meshData.boundingBoxMax
        )
    }

    /// Build a colored point-cloud SceneKit node (Path C foundation / splat init).
    static func createPointCloudNode(from meshData: MeshData) -> SCNNode {
        let vertices = meshData.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
        let vertexSource = SCNGeometrySource(vertices: vertices)

        var sources = [vertexSource]
        if !meshData.colors.isEmpty {
            let colorData = Data(bytes: meshData.colors, count: meshData.colors.count * MemoryLayout<SIMD4<Float>>.stride)
            let colorSource = SCNGeometrySource(
                data: colorData,
                semantic: .color,
                vectorCount: meshData.colors.count,
                usesFloatComponents: true,
                componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SIMD4<Float>>.stride
            )
            sources.append(colorSource)
        }

        let indices = Array(0..<UInt32(vertices.count))
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        element.pointSize = 6
        element.minimumPointScreenSpaceRadius = 2
        element.maximumPointScreenSpaceRadius = 8

        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]

        return SCNNode(geometry: geometry)
    }

    /// Create a SceneKit node from an OBJ file URL
    static func createSceneKitNode(fromOBJ url: URL) -> SCNNode? {
        do {
            let scene = try SCNScene(url: url, options: [
                .checkConsistency: true,
                SCNSceneSource.LoadingOption.flattenScene: true
            ])

            let containerNode = SCNNode()
            for child in scene.rootNode.childNodes {
                let cloned = child.clone()
                // Ensure all materials are double-sided
                cloned.enumerateChildNodes { node, _ in
                    node.geometry?.materials.forEach { mat in
                        mat.isDoubleSided = true
                    }
                }
                cloned.geometry?.materials.forEach { mat in
                    mat.isDoubleSided = true
                }
                containerNode.addChildNode(cloned)
            }

            return containerNode
        } catch {
            DebugLogger.shared.error("Error loading OBJ: \(error)", category: "Mesh")
            return nil
        }
    }

    #if !targetEnvironment(simulator)
    // MARK: - Point Cloud from Depth

    static func createPointCloud(from frame: ARFrame) -> [SIMD3<Float>]? {
        guard let depthMap = frame.sceneDepth?.depthMap ?? frame.smoothedSceneDepth?.depthMap else {
            return nil
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let intrinsics = frame.camera.intrinsics
        let cameraTransform = frame.camera.transform

        var points: [SIMD3<Float>] = []

        let step = 4
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let depthPointer = baseAddress.advanced(by: y * bytesPerRow + x * MemoryLayout<Float32>.size)
                let depth = depthPointer.assumingMemoryBound(to: Float32.self).pointee

                guard depth > 0 && depth < 5.0 else { continue }

                let fx = intrinsics[0][0]
                let fy = intrinsics[1][1]
                let cx = intrinsics[2][0]
                let cy = intrinsics[2][1]

                let xWorld = (Float(x) - cx) * depth / fx
                let yWorld = (Float(y) - cy) * depth / fy
                let localPoint = SIMD4<Float>(xWorld, yWorld, depth, 1.0)

                let worldPoint = cameraTransform * localPoint
                points.append(SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z))
            }
        }

        return points
    }
    #endif

    // MARK: - Bounding Box

    static func calculateBoundingBox(for node: SCNNode) -> (min: SCNVector3, max: SCNVector3) {
        let (minVec, maxVec) = node.boundingBox
        return (minVec, maxVec)
    }

    static func calculateCenter(min: SCNVector3, max: SCNVector3) -> SCNVector3 {
        return SCNVector3(
            (min.x + max.x) / 2.0,
            (min.y + max.y) / 2.0,
            (min.z + max.z) / 2.0
        )
    }

    static func calculateViewDistance(min: SCNVector3, max: SCNVector3) -> Float {
        let size = SCNVector3(max.x - min.x, max.y - min.y, max.z - min.z)
        let maxDimension = Swift.max(size.x, Swift.max(size.y, size.z))
        return maxDimension * 2.0
    }
}

// MARK: - Path B: On-Device Photogrammetry

#if !targetEnvironment(simulator)
/// Reconstructs a dense, textured USDZ from a folder of full-resolution photos
/// using Apple's on-device PhotogrammetrySession. Supported on iPhone 12 Pro and
/// later (Pro models). Always gate calls with `isSupported`.
enum PhotogrammetryProcessor {

    static var isSupported: Bool {
        PhotogrammetrySession.isSupported
    }

    enum ProcessError: Error, LocalizedError {
        case notSupported
        case noImages
        var errorDescription: String? {
            switch self {
            case .notSupported: return "High-quality reconstruction isn't supported on this device."
            case .noImages: return "Not enough photos were captured for reconstruction."
            }
        }
    }

    /// Turn a raw PhotogrammetrySession failure into actionable guidance.
    /// Error code 6 == "alignment failed": the system couldn't work out the
    /// camera positions, almost always due to too little overlap / texture.
    static func friendlyMessage(for error: Error) -> String {
        if let pe = error as? ProcessError { return pe.errorDescription ?? "\(error)" }
        let ns = error as NSError
        if ns.code == 6 {
            return "Couldn't align the photos into a 3D model. This usually means the photos didn't overlap enough.\n\nTips: move slowly and keep the subject 1–2 m away, circle it with lots of overlap between shots, use good even lighting, and avoid blank/shiny surfaces (plain walls, glass). Then scan again."
        }
        return "Reconstruction failed: \(error.localizedDescription)"
    }

    /// On-device reconstruction effort. iOS caps mesh detail at `.reduced`
    /// (Apple limitation; `.medium`/`.full` are macOS-only), so this only trades
    /// feature-matching sensitivity for speed — not a detail tier. We never drop
    /// photos: reducing frame overlap is the #1 cause of alignment failures
    /// (PhotogrammetrySession error 6).
    enum Quality {
        case draft   // normal sensitivity — faster, slightly more failure-prone
        case best    // high sensitivity — slower, most robust alignment + detail
    }

    /// Reconstruct a textured USDZ from a folder of images.
    /// `progress` is called with values in 0...1 as the session works.
    static func reconstruct(
        inputFolder: URL,
        outputUSDZ: URL,
        quality: Quality = .best,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard isSupported else { throw ProcessError.notSupported }

        // iOS on-device PhotogrammetrySession only supports .reduced detail
        // (.medium/.full/.raw are macOS-only). For higher detail, use the
        // Splat (Desktop) export or cloud.
        let requestDetail: PhotogrammetrySession.Request.Detail = .reduced

        let allImages = (try? FileManager.default.contentsOfDirectory(atPath: inputFolder.path)) ?? []
        let imageCount = allImages.filter {
            let l = $0.lowercased()
            return l.hasSuffix(".jpg") || l.hasSuffix(".jpeg") || l.hasSuffix(".heic")
        }.count
        guard imageCount >= 3 else { throw ProcessError.noImages }

        var configuration = PhotogrammetrySession.Configuration()
        configuration.sampleOrdering = .sequential
        // .high finds more feature tracks → more robust alignment; .normal is
        // faster but likelier to fail on sparse-texture scenes.
        configuration.featureSensitivity = (quality == .best) ? .high : .normal

        let session = try PhotogrammetrySession(input: inputFolder, configuration: configuration)
        try session.process(requests: [
            .modelFile(url: outputUSDZ, detail: requestDetail)
        ])

        for try await output in session.outputs {
            switch output {
            case .requestProgress(_, let fraction):
                progress(fraction)
            case .requestComplete:
                progress(1.0)
            case .processingComplete:
                return
            case .requestError(_, let error):
                throw error
            default:
                continue
            }
        }
    }
}
#endif

// MARK: - Splat Desktop Export (Path C, no cloud)

/// Packages a scan's posed photos + point cloud into a bundle a desktop Gaussian-
/// splat tool can train from directly. Because ARKit supplies camera poses, the
/// desktop side can skip COLMAP entirely.
enum SplatExporter {

    /// Write transforms.json (instant-ngp/nerfstudio convention), points3D.ply,
    /// and a README into the folder that already holds the captured frames.
    static func writeBundle(imageFolder: URL, poses: [CapturedPose], pointCloud: MeshData?) {
        if let first = poses.first {
            let fx = Double(first.intrinsics[0][0])
            let fy = Double(first.intrinsics[1][1])
            let cx = Double(first.intrinsics[2][0])
            let cy = Double(first.intrinsics[2][1])

            var frames: [[String: Any]] = []
            for p in poses {
                let m = p.transform
                // row-major 4x4: element(row r, col c) = m[c][r]
                var rows: [[Double]] = []
                for r in 0..<4 {
                    rows.append([Double(m[0][r]), Double(m[1][r]), Double(m[2][r]), Double(m[3][r])])
                }
                frames.append([
                    "file_path": String(format: "frame_%04d.jpg", p.index),
                    "transform_matrix": rows
                ])
            }

            let root: [String: Any] = [
                "camera_model": "OPENCV",
                "fl_x": fx, "fl_y": fy, "cx": cx, "cy": cy,
                "w": first.width, "h": first.height,
                "aabb_scale": 16,
                "ply_file_path": "points3D.ply",
                "frames": frames
            ]
            if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) {
                try? data.write(to: imageFolder.appendingPathComponent("transforms.json"))
            }
        }

        if let cloud = pointCloud, !cloud.vertices.isEmpty {
            _ = try? OBJExporter.exportPointCloudPLY(meshData: cloud, fileName: "points3D", directory: imageFolder)
        }

        let readme = """
        ScanView 3D — Gaussian Splat capture bundle
        ===========================================

        Contents:
          frame_XXXX.jpg     Captured photos (full resolution)
          transforms.json    Camera intrinsics + per-image poses
                             (instant-ngp / Nerfstudio convention, OpenGL axes)
          points3D.ply       LiDAR colored point cloud (use as init)

        Poses are included from ARKit, so you can SKIP COLMAP / structure-from-motion.

        Train a Gaussian splat on your computer, e.g.:
          • Nerfstudio:  ns-train splatfacto --data <thisFolder>
          • Postshot:    import transforms.json (poses are read directly)
          • gsplat / inria 3DGS: convert transforms.json to your loader, init from points3D.ply

        Tip: if a tool expects the opposite handedness, flip the Y and Z axes of each
        transform_matrix.
        """
        try? readme.write(to: imageFolder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    }

    /// Zip the bundle folder for sharing (uses the documented NSFileCoordinator trick).
    static func zip(folder: URL) -> URL? {
        let coordinator = NSFileCoordinator()
        var nsError: NSError?
        var result: URL?
        coordinator.coordinate(readingItemAt: folder, options: [.forUploading], error: &nsError) { zipURL in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(folder.lastPathComponent + "_splat.zip")
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: zipURL, to: dest)) != nil {
                result = dest
            }
        }
        return result
    }
}
