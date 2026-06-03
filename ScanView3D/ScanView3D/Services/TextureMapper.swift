import UIKit
import CoreVideo
import simd
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

    // MARK: - High-Resolution Texture Baking (Path A)

    /// Bake captured camera frames into a UV texture atlas with PER-FACE-CORNER UVs.
    ///
    /// This decouples color resolution from mesh resolution: each triangle gets its
    /// own cell in the atlas, and full-resolution camera pixels are projected into it.
    /// The result is a sharp, photographic surface texture instead of one blurry
    /// color per vertex.
    func bakeTexture(meshData: MeshData, atlasSize requestedSize: Int = 4096) -> BakedTexture? {
        let faceCount = meshData.faces.count
        guard faceCount > 0, !capturedFrames.isEmpty else { return nil }

        // Build fast per-frame samplers (retain CFData so the byte pointer stays valid).
        var frames: [BakeFrame] = []
        frames.reserveCapacity(capturedFrames.count)
        for f in capturedFrames {
            guard let dp = f.image.dataProvider,
                  let data = dp.data,
                  let ptr = CFDataGetBytePtr(data) else { continue }
            let isBGRA = f.image.bitmapInfo.contains(.byteOrder32Little)
            let pos = SIMD3<Float>(f.transform.columns.3.x, f.transform.columns.3.y, f.transform.columns.3.z)
            let fwd = -SIMD3<Float>(f.transform.columns.2.x, f.transform.columns.2.y, f.transform.columns.2.z)
            frames.append(BakeFrame(
                data: data, ptr: ptr,
                imgW: f.image.width, imgH: f.image.height,
                bytesPerRow: f.image.bytesPerRow, bpp: f.image.bitsPerPixel / 8,
                isBGRA: isBGRA,
                view: f.transform.inverse, intr: f.intrinsics,
                sensorW: Float(f.imageWidth), sensorH: Float(f.imageHeight),
                position: pos, forward: fwd))
        }
        guard !frames.isEmpty else { return nil }

        // Grid packing: one triangle per square cell. cols = ceil(sqrt(N)) guarantees
        // rows <= cols, so a square atlas always fits.
        let cols = max(1, Int(Double(faceCount).squareRoot().rounded(.up)))
        var atlas = max(1024, min(requestedSize, 8192))
        // Aim for at least ~10px cells if the atlas budget allows it.
        if cols * 10 > atlas && cols * 10 <= 8192 { atlas = cols * 10 }
        let cell = max(4, atlas / cols)
        let af = Float(atlas)

        // Allocate atlas pixel buffer (RGBA), neutral grey background.
        let count = atlas * atlas * 4
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        buf.initialize(repeating: 160, count: count)
        var ai = 3
        while ai < count { buf[ai] = 255; ai += 4 }

        var cornerUVs = [SIMD2<Float>](repeating: SIMD2<Float>(0, 0), count: faceCount * 3)
        let colorCount = meshData.colors.count

        for f in 0..<faceCount {
            let face = meshData.faces[f]
            guard face.count == 3 else { continue }
            let i0 = Int(face[0]), i1 = Int(face[1]), i2 = Int(face[2])
            guard i0 < meshData.vertices.count, i1 < meshData.vertices.count, i2 < meshData.vertices.count else { continue }
            let v0 = meshData.vertices[i0], v1 = meshData.vertices[i1], v2 = meshData.vertices[i2]

            var fn = cross(v1 - v0, v2 - v0)
            let fnl = length(fn)
            if fnl > 1e-8 { fn /= fnl }
            let centroid = (v0 + v1 + v2) / 3

            // Pick the best camera frame for this triangle.
            var best = -1
            var bestScore: Float = 0
            for fi in 0..<frames.count {
                let s = frames[fi]
                let toC = centroid - s.position
                let dist = length(toC)
                if dist < 1e-3 { continue }
                let dir = toC / dist
                let viewAlign = dot(dir, s.forward)
                if viewAlign < 0.15 { continue }
                let na = abs(dot(fn, dir))
                if na < 0.05 { continue }
                if bakeProject(v0, s) == nil || bakeProject(v1, s) == nil || bakeProject(v2, s) == nil { continue }
                let score = na * viewAlign / (dist * dist)
                if score > bestScore { bestScore = score; best = fi }
            }
            let chosen: BakeFrame? = best >= 0 ? frames[best] : nil

            // Cell layout with a 1px gutter; corners form a right triangle in the cell.
            let col = f % cols
            let row = f / cols
            let ox = col * cell
            let oy = row * cell
            let g = 1
            let inner = max(1, cell - 2 * g)
            let ax0 = Float(ox + g),         ay0 = Float(oy + g)
            let ax1 = Float(ox + g + inner), ay1 = Float(oy + g)
            let ax2 = Float(ox + g),         ay2 = Float(oy + g + inner)

            cornerUVs[f * 3 + 0] = SIMD2<Float>((ax0 + 0.5) / af, 1 - (ay0 + 0.5) / af)
            cornerUVs[f * 3 + 1] = SIMD2<Float>((ax1 + 0.5) / af, 1 - (ay1 + 0.5) / af)
            cornerUVs[f * 3 + 2] = SIMD2<Float>((ax2 + 0.5) / af, 1 - (ay2 + 0.5) / af)

            // Fallback color (used if a triangle isn't seen by any frame, or per-pixel
            // projection fails) so we never leave grey holes.
            var fcol = SIMD4<Float>(0.6, 0.6, 0.6, 1)
            if colorCount > 0 {
                let c0 = meshData.colors[min(i0, colorCount - 1)]
                let c1 = meshData.colors[min(i1, colorCount - 1)]
                let c2 = meshData.colors[min(i2, colorCount - 1)]
                fcol = (c0 + c1 + c2) / 3
            }
            let fr = UInt8(max(0, min(255, fcol.x * 255)))
            let fg = UInt8(max(0, min(255, fcol.y * 255)))
            let fb = UInt8(max(0, min(255, fcol.z * 255)))

            // Rasterize the triangle's cell with barycentric interpolation.
            let den = (ay1 - ay2) * (ax0 - ax2) + (ax2 - ax1) * (ay0 - ay2)
            if abs(den) < 1e-6 { continue }
            let invDen = 1 / den
            let bleed: Float = 1.5 / Float(inner)   // bleed into gutter to hide seams
            let minX = ox, maxX = ox + cell - 1
            let minY = oy, maxY = oy + cell - 1

            for py in minY...maxY {
                let fy = Float(py) + 0.5
                for px in minX...maxX {
                    let fx = Float(px) + 0.5
                    var a = ((ay1 - ay2) * (fx - ax2) + (ax2 - ax1) * (fy - ay2)) * invDen
                    var b = ((ay2 - ay0) * (fx - ax2) + (ax0 - ax2) * (fy - ay2)) * invDen
                    var c = 1 - a - b
                    if a < -bleed || b < -bleed || c < -bleed { continue }
                    if a < 0 { a = 0 }; if b < 0 { b = 0 }; if c < 0 { c = 0 }
                    let sum = a + b + c
                    if sum <= 0 { continue }
                    a /= sum; b /= sum; c /= sum

                    var rr = fr, gg = fg, bb = fb
                    if let s = chosen {
                        let world = SIMD3<Float>(
                            a * v0.x + b * v1.x + c * v2.x,
                            a * v0.y + b * v1.y + c * v2.y,
                            a * v0.z + b * v1.z + c * v2.z)
                        if let uv = bakeProject(world, s) {
                            let texel = bakeSample(s, uv)
                            rr = texel.0; gg = texel.1; bb = texel.2
                        }
                    }
                    let idx = (py * atlas + px) * 4
                    buf[idx] = rr; buf[idx + 1] = gg; buf[idx + 2] = bb; buf[idx + 3] = 255
                }
            }
        }

        // Build the atlas image.
        let cs = CGColorSpaceCreateDeviceRGB()
        let bmp = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: buf, width: atlas, height: atlas,
                                  bitsPerComponent: 8, bytesPerRow: atlas * 4,
                                  space: cs, bitmapInfo: bmp),
              let cg = ctx.makeImage() else {
            buf.deallocate()
            return nil
        }
        buf.deallocate()

        return BakedTexture(atlasImage: UIImage(cgImage: cg), cornerUVs: cornerUVs, atlasSize: atlas)
    }
}

