import Foundation
import SceneKit
#if !targetEnvironment(simulator)
import ARKit
#endif

/// Processes raw mesh data into displayable and exportable formats
class MeshProcessor {

    // MARK: - Mesh Simplification

    /// Simplify mesh by merging nearby vertices
    static func simplifyMesh(_ meshData: MeshData, targetReduction: Float = 0.5) -> MeshData {
        // For now, return the original mesh
        // Full mesh simplification (quadric error decimation) is complex
        // and can be added as an enhancement
        return meshData
    }

    // MARK: - SceneKit Conversion

    /// Convert MeshData to a SceneKit node for viewing
    static func createSceneKitNode(from meshData: MeshData, withColors: Bool = true) -> SCNNode {
        let vertices = meshData.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
        let normals = meshData.normals.map { SCNVector3($0.x, $0.y, $0.z) }

        // Create geometry sources
        let vertexSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)

        // Create color source if available
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

        // Create index data for faces
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

        // Create geometry
        let geometry = SCNGeometry(sources: sources, elements: [element])

        // Apply default material
        let material = SCNMaterial()
        material.isDoubleSided = true
        material.lightingModel = .physicallyBased

        if withColors && !meshData.colors.isEmpty {
            material.diffuse.contents = UIColor.white
        } else {
            material.diffuse.contents = UIColor(white: 0.8, alpha: 1.0)
        }
        material.roughness.contents = 0.6
        material.metalness.contents = 0.1

        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        return node
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
                containerNode.addChildNode(child.clone())
            }

            return containerNode
        } catch {
            DebugLogger.shared.error("Error loading OBJ: \(error)", category: "Mesh")
            return nil
        }
    }

    #if !targetEnvironment(simulator)
    // MARK: - Point Cloud from Depth

    /// Create a point cloud from ARFrame depth data
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

        let step = 4 // Sample every 4th pixel for performance
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let depthPointer = baseAddress.advanced(by: y * bytesPerRow + x * MemoryLayout<Float32>.size)
                let depth = depthPointer.assumingMemoryBound(to: Float32.self).pointee

                guard depth > 0 && depth < 5.0 else { continue }

                // Unproject to 3D using camera intrinsics
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

    /// Calculate bounding box for a SceneKit node
    static func calculateBoundingBox(for node: SCNNode) -> (min: SCNVector3, max: SCNVector3) {
        let (minVec, maxVec) = node.boundingBox
        return (minVec, maxVec)
    }

    /// Calculate center point of a bounding box
    static func calculateCenter(min: SCNVector3, max: SCNVector3) -> SCNVector3 {
        return SCNVector3(
            (min.x + max.x) / 2.0,
            (min.y + max.y) / 2.0,
            (min.z + max.z) / 2.0
        )
    }

    /// Calculate the size needed to fit the model in view
    static func calculateViewDistance(min: SCNVector3, max: SCNVector3) -> Float {
        let size = SCNVector3(max.x - min.x, max.y - min.y, max.z - min.z)
        let maxDimension = Swift.max(size.x, Swift.max(size.y, size.z))
        return maxDimension * 2.0
    }
}
