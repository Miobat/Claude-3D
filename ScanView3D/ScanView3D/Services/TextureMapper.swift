import UIKit
import CoreVideo
import CoreImage
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

/// Handles camera frame capture during scanning and texture projection onto meshes.
///
/// Thread-safety: frames are appended on a private background queue and read
/// through a lock, so colour sampling and baking can run on any thread.
class TextureMapper {

    // MARK: - Properties

    private let lock = NSLock()
    private var frames: [CapturedFrame] = []
    private let captureQueue = DispatchQueue(label: "scanview.texture.capture", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false, .highQualityDownsample: true])

    // Main-thread state
    private var lastCaptureTime: TimeInterval = 0
    private var conversionInFlight = false

    private var captureInterval: TimeInterval = 0.5
    private var maxFrames: Int = 40
    private var downscaleWidth: Int = 960

    var capturedFrames: [CapturedFrame] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    var frameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return frames.count
    }

    var estimatedMemoryUsageMB: Double {
        capturedFrames.reduce(0) { $0 + Double($1.image.width * $1.image.height * 4) } / (1024.0 * 1024.0)
    }

    var estimatedAtlasSizeMB: Double {
        frameCount == 0 ? 0 : estimatedMemoryUsageMB * 0.1
    }

    // MARK: - Configuration

    func configure(quality: ScanSettings.ScanQuality) {
        captureInterval = quality.textureCaptureInterval
        maxFrames = quality.maxTextureFrames
        downscaleWidth = quality.textureDownscaleWidth
    }

    func reset() {
        lock.lock()
        frames.removeAll()
        lock.unlock()
        lastCaptureTime = 0
    }

    // MARK: - Frame Capture

    #if !targetEnvironment(simulator)
    /// Call on the main thread. Conversion happens in the background; at most one
    /// frame is in flight so ARKit's camera buffers are never held for long.
    func captureFrame(from arFrame: ARFrame, onCountChanged: ((Int) -> Void)? = nil) {
        let currentTime = arFrame.timestamp
        guard currentTime - lastCaptureTime >= captureInterval, !conversionInFlight else { return }
        lastCaptureTime = currentTime
        conversionInFlight = true

        let pixelBuffer = arFrame.capturedImage
        let transform = arFrame.camera.transform
        let intrinsics = arFrame.camera.intrinsics
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let maxWidth = downscaleWidth
        let limit = maxFrames

        captureQueue.async { [weak self] in
            guard let self = self else { return }
            var count = 0
            if let cgImage = self.makeCGImage(pixelBuffer, maxWidth: maxWidth) {
                let frame = CapturedFrame(image: cgImage, transform: transform, intrinsics: intrinsics,
                                          imageWidth: width, imageHeight: height, timestamp: currentTime)
                self.lock.lock()
                if self.frames.count >= limit { self.removeRedundantFrameLocked() }
                self.frames.append(frame)
                count = self.frames.count
                self.lock.unlock()
            }
            DispatchQueue.main.async {
                self.conversionInFlight = false
                if count > 0 { onCountChanged?(count) }
            }
        }
    }
    #endif

    // MARK: - Vertex Color Sampling

    /// One colour per vertex from the best-facing camera frame (bilinear sampled).
    func sampleVertexColors(vertices: [SIMD3<Float>], normals: [SIMD3<Float>]) -> [SIMD4<Float>] {
        let fallback = SIMD4<Float>(0.7, 0.7, 0.7, 1.0)
        var colors = [SIMD4<Float>](repeating: fallback, count: vertices.count)
        let samplers = makeSamplers()
        guard !samplers.isEmpty else { return colors }

        for i in 0..<vertices.count {
            let vertex = vertices[i]
            let normal = i < normals.count ? normals[i] : SIMD3<Float>(0, 1, 0)

            var best = -1
            var bestScore: Float = -1
            var bestUV = SIMD2<Float>(0, 0)

            for (fi, s) in samplers.enumerated() {
                let toVertex = vertex - s.position
                let distance = simd_length(toVertex)
                guard distance > 0.05 else { continue }
                let dir = toVertex / distance

                let normalDot = -simd_dot(normal, dir)
                guard normalDot > 0.05 else { continue }
                let viewDot = simd_dot(dir, s.forward)
                guard viewDot > 0.2 else { continue }
                guard let uv = projectToImage(vertex, s), uv.x >= 0.02, uv.x <= 0.98, uv.y >= 0.02, uv.y <= 0.98 else { continue }

                let centerScore = max(0, 1.0 - simd_length(uv - SIMD2<Float>(0.5, 0.5)) * 1.5)
                let score = normalDot * viewDot * centerScore / max(distance, 0.2)
                if score > bestScore {
                    bestScore = score
                    best = fi
                    bestUV = uv
                }
            }

            if best >= 0 {
                let t = sampleBilinear(samplers[best], bestUV)
                colors[i] = SIMD4<Float>(Float(t.0) / 255, Float(t.1) / 255, Float(t.2) / 255, 1)
            }
        }
        return colors
    }

    /// Resolve every frame once: pixel pointer, view matrix, camera position.
    private func makeSamplers() -> [FrameSampler] {
        var samplers: [FrameSampler] = []
        for f in capturedFrames {
            guard let dp = f.image.dataProvider,
                  let data = dp.data,
                  let ptr = CFDataGetBytePtr(data) else { continue }
            samplers.append(FrameSampler(
                data: data, ptr: ptr,
                imgW: f.image.width, imgH: f.image.height,
                bytesPerRow: f.image.bytesPerRow, bpp: f.image.bitsPerPixel / 8,
                isBGRA: f.image.bitmapInfo.contains(.byteOrder32Little),
                view: f.transform.inverse, intr: f.intrinsics,
                sensorW: Float(f.imageWidth), sensorH: Float(f.imageHeight),
                position: f.transform.position,
                forward: -SIMD3<Float>(f.transform.columns.2.x, f.transform.columns.2.y, f.transform.columns.2.z)))
        }
        return samplers
    }

    // MARK: - Image Conversion

    private func makeCGImage(_ pixelBuffer: CVPixelBuffer, maxWidth: Int) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = min(1.0, Double(maxWidth) / Double(CVPixelBufferGetWidth(pixelBuffer)))
        let image = scale < 1.0 ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ciImage
        return ciContext.createCGImage(image, from: image.extent)
    }

    // MARK: - Frame Management

    /// Drop the frame that looks most like its predecessor (same direction AND
    /// nearly the same position). Caller must hold `lock`.
    private func removeRedundantFrameLocked() {
        guard frames.count >= 3 else {
            if frames.count >= 2 { frames.removeFirst() }
            return
        }
        var minCost: Float = .greatestFiniteMagnitude
        var removeIndex = 1
        for i in 1..<frames.count - 1 {
            let a = frames[i].transform, b = frames[i - 1].transform
            let fa = -SIMD3<Float>(a.columns.2.x, a.columns.2.y, a.columns.2.z)
            let fb = -SIMD3<Float>(b.columns.2.x, b.columns.2.y, b.columns.2.z)
            let angle = acos(min(1, max(-1, simd_dot(fa, fb))))
            let moved = simd_distance(a.position, b.position)
            let cost = angle + moved   // ~1 rad ≈ 1 m of "difference"
            if cost < minCost { minCost = cost; removeIndex = i }
        }
        frames.remove(at: removeIndex)
    }

    // MARK: - High-Resolution Texture Baking

    /// Bake captured camera frames into a UV texture atlas with PER-FACE-CORNER UVs.
    ///
    /// Each triangle gets its own cell in the atlas and full-resolution camera
    /// pixels are projected into it, decoupling colour detail from mesh density.
    func bakeTexture(meshData: MeshData, atlasSize requestedSize: Int = 4096) -> BakedTexture? {
        let faceCount = meshData.faces.count
        let frames = makeSamplers()
        guard faceCount > 0, !frames.isEmpty else { return nil }

        // Grid packing: one triangle per square cell. cols = ceil(sqrt(N)) guarantees
        // rows <= cols, so a square atlas always fits.
        let cols = max(1, Int(Double(faceCount).squareRoot().rounded(.up)))
        var atlas = max(1024, min(requestedSize, 8192))
        if cols * 10 > atlas && cols * 10 <= 8192 { atlas = cols * 10 }
        let cell = max(4, atlas / cols)
        let af = Float(atlas)

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

            var fn = simd_cross(v1 - v0, v2 - v0)
            let fnl = simd_length(fn)
            if fnl > 1e-8 { fn /= fnl }
            let centroid = (v0 + v1 + v2) / 3

            // Pick the best camera frame for this triangle.
            var best = -1
            var bestScore: Float = 0
            for fi in 0..<frames.count {
                let s = frames[fi]
                let toC = centroid - s.position
                let dist = simd_length(toC)
                if dist < 1e-3 { continue }
                let dir = toC / dist
                let viewAlign = simd_dot(dir, s.forward)
                if viewAlign < 0.15 { continue }
                let na = abs(simd_dot(fn, dir))
                if na < 0.05 { continue }
                if projectToImage(v0, s) == nil || projectToImage(v1, s) == nil || projectToImage(v2, s) == nil { continue }
                let score = na * viewAlign / (dist * dist)
                if score > bestScore { bestScore = score; best = fi }
            }
            let chosen: FrameSampler? = best >= 0 ? frames[best] : nil

            // Cell layout with a 1px gutter; corners form a right triangle in the cell.
            let ox = (f % cols) * cell
            let oy = (f / cols) * cell
            let g = 1
            let inner = max(1, cell - 2 * g)
            let ax0 = Float(ox + g),         ay0 = Float(oy + g)
            let ax1 = Float(ox + g + inner), ay1 = Float(oy + g)
            let ax2 = Float(ox + g),         ay2 = Float(oy + g + inner)

            cornerUVs[f * 3 + 0] = SIMD2<Float>((ax0 + 0.5) / af, 1 - (ay0 + 0.5) / af)
            cornerUVs[f * 3 + 1] = SIMD2<Float>((ax1 + 0.5) / af, 1 - (ay1 + 0.5) / af)
            cornerUVs[f * 3 + 2] = SIMD2<Float>((ax2 + 0.5) / af, 1 - (ay2 + 0.5) / af)

            // Fallback colour so unseen triangles never leave grey holes.
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

            for py in oy...(oy + cell - 1) {
                let fy = Float(py) + 0.5
                for px in ox...(ox + cell - 1) {
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
                        let world = a * v0 + b * v1 + c * v2
                        if let uv = projectToImage(world, s) {
                            let texel = sampleBilinear(s, uv)
                            rr = texel.0; gg = texel.1; bb = texel.2
                        }
                    }
                    let idx = (py * atlas + px) * 4
                    buf[idx] = rr; buf[idx + 1] = gg; buf[idx + 2] = bb; buf[idx + 3] = 255
                }
            }
        }

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

/// Pre-resolved camera frame data for fast projection/sampling.
struct FrameSampler {
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

/// Project a world point into a frame, returning normalized image UV (origin
/// top-left), or nil if behind the camera or outside the image.
///
/// ARKit's camera space is +X right, +Y UP, looking down -Z. Image pixels run
/// with +y DOWN, so Y must be negated along with Z before applying intrinsics.
func projectToImage(_ world: SIMD3<Float>, _ s: FrameSampler) -> SIMD2<Float>? {
    let cp = s.view * SIMD4<Float>(world.x, world.y, world.z, 1)
    let depth = -cp.z
    guard depth > 0.001 else { return nil }
    let x = s.intr[0][0] * (cp.x / depth) + s.intr[2][0]
    let y = s.intr[1][1] * (-cp.y / depth) + s.intr[2][1]
    let u = x / s.sensorW
    let v = y / s.sensorH
    guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
    return SIMD2<Float>(u, v)
}

/// Bilinear sample a frame's pixels at normalized UV (origin top-left).
func sampleBilinear(_ s: FrameSampler, _ uv: SIMD2<Float>) -> (UInt8, UInt8, UInt8) {
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
