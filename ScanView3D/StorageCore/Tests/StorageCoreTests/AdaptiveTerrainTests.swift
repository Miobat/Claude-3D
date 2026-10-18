import Foundation
import XCTest
import simd
@testable import StorageCore

final class AdaptiveTerrainTests: XCTestCase {
    typealias Observation = AdaptiveTerrainSampler.Observation
    private let camera = SIMD3<Float>(0, 1.5, 0)

    private func surface(step: Float = 0.05, height: (Float, Float) -> Float) -> [Observation] {
        var result: [Observation] = []
        let n = Int(2.4 / step)
        for z in 0..<n { for x in 0..<n {
            let px = Float(x) * step - 1.2 + 0.003, pz = Float(z) * step - 1.2 + 0.003
            result.append(Observation(position: SIMD3(px, height(px, pz), pz)))
        } }
        return result
    }

    private func scan(_ source: [Observation], frames: Int = 8,
                      capacity: Int = 200_000, cache: Int = 2_000) -> AdaptiveTerrainSampler {
        let sampler = AdaptiveTerrainSampler(capacity: capacity, activeCellLimit: cache)
        for frame in 0..<frames {
            sampler.integrate(source, camera: camera, range: 5, timestamp: Double(frame) * 0.3)
        }
        return sampler
    }

    private func fixedCount(_ source: [Observation], spacing: Float) -> Int {
        Set(source.compactMap { TerrainCapture.key($0.position, spacing: spacing) }).count
    }

    func testFlatGroundBecomesCoarseWithoutMovingAnyPoint() {
        let source = surface { _, _ in 0.25 }, sampler = scan(source)
        let output = sampler.snapshot().map(\.position)
        // Unobserved outer margins stay fine/uncertain; supported interior is coarse.
        XCTAssertLessThan(output.count, fixedCount(source, spacing: 0.05) / 2)
        XCTAssertTrue(Set(output).isSubset(of: Set(source.map(\.position))))
        XCTAssertEqual(output.count, sampler.pointCount)
        XCTAssertEqual(sampler.level(at: SIMD3(0.003, 0.25, 0.003)), .coarse)
    }

    func testSmoothSlopeIsSparseRegardlessOfSteepness() {
        for slope: Float in [0.2, 0.8, -0.4] {
            let source = surface { x, z in 0.25 + slope * x + 0.1 * z }, sampler = scan(source)
            XCTAssertLessThan(sampler.pointCount, fixedCount(source, spacing: 0.05) / 2, "slope=\(slope)")
            XCTAssertTrue(sampler.snapshot().allSatisfy { abs($0.position.y - (0.25 + slope * $0.position.x + 0.1 * $0.position.z)) < 0.00001 })
        }
    }

    func testKerbKeepsBothObservedLevelsAndFineEdge() {
        let source = surface { x, _ in x < 0 ? 0.25 : 0.40 }, sampler = scan(source)
        let points = sampler.snapshot().map(\.position)
        let edge = points.filter { abs($0.x) < 0.19 }
        XCTAssertGreaterThan(edge.count, 100)
        XCTAssertTrue(edge.contains { $0.y == 0.25 } && edge.contains { $0.y == 0.4 })
        XCTAssertEqual(sampler.level(at: SIMD3(0.003, 0.4, 0.003)), .detail)
        XCTAssertLessThan(points.count, fixedCount(source, spacing: 0.05))
        XCTAssertTrue(Set(points).isSubset(of: Set(source.map(\.position))))
    }

    func testDitchPreservesRimAndBottomWithoutFillingIt() {
        let source = surface { x, _ in 0.25 - max(0, 0.3 - abs(x)) }, sampler = scan(source)
        let points = sampler.snapshot().map(\.position)
        XCTAssertGreaterThan(points.filter { abs($0.x) < 0.2 }.count, 100)
        XCTAssertLessThan(points.map(\.y).min() ?? 1, 0)
        XCTAssertTrue(Set(points).isSubset(of: Set(source.map(\.position))))
        XCTAssertGreaterThan(source.filter { sampler.level(at: $0.position) == .detail }.count, 100)
    }

