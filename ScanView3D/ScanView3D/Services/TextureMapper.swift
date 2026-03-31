import UIKit
import CoreVideo
#if !targetEnvironment(simulator)
import ARKit
#endif

/// Stores a captured camera frame with its pose and intrinsics for texture projection
struct CapturedFrame {
    let image: CGImage
    let transform: simd_float4x4
    let intrinsics: simd_float3x3
    let imageWidth: Int   // original sensor image dimensions (for projection math)
    let imageHeight: Int
    let timestamp: TimeInterval
}

/// Handles camera frame capture during scanning and texture projection onto meshes
class TextureMapper {

    // MARK: - Properties

    private(set) var capturedFrames: [CapturedFrame] = []
    private var lastCaptureTime: TimeInterval = 0
    private var captureInterval: TimeInterval = 0.5
    private var maxFrames: Int = 40
    private var downscaleWidth: Int = 960

    var frameCount: Int { capturedFrames.count }

    var estimatedMemoryUsageMB: Double {
        var total: Double = 0
        for frame in capturedFrames {
            total += Double(frame.image.width * frame.image.height * 4) / (1024.0 * 1024.0)
        }
        return total
    }

    var estimatedAtlasSizeMB: Double {
        guard !capturedFrames.isEmpty else { return 0 }
        return estimatedMemoryUsageMB * 0.1
    }

    // MARK: - Configuration

    func configure(quality: ScanSettings.ScanQuality) {
        captureInterval = quality.textureCaptureInterval
        maxFrames = quality.maxTextureFrames
        downscaleWidth = quality.textureDownscaleWidth
    }

    func reset() {
        capturedFrames.removeAll()
        lastCaptureTime = 0
    }

    // MARK: - Frame Capture

    #if !targetEnvironment(simulator)
    func captureFrame(from arFrame: ARFrame) {
        let currentTime = arFrame.timestamp
        guard currentTime - lastCaptureTime >= captureInterval else { return }
        lastCaptureTime = currentTime

        let pixelBuffer = arFrame.capturedImage
        guard let cgImage = pixelBufferToCGImage(pixelBuffer, maxWidth: downscaleWidth) else { return }

        let frame = CapturedFrame(
            image: cgImage,
            transform: arFrame.camera.transform,
            intrinsics: arFrame.camera.intrinsics,
            imageWidth: CVPixelBufferGetWidth(pixelBuffer),
            imageHeight: CVPixelBufferGetHeight(pixelBuffer),
            timestamp: currentTime
        )

        if capturedFrames.count >= maxFrames {
            removeRedundantFrame()
        }
        capturedFrames.append(frame)
    }
    #endif

    // MARK: - Vertex Color Sampling

    func sampleVertexColors(vertices: [SIMD3<Float>], normals: [SIMD3<Float>]) -> [SIMD4<Float>] {
        guard !capturedFrames.isEmpty else {
            return Array(repeating: SIMD4<Float>(0.7, 0.7, 0.7, 1.0), count: vertices.count)
        }

        var colors = [SIMD4<Float>](repeating: SIMD4<Float>(0.7, 0.7, 0.7, 1.0), count: vertices.count)

        // Pre-compute camera data
        let cameraData = capturedFrames.map { frame -> (position: SIMD3<Float>, forward: SIMD3<Float>) in
            let pos = SIMD3<Float>(frame.transform.columns.3.x, frame.transform.columns.3.y, frame.transform.columns.3.z)
            let fwd = -SIMD3<Float>(frame.transform.columns.2.x, frame.transform.columns.2.y, frame.transform.columns.2.z)
            return (pos, fwd)
        }

        // Detect pixel format from first frame for correct color channel reading
        let firstImage = capturedFrames[0].image
        let isBGRA = firstImage.bitmapInfo.contains(.byteOrder32Little) ||
                     (firstImage.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue == CGBitmapInfo.byteOrder32Little.rawValue)

        for i in 0..<vertices.count {
            let vertex = vertices[i]
            let normal = i < normals.count ? normals[i] : SIMD3<Float>(0, 1, 0)

            var bestFrameIndex = -1
            var bestScore: Float = -1

            for (fi, _) in capturedFrames.enumerated() {
                let cam = cameraData[fi]
                let toVertex = vertex - cam.position
                let distance = length(toVertex)
                guard distance > 0.05 else { continue }
                let toVertexNorm = toVertex / distance

                let normalDot = -dot(normal, toVertexNorm)
                guard normalDot > 0.05 else { continue }

                let viewDot = dot(toVertexNorm, cam.forward)
                guard viewDot > 0.2 else { continue }

                guard let uv = projectPoint(vertex, into: capturedFrames[fi]) else { continue }

                let centerDist = length(SIMD2<Float>(uv.x - 0.5, uv.y - 0.5))
                let centerScore = max(0, 1.0 - centerDist * 1.5)
                let score = normalDot * viewDot * centerScore / max(distance, 0.2)

                if score > bestScore {
                    bestScore = score
                    bestFrameIndex = fi
                }
            }

            if bestFrameIndex >= 0, let uv = projectPoint(vertex, into: capturedFrames[bestFrameIndex]) {
                if let color = sampleColor(from: capturedFrames[bestFrameIndex].image, at: uv, isBGRA: isBGRA) {
                    colors[i] = color
                }
            }
        }

        return colors
    }

