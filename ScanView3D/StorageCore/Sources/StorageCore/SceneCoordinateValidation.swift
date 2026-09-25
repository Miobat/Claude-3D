#if canImport(SceneKit)
import Foundation
import SceneKit
import simd

/// Independent of the viewer's centering/grid/camera. Reads actual vertices,
/// not rotated bounding-box corners, so asymmetric geometry is checked too.
enum SceneCoordinateValidation {
    struct Bounds {
        var minimum: SIMD3<Double>
        var maximum: SIMD3<Double>
        var vertexCount: Int
    }
    static func bounds(url: URL, transform: [Double] = CoordinateMath.identity) throws -> Bounds {
        let m = try CoordinateMath.validated(transform)
        let correction = simd_double4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                       SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))
        let scene = try SCNScene(url: url, options: [.checkConsistency: true])
        var result = Bounds(minimum: SIMD3(repeating: .infinity), maximum: SIMD3(repeating: -.infinity), vertexCount: 0)
        func visit(_ node: SCNNode, parent: simd_double4x4) throws {
            let f = node.simdTransform
            let matrix = parent * simd_double4x4(SIMD4<Double>(f.columns.0), SIMD4<Double>(f.columns.1),
                                                 SIMD4<Double>(f.columns.2), SIMD4<Double>(f.columns.3))
            if let source = node.geometry?.sources(for: .vertex).first {
                guard source.usesFloatComponents, [4, 8].contains(source.bytesPerComponent),
                      source.componentsPerVector >= 3, source.dataStride > 0, source.dataOffset >= 0,
                      source.vectorCount > 0,
                      source.vectorCount <= source.data.count / source.dataStride + 1 else { throw CoordinateError.incompleteExport }
                try source.data.withUnsafeBytes { bytes in
                    for index in 0..<source.vectorCount {
                        let start = source.dataOffset + source.dataStride * index
                        guard start <= bytes.count - 3 * source.bytesPerComponent else { throw CoordinateError.incompleteExport }
                        func scalar(_ component: Int) -> Double {
                            let offset = start + component * source.bytesPerComponent
                            return source.bytesPerComponent == 4
                                ? Double(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self))
                                : bytes.loadUnaligned(fromByteOffset: offset, as: Double.self)
                        }
                        let w = matrix * SIMD4(scalar(0), scalar(1), scalar(2), 1)
                        guard w.x.isFinite, w.y.isFinite, w.z.isFinite else { throw CoordinateError.incompleteExport }
                        let p = SIMD3(w.x, w.y, w.z)
                        result.minimum = simd_min(result.minimum, p)
                        result.maximum = simd_max(result.maximum, p)
                        result.vertexCount += 1
                    }
                }
            }
            for child in node.childNodes { try visit(child, parent: matrix) }
        }
        try visit(scene.rootNode, parent: correction)
        guard result.vertexCount > 0 else { throw CoordinateError.incompleteExport }
        return result
    }
    static func verify(source: URL, exported: URL, transform: [Double]) throws {
        let expected = try bounds(url: source, transform: transform)
        let actual = try bounds(url: exported)
        let tolerance = max(0.0001, simd_length(expected.maximum - expected.minimum) * 0.0001)
        guard actual.vertexCount == expected.vertexCount,
              simd_length(expected.minimum - actual.minimum) <= tolerance,
              simd_length(expected.maximum - actual.maximum) <= tolerance else { throw CoordinateError.incompleteExport }
    }
}
#endif