    func testRampToeAndCrestKeepDetailWhileMiddleStaysSparse() {
        let source = surface { x, _ in 0.25 + min(0.5, max(0, x + 0.5)) * 0.5 }, sampler = scan(source)
        let points = sampler.snapshot().map(\.position)
        XCTAssertGreaterThan(points.filter { abs($0.x + 0.5) < 0.19 }.count, 100)
        XCTAssertLessThan(sampler.pointCount, fixedCount(source, spacing: 0.05))
        XCTAssertTrue(Set(points).isSubset(of: Set(source.map(\.position))))
    }

    func testNarrowChannelIsNotDiscardedByCoarseFirstSampling() {
        let source = surface(step: 0.025) { x, _ in abs(x) < 0.04 ? 0.13 : 0.25 }, sampler = scan(source)
        XCTAssertGreaterThan(sampler.snapshot().filter { abs($0.position.x) < 0.04 && $0.position.y == 0.13 }.count, 30)
    }

    func testIsolatedUnreliableSpikeNeverCreatesGeometryOrFeature() {
        var source = surface { _, _ in 0.25 }
        source.append(Observation(position: SIMD3(0.05, 0.6, 0.05), reliable: false))
        let sampler = scan(source)
        XCTAssertTrue(sampler.snapshot().allSatisfy { $0.position.y == 0.25 })
        XCTAssertEqual(sampler.level(at: SIMD3(0.003, 0.25, 0.003)), .coarse)
    }

    func testSmallStableNoiseDoesNotMakeTheWholeSiteDetailed() {
        let source = surface { x, z in 0.25 + 0.003 * sin(x * 35) * cos(z * 29) }, sampler = scan(source)
        XCTAssertLessThan(sampler.pointCount, fixedCount(source, spacing: 0.05) / 2)
    }

    func testCoarseRepresentativeIsObservedAndNotAnIsolatedNoisyCorner() {
        var source = surface { _, _ in 0.25 }
        let corner = SIMD3<Float>(0.003, 0.27, 0.003)
        source.removeAll { $0.position.x == corner.x && $0.position.z == corner.z }
        source.insert(.init(position: corner), at: 0)
        let sampler = scan(source)
        let parent = TerrainCapture.key(corner, spacing: 0.2)
        let selected = sampler.snapshot().filter { TerrainCapture.key($0.position, spacing: 0.2) == parent }
        XCTAssertEqual(selected.count, 1)
        XCTAssertNotEqual(selected.first?.position, corner)
        XCTAssertTrue(selected.allSatisfy { $0.position.y == 0.25 })
        XCTAssertTrue(Set(selected.map(\.position)).isSubset(of: Set(source.map(\.position))))
    }

    func testSingleFrameAndDuplicateTimestampDoNotCertifyDetail() {
        let source = surface { x, _ in x < 0 ? 0.25 : 0.4 }
        let sampler = AdaptiveTerrainSampler(capacity: 200_000)
        for _ in 0..<8 { sampler.integrate(source, camera: camera, range: 5, timestamp: 0) }
        XCTAssertEqual(sampler.analysisCount, 1)
        XCTAssertFalse(source.contains { sampler.level(at: $0.position) == .detail })
        XCTAssertEqual(sampler.pointCount, fixedCount(source, spacing: 0.05))
    }

    func testConfirmedEdgeDoesNotFlickerBackToCoarse() {
        let source = surface { x, _ in x < 0 ? 0.25 : 0.4 }, sampler = scan(source)
        let edge = SIMD3<Float>(0.003, 0.4, 0.003)
        XCTAssertEqual(sampler.level(at: edge), .detail)
        let oneSide = source.filter { $0.position.x >= 0 }
        for frame in 8..<16 { sampler.integrate(oneSide, camera: camera, range: 5, timestamp: Double(frame) * 0.3) }
        XCTAssertEqual(sampler.level(at: edge), .detail)
    }

