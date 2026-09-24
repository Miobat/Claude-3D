import UIKit
import CoreVideo
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import simd
import os
#if !targetEnvironment(simulator)
import ARKit
#endif

/// A camera keyframe kept for colouring the scan. The image lives on disk as a
/// full-resolution JPEG, so we can keep many sharp frames without using much
/// memory; only one is decoded at a time when colouring.
struct CapturedFrame {
    let imageURL: URL
    let transform: simd_float4x4
    let intrinsics: simd_float3x3
    let imageWidth: Int          // sensor image size that `intrinsics` refer to
    let imageHeight: Int
    let timestamp: TimeInterval
    /// LiDAR depth (metres) seen from this camera, for occlusion tests.
    let depth: [Float]
    let depthWidth: Int
    let depthHeight: Int
    /// Brightness correction relative to the first frame (exposure changes).
    let gain: Float
}

/// Captures keyframes during scanning and projects them onto the mesh.
///
/// Quality measures:
/// - keyframes are chosen by movement, not time, and blurry frames are skipped
/// - each frame keeps its LiDAR depth, so surfaces hidden from a camera (e.g. a
///   wall behind a chair) are never coloured from it
/// - brightness is normalised between frames to reduce colour seams
///
/// Thread-safety: frames are appended on a private queue and read under a lock.
class TextureMapper {

    // MARK: - Properties

    private let lock = NSLock()
    private let epoch = CaptureEpoch()
    private var frames: [CapturedFrame] = []
    private let captureQueue = DispatchQueue(label: "scanview.texture.capture", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var folder: URL?
    private var fileCounter = 0

    // Main-thread capture state
    private var conversionInFlight = false
    private var lastKeptTransform: simd_float4x4?
    private var lastKeptTime: TimeInterval = 0
    private var lastTickTransform: simd_float4x4?
    private var lastTickTime: TimeInterval = 0
    private var referenceExposure: Double?

    private var maxFrames: Int = 200
    private var maxImageWidth: Int = 1920
    private let minKeyframeMove: Float = 0.08          // metres
    private let minKeyframeTurn: Float = 7 * .pi / 180 // radians
    private let maxBlurPixels: Double = 2.5

    var capturedFrames: [CapturedFrame] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    var frameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return frames.count
    }

    /// Memory held by kept frames (images are on disk; only depth maps are in RAM).
    var estimatedMemoryUsageMB: Double {
        Double(capturedFrames.reduce(0) { $0 + $1.depth.count * 4 }) / (1024.0 * 1024.0)
    }

    var estimatedAtlasSizeMB: Double {
        frameCount == 0 ? 0 : 12
    }

    // MARK: - Configuration

    func configure(quality: ScanSettings.ScanQuality) {
        maxFrames = max(quality.maxTextureFrames, 200)
        maxImageWidth = 1920
    }

    func reset() {
        epoch.invalidate()
        conversionInFlight = false
        lock.lock()
        frames.removeAll()
        lock.unlock()
        if let f = folder { try? FileManager.default.removeItem(at: f) }
        folder = nil
        fileCounter = 0
        lastKeptTransform = nil
        lastKeptTime = 0
        lastTickTransform = nil
        lastTickTime = 0
        referenceExposure = nil
    }

    /// No new frames may be accepted while draining. Count callbacks are queued
    /// on main before this completion, so finalization sees the complete result.
    func drain(completion: @escaping () -> Void) {
        captureQueue.async { DispatchQueue.main.async(execute: completion) }
    }

