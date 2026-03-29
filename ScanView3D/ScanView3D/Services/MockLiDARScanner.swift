import Foundation
import Combine

#if targetEnvironment(simulator)

/// Mock LiDAR scanner for Simulator testing - generates a sample room mesh
class MockLiDARScanner: ObservableObject {
    @Published var isScanning = false
    @Published var isPaused = false
    @Published var scanProgress: String = "Ready to scan (Simulator Mode)"
    @Published var vertexCount: Int = 0
    @Published var faceCount: Int = 0
    @Published var confidenceThreshold: Float = 0.5
    @Published var scanError: String?
    @Published var capturedFrameCount: Int = 0
    @Published var isPreviewing = false
    @Published var memoryUsageMB: Double = 0
    @Published var estimatedFileSizeMB: Double = 0
    @Published var scanCapacityPercent: Double = 0

    private var scanTimer: Timer?
    private var simulatedProgress: Float = 0
    private var meshData: MeshData?
    private var scanRange: ScanSettings.ScanRange = .room
    private var scanQuality: ScanSettings.ScanQuality = .standard

    static var isLiDARAvailable: Bool { true }
    static var isLiDARWithClassificationAvailable: Bool { true }

    let textureMapper = TextureMapper()

    func startPreview() {
        isPreviewing = true
        scanProgress = "Point camera at area to scan"
    }

    func stopPreview() {
        isPreviewing = false
    }