    func testUnknownGapIsNeverFilledOrMarkedAsDetailed() {
        let source = surface { _, _ in 0.25 }.filter { abs($0.position.x) > 0.25 }
        let sampler = scan(source)
        XCTAssertFalse(sampler.snapshot().contains { abs($0.position.x) <= 0.25 })
        XCTAssertNil(sampler.level(at: SIMD3(0.003, 0.25, 0.003)))
        XCTAssertEqual(sampler.level(at: SIMD3(0.303, 0.25, 0.003)), .uncertain)
    }

    func testUnobservedBoundaryKeepsFineGeometryWithoutCallingItAnEdge() {
        let source = surface { _, _ in 0.25 }, sampler = scan(source)
        let outer = source.filter { $0.position.x < -1.05 }
        let kept = Set(sampler.snapshot().map(\.position))
        XCTAssertTrue(outer.allSatisfy { kept.contains($0.position) })
        XCTAssertEqual(sampler.level(at: SIMD3(-1.197, 0.25, 0.003)), .uncertain)
    }

    func testFineMarkRequiresNearbyRepeatedRetainedPoint() {
        let source = surface { x, _ in x < 0 ? 0.25 : 0.4 }, sampler = scan(source)
        XCTAssertEqual(sampler.level(at: SIMD3(0.003, 0.4, 0.003)), .detail)
        XCTAssertNotEqual(sampler.level(at: SIMD3(0.048, 0.445, 0.048)), .detail)
    }

    func testRangeConfidenceAndNonfiniteInputsAreRejected() {
        let sampler = AdaptiveTerrainSampler(capacity: 100)
        let source: [Observation] = [
            .init(position: SIMD3(0, 0, -1)), .init(position: SIMD3(0, 0, -4)),
            .init(position: SIMD3(.nan, 0, 0)), .init(position: SIMD3(1, 0, 0), reliable: false),
            .init(position: .zero, color: SIMD3(.infinity, 0, 0))
        ]
        XCTAssertEqual(sampler.integrate(source, camera: .zero, range: 3, timestamp: 0), [true, false, false, false, false])
        XCTAssertEqual(sampler.pointCount, 1)
        XCTAssertEqual(sampler.snapshot().first?.position, SIMD3(0, 0, -1))
    }

    func testCapacityPausesWithoutDroppingPreviouslyRetainedPoints() {
        let source = surface { _, _ in 0.25 }, sampler = scan(source, capacity: 120)
        XCTAssertTrue(sampler.isFull)
        XCTAssertLessThanOrEqual(sampler.storageUnits, sampler.capacity)
        let before = sampler.snapshot().map(\.position)
        sampler.integrate(surface { _, _ in -1 }, camera: camera, range: 5, timestamp: 3)
        XCTAssertTrue(Set(before).isSubset(of: Set(sampler.snapshot().map(\.position))))
    }

    func testZeroBudgetHasNoHiddenMinimum() {
        let sampler = scan(surface { _, _ in 0.25 }, capacity: 0)
        XCTAssertTrue(sampler.isFull); XCTAssertEqual(sampler.pointCount, 0); XCTAssertEqual(sampler.storageUnits, 0)
    }

    func testCacheCompactionIsBoundedAndPreservesTheExport() {
        let source = surface { _, _ in 0.25 }, sampler = scan(source)
        let before = sampler.snapshot().map(\.position), units = sampler.storageUnits
        sampler.integrate([], camera: camera, range: 5, timestamp: 10)
        XCTAssertEqual(sampler.activeCellCount, 0)
        XCTAssertLessThan(sampler.storageUnits, units)
        XCTAssertEqual(before, sampler.snapshot().map(\.position))
    }

    func testSmallActiveCacheStillKeepsUnknownAndConfirmedGeometry() {
        let source = surface { x, _ in x < 0 ? 0.25 : 0.4 }, sampler = scan(source, cache: 8)
        XCTAssertLessThanOrEqual(sampler.activeCellCount, 8)
        XCTAssertTrue(sampler.snapshot().contains { $0.position.y == 0.4 })
        XCTAssertTrue(sampler.snapshot().contains { $0.position.y == 0.25 })
        XCTAssertEqual(sampler.snapshot().count, sampler.pointCount)
    }