    private func frameFolder() -> URL? {
        if let f = folder { return f }
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("texframes-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)) != nil else { return nil }
        folder = f
        return f
    }

    // MARK: - Frame Capture

    #if !targetEnvironment(simulator)
    /// Call on the main thread for each candidate frame (tracking must be normal).
    /// Keeps it only if the camera moved enough since the last keyframe and the
    /// image isn't blurred by motion.
    func captureFrame(from arFrame: ARFrame, exposure: (iso: Double, duration: Double)? = nil,
                      onCountChanged: ((Int) -> Void)? = nil) {
        let now = arFrame.timestamp
        let transform = arFrame.camera.transform

        // Motion blur estimate from the movement since the previous timer tick.
        var blurPixels = 0.0
        if let prev = lastTickTransform, now > lastTickTime {
            let dt = now - lastTickTime
            let turn = TextureMapper.angle(between: prev, and: transform)
            let move = simd_distance(prev.position, transform.position)
            let exposureTime = arFrame.camera.exposureDuration > 0 ? arFrame.camera.exposureDuration : 1.0 / 60.0
            let fx = Double(arFrame.camera.intrinsics[0][0])
            // Rotation smear + translation smear for a surface ~1.5 m away.
            blurPixels = (Double(turn) / dt + Double(move) / dt / 1.5) * exposureTime * fx
        }
        lastTickTransform = transform
        lastTickTime = now

        guard !conversionInFlight, blurPixels <= maxBlurPixels, now - lastKeptTime >= 0.2 else { return }
        if let last = lastKeptTransform {
            let moved = simd_distance(last.position, transform.position)
            let turned = TextureMapper.angle(between: last, and: transform)
            guard moved >= minKeyframeMove || turned >= minKeyframeTurn else { return }
        }
        guard let dir = frameFolder() else { return }

        lastKeptTransform = transform
        lastKeptTime = now
        conversionInFlight = true

        // Exposure normalisation: brightness ∝ ISO × exposure time.
        var gain: Float = 1
        if let e = exposure, e.iso > 0, e.duration > 0 {
            let value = e.iso * e.duration
            if let ref = referenceExposure {
                gain = Float(min(1.6, max(0.6, ref / value)))
            } else {
                referenceExposure = value
            }
        }

        let pixelBuffer = arFrame.capturedImage
        let depthBuffer = (arFrame.smoothedSceneDepth ?? arFrame.sceneDepth)?.depthMap
        let intrinsics = arFrame.camera.intrinsics
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let maxWidth = maxImageWidth
        let limit = maxFrames
        fileCounter += 1
        let url = dir.appendingPathComponent(String(format: "f_%05d.jpg", fileCounter))
        let token = epoch.current

        captureQueue.async { [weak self] in
            guard let self = self else { return }
            var count = 0
            let depth = TextureMapper.copyDepth(depthBuffer)
            if self.writeJPEG(pixelBuffer, maxWidth: maxWidth, to: url) {
                let frame = CapturedFrame(imageURL: url, transform: transform, intrinsics: intrinsics,
                                          imageWidth: width, imageHeight: height, timestamp: now,
                                          depth: depth.values, depthWidth: depth.width, depthHeight: depth.height,
                                          gain: gain)
                let accepted = self.epoch.withCurrent(token) {
                    self.lock.lock()
                    if self.frames.count >= limit { self.removeRedundantFrameLocked() }
                    self.frames.append(frame)
                    count = self.frames.count
                    self.lock.unlock()
                }
                if !accepted { try? FileManager.default.removeItem(at: url) }
            }
            DispatchQueue.main.async {
                guard self.epoch.isCurrent(token) else { return }
                self.conversionInFlight = false
                if count > 0 { onCountChanged?(count) }
            }
        }
    }

    private static func copyDepth(_ buffer: CVPixelBuffer?) -> (values: [Float], width: Int, height: Int) {
        guard let buffer = buffer, CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else {
            return ([], 0, 0)
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return ([], 0, 0) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<w { values[y * w + x] = row[x] }
        }
        return (values, w, h)
    }
    #endif

    private func writeJPEG(_ pixelBuffer: CVPixelBuffer, maxWidth: Int, to url: URL) -> Bool {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = min(1.0, Double(maxWidth) / Double(CVPixelBufferGetWidth(pixelBuffer)))
        if scale < 1.0 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let data = ciContext.jpegRepresentation(
                of: image, colorSpace: space,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.85])
        else { return false }
        return (try? data.write(to: url)) != nil
    }

