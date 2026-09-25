#if !targetEnvironment(simulator)
import ARKit
import RealityKit
import Metal

/// Owned sensor data, never an ARFrame or retained ARKit texture. Capture and
/// preview use the same unprojection and confidence/range definition.
struct CaptureDepthFrame {
    let width: Int
    let height: Int
    let depth: [Float]
    let confidence: [UInt8]
    let cameraToWorld: simd_float4x4
    let intrinsics: SIMD4<Float> // fx, fy, cx, cy in depth pixels
    let timestamp: TimeInterval

    init?(_ frame: ARFrame) {
        guard let data = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let map = data.depthMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        width = CVPixelBufferGetWidth(map); height = CVPixelBufferGetHeight(map)
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(map)).assumingMemoryBound(to: Float.self)
            for x in 0..<width { values[y * width + x] = row[x] }
        }
        depth = values
        var confidenceValues = [UInt8](repeating: 0, count: width * height)
        if let map = data.confidenceMap, CVPixelBufferGetWidth(map) == width, CVPixelBufferGetHeight(map) == height {
            CVPixelBufferLockBaseAddress(map, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(map) {
                for y in 0..<height {
                    let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(map)).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width { confidenceValues[y * width + x] = row[x] }
                }
            }
            CVPixelBufferUnlockBaseAddress(map, .readOnly)
        }
        confidence = confidenceValues
        let k = frame.camera.intrinsics, size = frame.camera.imageResolution
        let sx = Float(width) / Float(size.width), sy = Float(height) / Float(size.height)
        intrinsics = SIMD4(k[0][0] * sx, k[1][1] * sy, k[2][0] * sx, k[2][1] * sy)
        cameraToWorld = frame.camera.transform
        timestamp = frame.timestamp
    }

    func cameraPoint(at i: Int) -> SIMD3<Float> {
        let d = depth[i]
        return SIMD3((Float(i % width) + 0.5 - intrinsics.z) / intrinsics.x * d,
                     -(Float(i / width) + 0.5 - intrinsics.w) / intrinsics.y * d, -d)
    }

    func accepts(_ i: Int, range: Float) -> Bool {
        confidence[i] >= (depth[i] > 3 ? 2 : 1) && CaptureRange.accepts(cameraPoint(at: i), metres: range)
    }

    func photoMask(range: Float) -> PhotoRangeMask {
        let pixels = depth.indices.map { accepts($0, range: range) ? UInt8(255) : 0 }
        return PhotoRangeMask(width: width, height: height, pixels: Data(pixels), rangeMetres: range).eroded()
    }
}

struct AcceptedDepthFrame {
    let frame: CaptureDepthFrame
    let depth: [Float] // zero means NOT committed to the capture
}

/// Display-only effect: accepted depth reprojects into the current camera every
/// rendered frame, with an occlusion test. No replacement-mesh flicker.
final class LiveCaptureFeedback {
    private struct Uniforms {
        var cameraToWorld: simd_float4x4
        var worldToAcceptedCamera: simd_float4x4
        var displayToImage: simd_float3x3
        var intrinsics: SIMD4<Float>
        var acceptedIntrinsics: SIMD4<Float>
        var parameters: SIMD4<Float>
    }
    private struct State {
        let current: MTLTexture
        let accepted: MTLTexture
        let uniforms: Uniforms
    }
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private let lock = NSLock()
    private var state: State?
    private var acceptedTime: TimeInterval = -1
    private var acceptedTexture: MTLTexture?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "captureFeedback"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        self.device = device; self.pipeline = pipeline
    }

    func reset() {
        lock.lock(); state = nil; lock.unlock()
        acceptedTime = -1; acceptedTexture = nil
    }

    // Each texture is immutable after publication to the render thread.
    func update(frame: ARFrame, accepted: AcceptedDepthFrame?, viewport: CGSize,
                orientation: UIInterfaceOrientation, range: Float, showCoverage: Bool) {
        guard let sensor = CaptureDepthFrame(frame), let current = texture(sensor.depth, width: sensor.width, height: sensor.height) else {
            lock.lock(); state = nil; lock.unlock(); return
        }
        if let accepted, accepted.frame.timestamp != acceptedTime {
            acceptedTexture = texture(accepted.depth, width: accepted.frame.width, height: accepted.frame.height)
            acceptedTime = accepted.frame.timestamp
        }
        let previous = accepted?.frame ?? sensor
        let t = frame.displayTransform(for: orientation, viewportSize: viewport).inverted()
        let displayToImage = simd_float3x3(SIMD3(Float(t.a), Float(t.b), 0),
            SIMD3(Float(t.c), Float(t.d), 0), SIMD3(Float(t.tx), Float(t.ty), 1))
        let k = previous.intrinsics
        let normalizedK = SIMD4(k.x / Float(previous.width), k.y / Float(previous.height),
            k.z / Float(previous.width), k.w / Float(previous.height))
        var reliable = false
        if case .normal = frame.camera.trackingState { reliable = true }
        let uniforms = Uniforms(cameraToWorld: sensor.cameraToWorld,
            worldToAcceptedCamera: previous.cameraToWorld.inverse, displayToImage: displayToImage,
            intrinsics: sensor.intrinsics, acceptedIntrinsics: normalizedK,
            parameters: SIMD4(range, showCoverage && reliable && acceptedTexture != nil ? 1 : 0,
                Float(sensor.width), Float(sensor.height)))
        let newState = State(current: current, accepted: acceptedTexture ?? current, uniforms: uniforms)
        lock.lock(); state = newState; lock.unlock()
    }

    private func texture(_ values: [Float], width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        values.withUnsafeBytes { raw in
            if let address = raw.baseAddress {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: address, bytesPerRow: width * MemoryLayout<Float>.stride)
            }
        }
        return texture
    }

    func render(_ context: ARView.PostProcessContext) {
        lock.lock(); let currentState = state; lock.unlock()
        // Source and destination may have different pixel formats; a blit-copy
        // is not a valid passthrough. Let the shader do the conversion instead.
        let state = currentState ?? State(current: context.sourceColorTexture, accepted: context.sourceColorTexture,
            uniforms: Uniforms(cameraToWorld: matrix_identity_float4x4, worldToAcceptedCamera: matrix_identity_float4x4,
                displayToImage: matrix_identity_float3x3, intrinsics: .zero, acceptedIntrinsics: .zero,
                parameters: SIMD4(-1, 0, 1, 1)))
        guard let encoder = context.commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(context.sourceColorTexture, index: 0)
        encoder.setTexture(context.targetColorTexture, index: 1)
        encoder.setTexture(state.current, index: 2)
        encoder.setTexture(state.accepted, index: 3)
        var uniforms = state.uniforms
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        let width = pipeline.threadExecutionWidth
        let group = MTLSize(width: width, height: min(8, pipeline.maxTotalThreadsPerThreadgroup / width), depth: 1)
        encoder.dispatchThreads(MTLSize(width: context.targetColorTexture.width,
            height: context.targetColorTexture.height, depth: 1), threadsPerThreadgroup: group)
        encoder.endEncoding()
    }
}
#endif