// MARK: - Texture Baking Support Types & Helpers

/// A baked UV texture atlas. `cornerUVs` holds 3 entries per face (per-corner),
/// flattened so face f uses indices [3f, 3f+1, 3f+2]. UVs use SceneKit/OBJ
/// convention (origin bottom-left).
struct BakedTexture {
    let atlasImage: UIImage
    let cornerUVs: [SIMD2<Float>]
    let atlasSize: Int
}

/// Pre-resolved camera frame data for fast projection/sampling during baking.
fileprivate struct BakeFrame {
    let data: CFData            // retained to keep `ptr` valid
    let ptr: UnsafePointer<UInt8>
    let imgW: Int
    let imgH: Int
    let bytesPerRow: Int
    let bpp: Int
    let isBGRA: Bool
    let view: simd_float4x4
    let intr: simd_float3x3
    let sensorW: Float
    let sensorH: Float
    let position: SIMD3<Float>
    let forward: SIMD3<Float>
}

/// Project a world point into a frame, returning normalized image UV (origin top-left),
/// or nil if behind the camera or outside the image.
fileprivate func bakeProject(_ world: SIMD3<Float>, _ s: BakeFrame) -> SIMD2<Float>? {
    let cp = s.view * SIMD4<Float>(world.x, world.y, world.z, 1)
    let z = cp.z
    guard z < -0.001 else { return nil }
    let x = s.intr[0][0] * cp.x / (-z) + s.intr[2][0]
    let y = s.intr[1][1] * cp.y / (-z) + s.intr[2][1]
    let u = x / s.sensorW
    let v = y / s.sensorH
    guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
    return SIMD2<Float>(u, v)
}