    static func angle(between a: simd_float4x4, and b: simd_float4x4) -> Float {
        let fa = -SIMD3<Float>(a.columns.2.x, a.columns.2.y, a.columns.2.z)
        let fb = -SIMD3<Float>(b.columns.2.x, b.columns.2.y, b.columns.2.z)
        return acos(min(1, max(-1, simd_dot(fa, fb))))
    }

    /// Drop the frame most similar to its predecessor (direction AND position).
    /// Caller must hold `lock`.
    private func removeRedundantFrameLocked() {
        guard frames.count >= 3 else {
            if frames.count >= 2 { try? FileManager.default.removeItem(at: frames[0].imageURL); frames.removeFirst() }
            return
        }
        var minCost: Float = .greatestFiniteMagnitude
        var removeIndex = 1
        for i in 1..<frames.count - 1 {
            let a = frames[i].transform, b = frames[i - 1].transform
            let cost = TextureMapper.angle(between: a, and: b) + simd_distance(a.position, b.position)
            if cost < minCost { minCost = cost; removeIndex = i }
        }
        try? FileManager.default.removeItem(at: frames[removeIndex].imageURL)
        frames.remove(at: removeIndex)
    }

    // MARK: - Choosing frames

    /// Poses of all frames, resolved once.
    private func makePoses() -> [FramePose] {
        capturedFrames.map { f in
            FramePose(view: f.transform.inverse, intrinsics: f.intrinsics,
                      sensorW: Float(f.imageWidth), sensorH: Float(f.imageHeight),
                      position: f.transform.position,
                      forward: -SIMD3<Float>(f.transform.columns.2.x, f.transform.columns.2.y, f.transform.columns.2.z),
                      depth: f.depth, depthW: f.depthWidth, depthH: f.depthHeight)
        }
    }

    // MARK: - Vertex Color Sampling

    /// One colour per vertex, from the best frame that actually sees it.
    func sampleVertexColors(vertices: [SIMD3<Float>], normals: [SIMD3<Float>]) -> [SIMD4<Float>] {
        let fallback = SIMD4<Float>(0.7, 0.7, 0.7, 1.0)
        var colors = [SIMD4<Float>](repeating: fallback, count: vertices.count)
        let poses = makePoses()
        let frameList = capturedFrames
        guard !poses.isEmpty else { return colors }

        // 1. Best frame for each vertex (geometry only — no pixels needed).
        var choice = [Int32](repeating: -1, count: vertices.count)
        var choiceUV = [SIMD2<Float>](repeating: .zero, count: vertices.count)
        for i in 0..<vertices.count {
            let v = vertices[i]
            let n = i < normals.count ? normals[i] : SIMD3<Float>(0, 1, 0)
            var bestScore: Float = 0
            for (fi, pose) in poses.enumerated() {
                let toV = v - pose.position
                let dist = simd_length(toV)
                guard dist > 0.05 else { continue }
                let dir = toV / dist
                let facing = -simd_dot(n, dir)
                guard facing > 0.05 else { continue }
                let viewAlign = simd_dot(dir, pose.forward)
                guard viewAlign > 0.2 else { continue }
                guard let proj = pose.project(v), proj.uv.x >= 0.02, proj.uv.x <= 0.98,
                      proj.uv.y >= 0.02, proj.uv.y <= 0.98, pose.isVisible(proj) else { continue }
                let center = max(0, 1 - simd_length(proj.uv - SIMD2<Float>(0.5, 0.5)) * 1.5)
                let score = facing * viewAlign * center / max(dist, 0.2)
                if score > bestScore { bestScore = score; choice[i] = Int32(fi); choiceUV[i] = proj.uv }
            }
        }

        // 2. Sample, decoding one frame image at a time.
        var byFrame = [[Int]](repeating: [], count: poses.count)
        for i in 0..<vertices.count where choice[i] >= 0 { byFrame[Int(choice[i])].append(i) }
        for (fi, members) in byFrame.enumerated() where !members.isEmpty {
            autoreleasepool {
                guard let image = DecodedImage(url: frameList[fi].imageURL) else { return }
                let gain = frameList[fi].gain
                for i in members {
                    colors[i] = image.sample(choiceUV[i], gain: gain)
                }
            }
        }
        return colors
    }