    // MARK: - Texture Atlas Generation

    func buildTextureAtlas(meshData: MeshData, tileSize: Int = 768) -> TextureAtlasResult? {
        guard !capturedFrames.isEmpty else { return nil }

        let effectiveTileSize = min(tileSize, capturedFrames.count > 20 ? 512 : tileSize)
        let frameCount = capturedFrames.count
        let gridCols = Int(ceil(sqrt(Double(frameCount))))
        let gridRows = Int(ceil(Double(frameCount) / Double(gridCols)))
        let atlasWidth = gridCols * effectiveTileSize
        let atlasHeight = gridRows * effectiveTileSize

        if atlasWidth > 4096 || atlasHeight > 4096 { return nil }

        let cameraData = capturedFrames.map { frame -> (position: SIMD3<Float>, forward: SIMD3<Float>) in
            let pos = SIMD3<Float>(frame.transform.columns.3.x, frame.transform.columns.3.y, frame.transform.columns.3.z)
            let fwd = -SIMD3<Float>(frame.transform.columns.2.x, frame.transform.columns.2.y, frame.transform.columns.2.z)
            return (pos, fwd)
        }

        var uvCoordinates = [SIMD2<Float>](repeating: SIMD2<Float>(0, 0), count: meshData.vertices.count)

        for face in meshData.faces {
            guard face.count == 3 else { continue }
            let i0 = Int(face[0]), i1 = Int(face[1]), i2 = Int(face[2])
            guard i0 < meshData.vertices.count && i1 < meshData.vertices.count && i2 < meshData.vertices.count else { continue }

            let v0 = meshData.vertices[i0], v1 = meshData.vertices[i1], v2 = meshData.vertices[i2]
            let faceCenter = (v0 + v1 + v2) / 3.0

            let n0 = i0 < meshData.normals.count ? meshData.normals[i0] : SIMD3<Float>(0, 1, 0)
            let n1 = i1 < meshData.normals.count ? meshData.normals[i1] : SIMD3<Float>(0, 1, 0)
            let n2 = i2 < meshData.normals.count ? meshData.normals[i2] : SIMD3<Float>(0, 1, 0)
            let sumN = n0 + n1 + n2
            let lenN = length(sumN)
            let faceNormal = lenN > 0.001 ? sumN / lenN : SIMD3<Float>(0, 1, 0)

            var bestFrame = -1
            var bestScore: Float = -1

            for (fi, _) in capturedFrames.enumerated() {
                let cam = cameraData[fi]
                let toFace = faceCenter - cam.position
                let distance = length(toFace)
                guard distance > 0.05 else { continue }
                let toFaceNorm = toFace / distance

                let normalAlignment = -dot(faceNormal, toFaceNorm)
                guard normalAlignment > 0.05 else { continue }

                let viewAlignment = dot(toFaceNorm, cam.forward)
                guard viewAlignment > 0.2 else { continue }

                guard let _ = projectPoint(v0, into: capturedFrames[fi]),
                      let _ = projectPoint(v1, into: capturedFrames[fi]),
                      let _ = projectPoint(v2, into: capturedFrames[fi]) else { continue }

                let score = normalAlignment * viewAlignment / max(distance * distance, 0.01)
                if score > bestScore { bestScore = score; bestFrame = fi }
            }

            guard bestFrame >= 0 else { continue }

            let row = bestFrame / gridCols
            let col = bestFrame % gridCols

            for idx in [i0, i1, i2] {
                if let localUV = projectPoint(meshData.vertices[idx], into: capturedFrames[bestFrame]) {
                    let atlasU = (Float(col) + localUV.x) / Float(gridCols)
                    let atlasV = (Float(row) + localUV.y) / Float(gridRows)
                    uvCoordinates[idx] = SIMD2<Float>(atlasU, atlasV)
                }
            }
        }

        guard let atlasImage = createAtlasImage(
            gridCols: gridCols, gridRows: gridRows,
            tileSize: effectiveTileSize, atlasWidth: atlasWidth, atlasHeight: atlasHeight
        ) else { return nil }

        return TextureAtlasResult(
            atlasImage: atlasImage, uvCoordinates: uvCoordinates,
            atlasWidth: atlasWidth, atlasHeight: atlasHeight
        )
    }

    // MARK: - Projection

