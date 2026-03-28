import Foundation
import SceneKit
#if !targetEnvironment(simulator)
import ARKit
#endif

// MARK: - SIMD3 Codable

extension SIMD3: @retroactive Codable where Scalar == Float {
    enum CodingKeys: String, CodingKey {
        case x, y, z
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(Float.self, forKey: .x)
        let y = try container.decode(Float.self, forKey: .y)
        let z = try container.decode(Float.self, forKey: .z)
        self.init(x, y, z)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.x, forKey: .x)
        try container.encode(self.y, forKey: .y)
        try container.encode(self.z, forKey: .z)
    }
}

// MARK: - Date Formatting

extension Date {
    var relativeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    var formattedString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }
}

// MARK: - SCNVector3 Helpers

extension SCNVector3 {
    func distance(to other: SCNVector3) -> Float {
        let dx = self.x - other.x
        let dy = self.y - other.y
        let dz = self.z - other.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    static func + (lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 {
        return SCNVector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    static func - (lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 {
        return SCNVector3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }

    static func * (lhs: SCNVector3, rhs: Float) -> SCNVector3 {
        return SCNVector3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }

    var length: Float {
        return sqrt(x * x + y * y + z * z)
    }

    var normalized: SCNVector3 {
        let len = length
        guard len > 0 else { return self }
        return SCNVector3(x / len, y / len, z / len)
    }

    func cross(_ other: SCNVector3) -> SCNVector3 {
        return SCNVector3(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        )
    }

    func dot(_ other: SCNVector3) -> Float {
        return x * other.x + y * other.y + z * other.z
    }
}

// MARK: - simd_float4x4 Helpers

extension simd_float4x4 {
    var position: SIMD3<Float> {
        return SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }
}

#if !targetEnvironment(simulator)
// MARK: - ARMeshGeometry Vertex Access

extension ARMeshGeometry {
    func vertex(at index: UInt32) -> SIMD3<Float> {
        assert(vertices.format == MTLVertexFormat.float3, "Expected float3 vertex format")
        let vertexPointer = vertices.buffer.contents().advanced(by: vertices.offset + (vertices.stride * Int(index)))
        let vertex = vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
        return vertex
    }

    func normal(at index: UInt32) -> SIMD3<Float> {
        assert(normals.format == MTLVertexFormat.float3, "Expected float3 normal format")
        let normalPointer = normals.buffer.contents().advanced(by: normals.offset + (normals.stride * Int(index)))
        let normal = normalPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
        return normal
    }

    func vertexIndicesOf(face faceIndex: Int) -> [UInt32] {
        let indexCountPerPrimitive = 3 // triangles
        let baseIndex = faceIndex * indexCountPerPrimitive
        var indices: [UInt32] = []

        let bytesPerIndex = faces.bytesPerIndex
        for i in 0..<indexCountPerPrimitive {
            let offset = faces.offset + (baseIndex + i) * bytesPerIndex
            let pointer = faces.buffer.contents().advanced(by: offset)

            if bytesPerIndex == 4 {
                indices.append(pointer.assumingMemoryBound(to: UInt32.self).pointee)
            } else {
                indices.append(UInt32(pointer.assumingMemoryBound(to: UInt16.self).pointee))
            }
        }
        return indices
    }
}
#endif

// MARK: - View Modifiers

extension View {
    func cardStyle() -> some View {
        self
            .padding(AppConstants.Layout.padding)
            .background(AppConstants.Colors.secondaryBackground)
            .cornerRadius(AppConstants.Layout.cornerRadius)
    }
}