    // MARK: - High-Resolution Texture Baking (photo patches)

    /// Bake the photos into a texture atlas. Neighbouring triangles that are
    /// best seen by the same photo form one patch, and that part of the photo is
    /// copied into the atlas at full resolution — so text and fine detail stay
    /// readable and there are no seams inside a patch. Patches are shrunk evenly
    /// only if everything wouldn't fit.
    func bakeTexture(meshData: MeshData, atlasSize requestedSize: Int = 8192) -> BakedTexture? {
        let faceCount = meshData.faces.count
        let poses = makePoses()
        let frameList = capturedFrames
        let vertexCount = meshData.vertices.count
        guard faceCount > 0, !poses.isEmpty else { return nil }

        func corners(_ f: Int) -> (Int, Int, Int)? {
            let face = meshData.faces[f]
            guard face.count == 3 else { return nil }
            let a = Int(face[0]), b = Int(face[1]), c = Int(face[2])
            guard a < vertexCount, b < vertexCount, c < vertexCount else { return nil }
            return (a, b, c)
        }

        // How well frame `fi` sees face `f` (0 = not usable).
        func score(_ f: Int, _ fi: Int) -> Float {
            guard case let (a, b, c)? = corners(f) else { return 0 }
            let v0 = meshData.vertices[a], v1 = meshData.vertices[b], v2 = meshData.vertices[c]
            var n = simd_cross(v1 - v0, v2 - v0)
            let len = simd_length(n)
            guard len > 1e-10 else { return 0 }
            n /= len
            let pose = poses[fi]
            let centroid = (v0 + v1 + v2) / 3
            let toC = centroid - pose.position
            let dist = simd_length(toC)
            guard dist > 1e-3 else { return 0 }
            let dir = toC / dist
            let viewAlign = simd_dot(dir, pose.forward)
            let facing = abs(simd_dot(n, dir))
            guard viewAlign > 0.15, facing > 0.1,
                  let pc = pose.project(centroid), pose.isVisible(pc),
                  pose.project(v0) != nil, pose.project(v1) != nil, pose.project(v2) != nil else { return 0 }
            // Prefer close, head-on views near the image centre.
            let centre = max(0.2, 1 - simd_length(pc.uv - SIMD2<Float>(0.5, 0.5)))
            return facing * viewAlign * centre / (dist * dist)
        }

        // 1. Best frame per triangle.
        var faceFrame = [Int32](repeating: -1, count: faceCount)
        for f in 0..<faceCount {
            var best: Float = 0
            for fi in 0..<poses.count {
                let s = score(f, fi)
                if s > best { best = s; faceFrame[f] = Int32(fi) }
            }
        }

        // 2. Edge neighbours, then smooth the choice so patches are large:
        //    adopt the neighbours' frame when most of them use it and it sees us.
        var edgeFirstFace: [UInt64: Int32] = [:]
        var neighbours = [[Int32]](repeating: [], count: faceCount)
        for f in 0..<faceCount {
            guard case let (a, b, c)? = corners(f) else { continue }
            for (p, q) in [(a, b), (b, c), (c, a)] {
                let key = UInt64(min(p, q)) << 32 | UInt64(max(p, q))
                if let other = edgeFirstFace[key] {
                    neighbours[f].append(other)
                    neighbours[Int(other)].append(Int32(f))
                } else {
                    edgeFirstFace[key] = Int32(f)
                }
            }
        }
        edgeFirstFace.removeAll()
        for _ in 0..<2 {
            for f in 0..<faceCount where !neighbours[f].isEmpty {
                var counts: [Int32: Int] = [:]
                for nb in neighbours[f] where faceFrame[Int(nb)] >= 0 { counts[faceFrame[Int(nb)], default: 0] += 1 }
                guard let best = counts.max(by: { $0.value < $1.value }),
                      best.key != faceFrame[f], best.value >= 2, score(f, Int(best.key)) > 0 else { continue }
                faceFrame[f] = best.key
            }
        }

        // 3. Patches = connected triangles sharing a frame (union-find).
        var parent = Array(0..<faceCount)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        for f in 0..<faceCount where faceFrame[f] >= 0 {
            for nb in neighbours[f] where faceFrame[Int(nb)] == faceFrame[f] {
                let ra = find(f), rb = find(Int(nb))
                if ra != rb { parent[ra] = rb }
            }
        }
        neighbours.removeAll()

        struct Patch {
            var frame: Int
            var faces: [Int] = []
            var uvMin = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
            var uvMax = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
            var pixelSize = SIMD2<Float>(0, 0)      // in the stored photo
            var origin = SIMD2<Int>(0, 0)           // in the atlas
        }
        var patchIndex: [Int: Int] = [:]
        var patches: [Patch] = []
        var cornerImageUV = [SIMD2<Float>](repeating: .zero, count: faceCount * 3)
        var untextured: [Int] = []
        for f in 0..<faceCount {
            guard faceFrame[f] >= 0, case let (a, b, c)? = corners(f) else { untextured.append(f); continue }
            let fi = Int(faceFrame[f])
            let pose = poses[fi]
            guard let p0 = pose.project(meshData.vertices[a]), let p1 = pose.project(meshData.vertices[b]),
                  let p2 = pose.project(meshData.vertices[c]) else { untextured.append(f); continue }
            let root = find(f)
            let pi: Int
            if let existing = patchIndex[root] { pi = existing } else {
                pi = patches.count
                patchIndex[root] = pi
                patches.append(Patch(frame: fi))
            }
            patches[pi].faces.append(f)
            for (k, p) in [p0, p1, p2].enumerated() {
                cornerImageUV[f * 3 + k] = p.uv
                patches[pi].uvMin = simd_min(patches[pi].uvMin, p.uv)
                patches[pi].uvMax = simd_max(patches[pi].uvMax, p.uv)
            }
        }
        for i in patches.indices {
            let f = frameList[patches[i].frame]
            let storedW = Float(min(f.imageWidth, maxImageWidth))
            let storedH = Float(f.imageHeight) * storedW / Float(max(f.imageWidth, 1))
            patches[i].pixelSize = (patches[i].uvMax - patches[i].uvMin) * SIMD2<Float>(storedW, storedH)
        }

        // 4. Pack patches into the atlas (shelves), shrinking evenly if needed.
        let atlas = TextureMapper.affordableAtlasSize(max(2048, min(requestedSize, 8192)))
        let pad = 3
        let reserved = 8      // grey tile for triangles no photo sees
        let totalArea = patches.reduce(Float(0)) { $0 + ($1.pixelSize.x + Float(2 * pad)) * ($1.pixelSize.y + Float(2 * pad)) }
        var scale = min(1, (Float(atlas * atlas) * 0.8 / max(totalArea, 1)).squareRoot())
        let order = patches.indices.sorted { patches[$0].pixelSize.y > patches[$1].pixelSize.y }
        var packed = false
        for _ in 0..<30 {
            var x = reserved + pad, y = 0, shelf = 0
            var ok = true
            for i in order {
                let w = Int((patches[i].pixelSize.x * scale).rounded(.up)) + 2 * pad
                let h = Int((patches[i].pixelSize.y * scale).rounded(.up)) + 2 * pad
                if x + w > atlas { x = 0; y += shelf; shelf = 0 }
                if w > atlas || y + h > atlas { ok = false; break }
                patches[i].origin = SIMD2<Int>(x, y)
                x += w
                shelf = max(shelf, h)
            }
            if ok { packed = true; break }
            scale *= 0.9
        }
        guard packed else { return nil }

        let count = atlas * atlas * 4
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        buf.initialize(repeating: 150, count: count)
        var ai = 3
        while ai < count { buf[ai] = 255; ai += 4 }

        // 5. Copy each patch's region of its photo (plus padding, so edges blend).
        var byFrame = [[Int]](repeating: [], count: poses.count)
        for i in patches.indices { byFrame[patches[i].frame].append(i) }
        let supersample = scale < 0.75
        for (fi, members) in byFrame.enumerated() where !members.isEmpty {
            autoreleasepool {
                guard let image = DecodedImage(url: frameList[fi].imageURL) else { return }
                let gain = frameList[fi].gain
                let f = frameList[fi]
                let storedW = Float(min(f.imageWidth, maxImageWidth))
                let storedH = Float(f.imageHeight) * storedW / Float(max(f.imageWidth, 1))
                for i in members {
                    let p = patches[i]
                    let w = Int((p.pixelSize.x * scale).rounded(.up)) + 2 * pad
                    let h = Int((p.pixelSize.y * scale).rounded(.up)) + 2 * pad
                    for ty in 0..<h {
                        let ay = p.origin.y + ty
                        guard ay < atlas else { continue }
                        let py = p.uvMin.y * storedH + (Float(ty - pad) + 0.5) / scale
                        for tx in 0..<w {
                            let ax = p.origin.x + tx
                            guard ax < atlas else { continue }
                            let px = p.uvMin.x * storedW + (Float(tx - pad) + 0.5) / scale
                            var c = image.sample(SIMD2<Float>(px / storedW, py / storedH), gain: gain)
                            if supersample {
                                // Average 2×2 samples when shrinking, so fine detail
                                // (e.g. text) doesn't turn into moiré.
                                let o = 0.25 / scale
                                c += image.sample(SIMD2<Float>((px + o) / storedW, py / storedH), gain: gain)
                                c += image.sample(SIMD2<Float>(px / storedW, (py + o) / storedH), gain: gain)
                                c += image.sample(SIMD2<Float>((px + o) / storedW, (py + o) / storedH), gain: gain)
                                c *= 0.25
                            }
                            let idx = (ay * atlas + ax) * 4
                            buf[idx] = UInt8(max(0, min(255, c.x * 255)))
                            buf[idx + 1] = UInt8(max(0, min(255, c.y * 255)))
                            buf[idx + 2] = UInt8(max(0, min(255, c.z * 255)))
                        }
                    }
                }
            }
        }

        // 6. UVs per face corner (OBJ convention: origin bottom-left).
        let af = Float(atlas)
        var cornerUVs = [SIMD2<Float>](repeating: SIMD2<Float>(Float(reserved) / 2 / af, 1 - Float(reserved) / 2 / af),
                                        count: faceCount * 3)
        for p in patches {
            let f = frameList[p.frame]
            let storedW = Float(min(f.imageWidth, maxImageWidth))
            let storedH = Float(f.imageHeight) * storedW / Float(max(f.imageWidth, 1))
            let size = SIMD2<Float>(storedW, storedH)
            for face in p.faces {
                for k in 0..<3 {
                    let pixel = (cornerImageUV[face * 3 + k] - p.uvMin) * size * scale
                    let ax = Float(p.origin.x + pad) + pixel.x
                    let ay = Float(p.origin.y + pad) + pixel.y
                    cornerUVs[face * 3 + k] = SIMD2<Float>(ax / af, 1 - ay / af)
                }
            }
        }
        _ = untextured   // these keep the grey tile UVs set above

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: buf, width: atlas, height: atlas, bitsPerComponent: 8,
                                  bytesPerRow: atlas * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage() else {
            buf.deallocate()
            return nil
        }
        buf.deallocate()
        DebugLogger.shared.info("Baked \(patches.count) photo patches into \(atlas)px atlas at \(Int(scale * 100))% resolution", category: "Texture")
        return BakedTexture(atlasImage: UIImage(cgImage: cg), cornerUVs: cornerUVs, atlasSize: atlas)
    }