    func projectPoint(_ worldPoint: SIMD3<Float>, into frame: CapturedFrame) -> SIMD2<Float>? {
        let viewMatrix = simd_inverse(frame.transform)
        let cameraPoint4 = viewMatrix * SIMD4<Float>(worldPoint.x, worldPoint.y, worldPoint.z, 1.0)
        let cameraPoint = SIMD3<Float>(cameraPoint4.x, cameraPoint4.y, cameraPoint4.z)

        guard cameraPoint.z < -0.01 else { return nil }

        let fx = frame.intrinsics[0][0]
        let fy = frame.intrinsics[1][1]
        let cx = frame.intrinsics[2][0]
        let cy = frame.intrinsics[2][1]

        let x = fx * cameraPoint.x / (-cameraPoint.z) + cx
        let y = fy * cameraPoint.y / (-cameraPoint.z) + cy

        let u = x / Float(frame.imageWidth)
        let v = y / Float(frame.imageHeight)

        guard u >= 0.02 && u <= 0.98 && v >= 0.02 && v <= 0.98 else { return nil }

        return SIMD2<Float>(u, v)
    }

    // MARK: - Color Sampling

    /// Sample color from CGImage, handling both BGRA and RGBA byte orders
    private func sampleColor(from image: CGImage, at uv: SIMD2<Float>, isBGRA: Bool) -> SIMD4<Float>? {
        let px = Int(uv.x * Float(image.width))
        let py = Int(uv.y * Float(image.height))

        guard px >= 0 && px < image.width && py >= 0 && py < image.height else { return nil }

        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }

        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow
        let offset = py * bytesPerRow + px * bytesPerPixel

        guard offset + bytesPerPixel <= CFDataGetLength(data) else { return nil }

        // Handle BGRA vs RGBA byte order
        let r: Float, g: Float, b: Float
        if isBGRA {
            b = Float(ptr[offset]) / 255.0
            g = Float(ptr[offset + 1]) / 255.0
            r = Float(ptr[offset + 2]) / 255.0
        } else {
            r = Float(ptr[offset]) / 255.0
            g = Float(ptr[offset + 1]) / 255.0
            b = Float(ptr[offset + 2]) / 255.0
        }

        return SIMD4<Float>(r, g, b, 1.0)
    }

    // MARK: - Image Conversion

    /// Convert CVPixelBuffer to CGImage, optionally downscaled
    private func pixelBufferToCGImage(_ pixelBuffer: CVPixelBuffer, maxWidth: Int) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let originalWidth = CVPixelBufferGetWidth(pixelBuffer)

        let scale = min(1.0, Double(maxWidth) / Double(originalWidth))

        // Use kCGImageAlphaPremultipliedFirst + byteOrder32Little = BGRA format (iOS native)
        let context = CIContext(options: [.useSoftwareRenderer: false, .highQualityDownsample: true])

        if scale < 1.0 {
            let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return context.createCGImage(scaled, from: scaled.extent)
        } else {
            return context.createCGImage(ciImage, from: ciImage.extent)
        }
    }

    // MARK: - Frame Management

    private func removeRedundantFrame() {
        guard capturedFrames.count >= 3 else {
            if capturedFrames.count >= 2 { capturedFrames.removeFirst() }
            return
        }

        var minAngle: Float = .greatestFiniteMagnitude
        var removeIndex = 1

        for i in 1..<capturedFrames.count - 1 {
            let fwd_i = -SIMD3<Float>(
                capturedFrames[i].transform.columns.2.x,
                capturedFrames[i].transform.columns.2.y,
                capturedFrames[i].transform.columns.2.z
            )
            let fwd_prev = -SIMD3<Float>(
                capturedFrames[i - 1].transform.columns.2.x,
                capturedFrames[i - 1].transform.columns.2.y,
                capturedFrames[i - 1].transform.columns.2.z
            )

            let angle = acos(min(1, max(-1, dot(fwd_i, fwd_prev))))
            if angle < minAngle { minAngle = angle; removeIndex = i }
        }

        capturedFrames.remove(at: removeIndex)
    }

    private func createAtlasImage(gridCols: Int, gridRows: Int, tileSize: Int, atlasWidth: Int, atlasHeight: Int) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: atlasWidth, height: atlasHeight))

        return renderer.image { ctx in
            UIColor(white: 0.5, alpha: 1.0).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: atlasWidth, height: atlasHeight))

            for (i, frame) in capturedFrames.enumerated() {
                let row = i / gridCols
                let col = i % gridCols
                let rect = CGRect(x: col * tileSize, y: row * tileSize, width: tileSize, height: tileSize)
                UIImage(cgImage: frame.image).draw(in: rect)
            }
        }
    }
}

struct TextureAtlasResult {
    let atlasImage: UIImage
    let uvCoordinates: [SIMD2<Float>]
    let atlasWidth: Int
    let atlasHeight: Int
}
