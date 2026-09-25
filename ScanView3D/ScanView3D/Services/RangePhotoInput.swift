import Foundation
import CoreImage
import ImageIO
import CoreVideo
#if !targetEnvironment(simulator)
import RealityKit
#endif

enum RangePhotoInput {
    /// Nearest-neighbour expansion preserves a binary boundary and image origin.
    static func maskBuffer(_ mask: PhotoRangeMask, width: Int, height: Int) throws -> CVPixelBuffer {
        guard mask.isValid, width > 0, height > 0, width <= 16384, height <= 16384 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_OneComponent8,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw CocoaError(.coderInvalidValue) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw CocoaError(.coderInvalidValue) }
        let pixels = [UInt8](mask.pixels)
        for y in 0..<height {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
            let sourceY = min(mask.height - 1, y * mask.height / height)
            for x in 0..<width { row[x] = pixels[sourceY * mask.width + min(mask.width - 1, x * mask.width / width)] }
        }
        return buffer
    }

    static func writeMask(_ mask: PhotoRangeMask, width: Int, height: Int, to url: URL) throws {
        let buffer = try maskBuffer(mask, width: width, height: height)
        let image = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cg = context.createCGImage(image, from: image.extent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

}

#if !targetEnvironment(simulator)
extension RangePhotoInput {
    /// Lazy, bounded image decoding. On any read failure the caller rejects the
    /// reconstruction, rather than quietly saving a model made from partial data.
    final class Samples: Sequence {
        typealias Element = PhotogrammetrySample
        let folder: URL
        let poses: [CapturedPose]
        private let context = CIContext()
        private let lock = NSLock()
        private var failure: Error?

        init(folder: URL, poses: [CapturedPose]) throws {
            guard !poses.isEmpty, poses.allSatisfy({ $0.rangeMask?.isValid == true }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.folder = folder
            self.poses = poses.sorted { $0.index < $1.index }
        }

        func checkFailure() throws {
            lock.lock(); let error = failure; lock.unlock()
            if let error { throw error }
        }

        func makeIterator() -> AnyIterator<PhotogrammetrySample> {
            var index = 0
            return AnyIterator { [self] in
                guard index < poses.count else { return nil }
                let pose = poses[index]; index += 1
                do { return try autoreleasepool { try sample(pose) } }
                catch {
                    lock.lock(); failure = error; lock.unlock()
                    return nil
                }
            }
        }

        private func sample(_ pose: CapturedPose) throws -> PhotogrammetrySample {
            let url = folder.appendingPathComponent(String(format: "frame_%04d.jpg", pose.index))
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  cg.width == pose.width, cg.height == pose.height, let mask = pose.rangeMask else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, cg.width, cg.height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else { throw CocoaError(.coderInvalidValue) }
            context.render(CIImage(cgImage: cg), to: buffer)
            var sample = PhotogrammetrySample(id: pose.index, image: buffer)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
            sample.metadata = (properties?[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
            sample.objectMask = try maskBuffer(mask, width: cg.width, height: cg.height)
            return sample
        }
    }
}
#endif