    /// Largest atlas that comfortably fits in the memory the app has left.
    static func affordableAtlasSize(_ requested: Int) -> Int {
        let available = Double(os_proc_available_memory())
        guard available > 0 else { return requested }   // simulator / unknown
        var size = requested
        while size > 2048 && Double(size * size * 4) * 3 > available { size /= 2 }
        return size
    }
}

// MARK: - Support types

/// A baked UV texture atlas. `cornerUVs` holds 3 entries per face (per-corner),
/// flattened so face f uses indices [3f, 3f+1, 3f+2]. UVs use SceneKit/OBJ
/// convention (origin bottom-left).
struct BakedTexture {
    let atlasImage: UIImage
    let cornerUVs: [SIMD2<Float>]
    let atlasSize: Int
}

/// A frame's camera, resolved once for fast projection and visibility tests.
struct FramePose {
    let view: simd_float4x4
    let intrinsics: simd_float3x3
    let sensorW: Float
    let sensorH: Float
    let position: SIMD3<Float>
    let forward: SIMD3<Float>
    let depth: [Float]
    let depthW: Int
    let depthH: Int

    struct Projection {
        let uv: SIMD2<Float>   // normalised image coords, origin top-left
        let depth: Float       // distance along the camera axis (m)
    }

    /// ARKit camera space is +X right, +Y UP, looking down -Z; image pixels have
    /// +y DOWN, so Y is negated along with Z before applying the intrinsics.
    func project(_ world: SIMD3<Float>) -> Projection? {
        let cp = view * SIMD4<Float>(world.x, world.y, world.z, 1)
        let d = -cp.z
        guard d > 0.001 else { return nil }
        let x = intrinsics[0][0] * (cp.x / d) + intrinsics[2][0]
        let y = intrinsics[1][1] * (-cp.y / d) + intrinsics[2][1]
        let u = x / sensorW, v = y / sensorH
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        return Projection(uv: SIMD2<Float>(u, v), depth: d)
    }