    func startScanning(
        detail: ScanSettings.MeshDetail = .medium,
        captureTexture: Bool = true,
        range: ScanSettings.ScanRange = .room,
        quality: ScanSettings.ScanQuality = .standard
    ) {
        self.scanRange = range
        self.scanQuality = quality
        isScanning = true
        isPaused = false
        scanError = nil
        simulatedProgress = 0
        scanProgress = "Scanning... (Simulated)"

        // Simulate progressive mesh building
        scanTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self = self, !self.isPaused else { return }
            self.simulatedProgress += 0.05

            // Progressively increase counts to simulate real scanning
            let progress = min(self.simulatedProgress, 1.0)
            let totalVerts = Int(Float(Self.sampleRoomVertexCount) * progress)
            let totalFaces = Int(Float(Self.sampleRoomFaceCount) * progress)

            self.vertexCount = totalVerts
            self.faceCount = totalFaces
            self.scanProgress = "Scanning... \(Int(progress * 100))%"

            // Simulate frame capture count
            self.capturedFrameCount = Int(progress * Float(quality.maxTextureFrames))

            if self.simulatedProgress >= 1.0 {
                self.scanTimer?.invalidate()
                self.scanProgress = "Scan complete - \(self.vertexCount) vertices captured"
                self.meshData = Self.generateSampleRoomMesh(range: range)
            }
        }
    }

    func pauseScanning() {
        isPaused = true
        scanProgress = "Scanning paused"
    }

    func resumeScanning() {
        isPaused = false
        scanProgress = "Scanning resumed..."
    }

    func stopScanning() {
        scanTimer?.invalidate()
        scanTimer = nil
        isScanning = false
        isPaused = false

        if meshData == nil {
            meshData = Self.generateSampleRoomMesh(range: scanRange)
            vertexCount = meshData!.vertexCount
            faceCount = meshData!.faceCount
        }
        scanProgress = "Scan complete"
    }

    func resetScanning() {
        stopScanning()
        meshData = nil
        vertexCount = 0
        faceCount = 0
        capturedFrameCount = 0
        scanProgress = "Ready to scan (Simulator Mode)"
    }

    func getCombinedMeshData() -> MeshData? {
        return meshData ?? Self.generateSampleRoomMesh(range: scanRange)
    }

    func buildTextureAtlas(meshData: MeshData) -> TextureAtlasResult? {
        return nil // No real camera in simulator
    }

    // MARK: - Sample Room Mesh Generation

    private static let sampleRoomVertexCount = 1200
    private static let sampleRoomFaceCount = 2000

    /// Generates a sample room mesh with floor, walls, a table, and a chair
    static func generateSampleRoomMesh(range: ScanSettings.ScanRange = .room) -> MeshData {
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var faces: [[UInt32]] = []
        var colors: [SIMD4<Float>] = []

        // Scale room based on range
        let scale = min(range.maxDistance / 3.0, 1.0)

        // Room dimensions (meters)
        let roomWidth: Float = 4.0 * scale
        let roomDepth: Float = 5.0 * scale
        let roomHeight: Float = 2.8 * scale

        // Floor
        let floorColor = SIMD4<Float>(0.5, 0.5, 0.5, 1.0)
        addPlane(
            origin: SIMD3(-roomWidth / 2, 0, -roomDepth / 2),
            u: SIMD3(roomWidth, 0, 0),
            v: SIMD3(0, 0, roomDepth),
            normal: SIMD3(0, 1, 0),
            subdivisions: 8,
            color: floorColor,
            vertices: &vertices, normals: &normals, faces: &faces, colors: &colors
        )

        // Back wall
        let wallColor = SIMD4<Float>(0.9, 0.9, 0.85, 1.0)
        addPlane(
            origin: SIMD3(-roomWidth / 2, 0, -roomDepth / 2),
            u: SIMD3(roomWidth, 0, 0),
            v: SIMD3(0, roomHeight, 0),
            normal: SIMD3(0, 0, 1),
            subdivisions: 6,
            color: wallColor,
            vertices: &vertices, normals: &normals, faces: &faces, colors: &colors
        )

        // Left wall
        addPlane(
            origin: SIMD3(-roomWidth / 2, 0, -roomDepth / 2),
            u: SIMD3(0, 0, roomDepth),
            v: SIMD3(0, roomHeight, 0),
            normal: SIMD3(1, 0, 0),
            subdivisions: 6,
            color: wallColor,
            vertices: &vertices, normals: &normals, faces: &faces, colors: &colors
        )

        // Right wall
        addPlane(
            origin: SIMD3(roomWidth / 2, 0, -roomDepth / 2),
            u: SIMD3(0, 0, roomDepth),
            v: SIMD3(0, roomHeight, 0),
            normal: SIMD3(-1, 0, 0),
            subdivisions: 6,
            color: wallColor,
            vertices: &vertices, normals: &normals, faces: &faces, colors: &colors
        )

        // Front wall (partial - with doorway gap)
        addPlane(
            origin: SIMD3(-roomWidth / 2, 0, roomDepth / 2),
            u: SIMD3(roomWidth * 0.35, 0, 0),
            v: SIMD3(0, roomHeight, 0),
            normal: SIMD3(0, 0, -1),
            subdivisions: 4,
            color: wallColor,
            vertices: &vertices, normals: &normals, faces: &faces, colors: &colors
        )
        addPlane(
            origin: SIMD3(roomWidth * 0.15, 0, roomDepth / 2),
            u: SIMD3(roomWidth * 0.35, 0, 0),
            v: SIMD3(0, roomHeight, 0),
            normal: SIMD3(0, 0, -1),
            subdivisions: 4,
            color: wallColor,
            vertices: &vertices, normals: &normals, faces: &faces, colors: &colors
        )

        // Ceiling
        let ceilingColor = SIMD4<Float>(0.8, 0.8, 0.9, 1.0)
        addPlane(
            origin: SIMD3(-roomWidth / 2, roomHeight, -roomDepth / 2),
            u: SIMD3(roomWidth, 0, 0),
            v: SIMD3(0, 0, roomDepth),
            normal: SIMD3(0, -1, 0),
            subdivisions: 6,
            color: ceilingColor,
            vertices: &vertices, normals: &normals, faces: &faces, colors: &colors
        )

        // Table (in center of room)
        let tableColor = SIMD4<Float>(0.6, 0.4, 0.1, 1.0)
        let tableHeight: Float = 0.75 * scale
        let tableWidth: Float = 1.2 * scale
        let tableDepth: Float = 0.7 * scale
        let tableX: Float = 0.0
        let tableZ: Float = -0.5 * scale

        // Table top
        addBox(
            center: SIMD3(tableX, tableHeight, tableZ),
            size: SIMD3(tableWidth, 0.04, tableDepth),
            color: tableColor,
            vertices: &vertices, normals: &normals, faces: &faces, colors: &colors
        )

        // Table legs
        let legSize = SIMD3<Float>(0.05, tableHeight, 0.05)
        let legColor = SIMD4<Float>(0.5, 0.35, 0.1, 1.0)
        for (dx, dz) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] as [(Float, Float)] {
            let lx = tableX + Float(dx) * (tableWidth / 2 - 0.05)
            let lz = tableZ + Float(dz) * (tableDepth / 2 - 0.05)
            addBox(
                center: SIMD3(lx, tableHeight / 2, lz),
                size: legSize,
                color: legColor,
                vertices: &vertices, normals: &normals, faces: &faces, colors: &colors
            )
        }

        // Chair
        let chairColor = SIMD4<Float>(0.3, 0.6, 0.3, 1.0)
        let seatHeight: Float = 0.45 * scale
        let chairX: Float = 0.0
        let chairZ: Float = 0.6 * scale

        // Chair seat
        addBox(
            center: SIMD3(chairX, seatHeight, chairZ),
            size: SIMD3(0.45 * scale, 0.04, 0.45 * scale),
            color: chairColor,
            vertices: &vertices, normals: &normals, faces: &faces, colors: &colors
        )

        // Chair back
        addBox(
            center: SIMD3(chairX, seatHeight + 0.35 * scale, chairZ + 0.2 * scale),
            size: SIMD3(0.45 * scale, 0.7 * scale, 0.03),
            color: chairColor,
            vertices: &vertices, normals: &normals, faces: &faces, colors: &colors
        )

        // Chair legs
        let chairLegSize = SIMD3<Float>(0.03, seatHeight, 0.03)
        for (dx, dz) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] as [(Float, Float)] {
            let lx = chairX + Float(dx) * 0.18 * scale
            let lz = chairZ + Float(dz) * 0.18 * scale
            addBox(
                center: SIMD3(lx, seatHeight / 2, lz),
                size: chairLegSize,
                color: legColor,
                vertices: &vertices, normals: &normals, faces: &faces, colors: &colors
            )
        }

        // Calculate bounding box
        var minBound = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxBound = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        for vertex in vertices {
            minBound = min(minBound, vertex)
            maxBound = max(maxBound, vertex)
        }

        return MeshData(
            vertices: vertices,
            normals: normals,
            faces: faces,
            colors: colors,
            boundingBoxMin: minBound,
            boundingBoxMax: maxBound
        )
    }

    // MARK: - Geometry Helpers

    /// Adds a subdivided plane to the mesh arrays
    private static func addPlane(
        origin: SIMD3<Float>,
        u: SIMD3<Float>,
        v: SIMD3<Float>,
        normal: SIMD3<Float>,
        subdivisions: Int,
        color: SIMD4<Float>,
        vertices: inout [SIMD3<Float>],
        normals: inout [SIMD3<Float>],
        faces: inout [[UInt32]],
        colors: inout [SIMD4<Float>]
    ) {
        let baseIndex = UInt32(vertices.count)
        let n = subdivisions

        for j in 0...n {
            for i in 0...n {
                let s = Float(i) / Float(n)
                let t = Float(j) / Float(n)
                let pos = origin + u * s + v * t
                vertices.append(pos)
                normals.append(normal)
                // Slight color variation for visual interest
                let variation = Float.random(in: -0.03...0.03)
                colors.append(SIMD4(color.x + variation, color.y + variation, color.z + variation, color.w))
            }
        }

        let stride = UInt32(n + 1)
        for j in 0..<UInt32(n) {
            for i in 0..<UInt32(n) {
                let topLeft = baseIndex + j * stride + i
                let topRight = topLeft + 1
                let bottomLeft = topLeft + stride
                let bottomRight = bottomLeft + 1

                faces.append([topLeft, bottomLeft, topRight])
                faces.append([topRight, bottomLeft, bottomRight])
            }
        }
    }

    /// Adds a box (6 faces) to the mesh arrays
    private static func addBox(
        center: SIMD3<Float>,
        size: SIMD3<Float>,
        color: SIMD4<Float>,
        vertices: inout [SIMD3<Float>],
        normals: inout [SIMD3<Float>],
        faces: inout [[UInt32]],
        colors: inout [SIMD4<Float>]
    ) {
        let hw = size.x / 2, hh = size.y / 2, hd = size.z / 2

        // 6 faces, 4 vertices each
        let faceData: [(normal: SIMD3<Float>, offsets: [(Float, Float, Float)])] = [
            // Front
            (SIMD3(0, 0, 1), [(-hw, -hh, hd), (hw, -hh, hd), (hw, hh, hd), (-hw, hh, hd)]),
            // Back
            (SIMD3(0, 0, -1), [(hw, -hh, -hd), (-hw, -hh, -hd), (-hw, hh, -hd), (hw, hh, -hd)]),
            // Top
            (SIMD3(0, 1, 0), [(-hw, hh, hd), (hw, hh, hd), (hw, hh, -hd), (-hw, hh, -hd)]),
            // Bottom
            (SIMD3(0, -1, 0), [(-hw, -hh, -hd), (hw, -hh, -hd), (hw, -hh, hd), (-hw, -hh, hd)]),
            // Right
            (SIMD3(1, 0, 0), [(hw, -hh, hd), (hw, -hh, -hd), (hw, hh, -hd), (hw, hh, hd)]),
            // Left
            (SIMD3(-1, 0, 0), [(-hw, -hh, -hd), (-hw, -hh, hd), (-hw, hh, hd), (-hw, hh, -hd)])
        ]

        for face in faceData {
            let baseIndex = UInt32(vertices.count)
            for offset in face.offsets {
                vertices.append(center + SIMD3(offset.0, offset.1, offset.2))
                normals.append(face.normal)
                let variation = Float.random(in: -0.02...0.02)
                colors.append(SIMD4(color.x + variation, color.y + variation, color.z + variation, color.w))
            }
            faces.append([baseIndex, baseIndex + 1, baseIndex + 2])
            faces.append([baseIndex, baseIndex + 2, baseIndex + 3])
        }
    }
}

#endif