    func testNewlyExposedStepCanPromoteAnOldCompactedFlatPatch() {
        let flat = surface { _, _ in 0.25 }, sampler = scan(flat)
        sampler.integrate([], camera: camera, range: 5, timestamp: 10)
        let changed = surface { x, _ in x < 0 ? 0.25 : 0.4 }
        for frame in 0..<10 { sampler.integrate(changed, camera: camera, range: 5, timestamp: 11 + Double(frame) * 0.3) }
        XCTAssertEqual(sampler.level(at: SIMD3(0.003, 0.4, 0.003)), .detail)
        XCTAssertTrue(sampler.snapshot().contains { $0.position.y == 0.4 })
    }

    func testAdaptiveMetadataAndVariableDensityManifestRoundTrip() throws {
        let metadata = TerrainCaptureMetadata(spacing: .overview, captureRangeMetres: Float(5).nextUp, adaptive: true)
        let normalized = try metadata.normalized()
        XCTAssertEqual(normalized.adaptive, true); XCTAssertEqual(normalized.captureRangeMetres, 5)
        XCTAssertEqual(normalized.version, 2)
        XCTAssertEqual(try normalized.normalized(), normalized)
        let manifest = try TerrainExportManifest(metadata: metadata, modelFile: "model.ply",
            modelSHA256: String(repeating: "a", count: 64), pointCount: 100)
        let data = try JSONEncoder().encode(manifest)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["spacingMetres"])
        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.minimumSpacingMetres, 0.05)
        XCTAssertEqual(manifest.maximumSpacingMetres, 0.2)
        XCTAssertEqual(manifest.transitionSpacingMetres, 0.1)
        XCTAssertEqual(manifest.sampling, "adaptiveObservedPointVoxels")
        XCTAssertEqual(try JSONDecoder().decode(TerrainExportManifest.self, from: data).adaptiveAlgorithmVersion, 1)
        XCTAssertFalse(manifest.interpolated); XCTAssertEqual(manifest.groundClassification, "unclassified")
        XCTAssertEqual(try JSONDecoder().decode(TerrainCaptureMetadata.self, from: JSONEncoder().encode(normalized)), normalized)
    }

    func testOldTerrainMetadataRemainsFixedAndSchemaOne() throws {
        let old = Data("{\"version\":1,\"spacing\":200,\"captureRangeMetres\":5}".utf8)
        let metadata = try JSONDecoder().decode(TerrainCaptureMetadata.self, from: old)
        XCTAssertNil(metadata.adaptive)
        let manifest = try TerrainExportManifest(metadata: metadata, modelFile: "model.ply",
            modelSHA256: String(repeating: "a", count: 64), pointCount: 1)
        XCTAssertEqual(manifest.schemaVersion, 1); XCTAssertEqual(manifest.spacingMetres, 0.2)
        XCTAssertNil(manifest.minimumSpacingMetres)
    }

    func testUnsupportedOrAmbiguousAdaptiveMetadataIsRejected() {
        var metadata = TerrainCaptureMetadata(spacing: .overview, captureRangeMetres: 3)
        metadata.version = 2
        XCTAssertThrowsError(try metadata.normalized())
        metadata.adaptive = false
        XCTAssertThrowsError(try metadata.normalized())
        metadata.adaptive = true; metadata.version = 3
        XCTAssertThrowsError(try metadata.normalized())
    }

    func testSyntheticBenchmarkReportsRetentionAndWorkerCost() {
        let source = surface(step: 0.025) { x, _ in x < 0.5 ? 0.25 : 0.4 }
        let start = Date(), sampler = scan(source)
        let elapsed = Date().timeIntervalSince(start)
        print("ADAPTIVE_BENCHMARK inputs=\(source.count) frames=8 seconds=\(elapsed) retained=\(sampler.pointCount) uniform5cm=\(fixedCount(source, spacing: 0.05)) units=\(sampler.storageUnits)")
        XCTAssertLessThan(sampler.pointCount, fixedCount(source, spacing: 0.05))
        XCTAssertLessThanOrEqual(sampler.storageUnits, sampler.capacity)
        // This is a CI CPU regression guard, not an iPhone frame-rate promise.
        XCTAssertLessThan(elapsed, 15)
    }
}