    /// False if the LiDAR depth shows something closer in front of the point
    /// (i.e. the point is hidden from this camera).
    func isVisible(_ p: Projection) -> Bool {
        guard depthW > 0, depthH > 0, depth.count == depthW * depthH else { return true }
        let x = min(depthW - 1, max(0, Int(p.uv.x * Float(depthW))))
        let y = min(depthH - 1, max(0, Int(p.uv.y * Float(depthH))))
        let measured = depth[y * depthW + x]
        guard measured.isFinite, measured > 0.05 else { return true }
        return p.depth <= measured + max(0.05, measured * 0.04)
    }
}

/// A decoded JPEG in a known RGBA byte layout, sampled bilinearly.
final class DecodedImage {
    private let pixels: [UInt8]
    let width: Int
    let height: Int

    init?(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        width = cg.width
        height = cg.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: cg.width, height: cg.height,
                                      bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return true
        }
        guard ok else { return nil }
        pixels = buffer
    }

    /// Bilinear sample at normalised uv (origin top-left), with brightness gain.
    func sample(_ uv: SIMD2<Float>, gain: Float) -> SIMD4<Float> {
        let fx = max(0, uv.x * Float(width) - 0.5)
        let fy = max(0, uv.y * Float(height) - 0.5)
        let x0 = min(Int(fx), width - 1), y0 = min(Int(fy), height - 1)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)

        func px(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let o = (y * width + x) * 4
            return SIMD3<Float>(Float(pixels[o]), Float(pixels[o + 1]), Float(pixels[o + 2]))
        }
        let top = px(x0, y0) * (1 - tx) + px(x1, y0) * tx
        let bottom = px(x0, y1) * (1 - tx) + px(x1, y1) * tx
        var c = (top * (1 - ty) + bottom * ty) / 255
        if gain != 1 {
            // Gain is linear light; pixels are sRGB (≈ gamma 2.2).
            c = simd_min(c * powf(gain, 1 / 2.2), SIMD3<Float>(repeating: 1))
        }
        return SIMD4<Float>(c.x, c.y, c.z, 1)
    }
}