/// Bilinear sample a frame's pixels at normalized UV (origin top-left).
fileprivate func bakeSample(_ s: BakeFrame, _ uv: SIMD2<Float>) -> (UInt8, UInt8, UInt8) {
    var fx = uv.x * Float(s.imgW) - 0.5
    var fy = uv.y * Float(s.imgH) - 0.5
    if fx < 0 { fx = 0 }
    if fy < 0 { fy = 0 }
    let x0 = min(Int(fx), s.imgW - 1)
    let y0 = min(Int(fy), s.imgH - 1)
    let x1 = min(x0 + 1, s.imgW - 1)
    let y1 = min(y0 + 1, s.imgH - 1)
    let tx = fx - Float(x0)
    let ty = fy - Float(y0)

    func texel(_ x: Int, _ y: Int) -> (Float, Float, Float) {
        let o = y * s.bytesPerRow + x * s.bpp
        let c0 = Float(s.ptr[o]), c1 = Float(s.ptr[o + 1]), c2 = Float(s.ptr[o + 2])
        return s.isBGRA ? (c2, c1, c0) : (c0, c1, c2)
    }
    func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

    let p00 = texel(x0, y0), p10 = texel(x1, y0)
    let p01 = texel(x0, y1), p11 = texel(x1, y1)
    let r = lerp(lerp(p00.0, p10.0, tx), lerp(p01.0, p11.0, tx), ty)
    let g = lerp(lerp(p00.1, p10.1, tx), lerp(p01.1, p11.1, tx), ty)
    let b = lerp(lerp(p00.2, p10.2, tx), lerp(p01.2, p11.2, tx), ty)
    return (UInt8(max(0, min(255, r))), UInt8(max(0, min(255, g))), UInt8(max(0, min(255, b))))
}

struct TextureAtlasResult {
    let atlasImage: UIImage
    let uvCoordinates: [SIMD2<Float>]
    let atlasWidth: Int
    let atlasHeight: Int
}
