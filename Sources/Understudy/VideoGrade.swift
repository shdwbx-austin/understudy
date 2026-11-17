import AVFoundation
import CoreImage
import Foundation
import os
import UnderstudyCore

/// Applies a deck's input transform (log curve or .cube LUT) to its player item on the GPU: a Core
/// Image colour cube run by the item's video composition. The player layer on screen and the
/// AVPlayerItemVideoOutput feeding NDI both get the converted frames, so the two always match.
enum VideoGrade {
    /// Built-in curves are baked to a cube this size (64³: well under a 10-bit step from the
    /// exact maths).
    static let builtInCubeSize = 64

    struct Cube: Sendable {
        let size: Int
        let data: Data
    }

    enum Failure: Error, LocalizedError {
        case unreadable(String, Error)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name, let error): return "Couldn't read \(name): \(error.localizedDescription)"
            }
        }
    }

    private static let cache = OSAllocatedUnfairLock<[InputTransform: Cube]>(initialState: [:])

    /// The cube for a transform (nil for none), read or baked once.
    static func cube(for transform: InputTransform) throws -> Cube? {
        if transform == .none { return nil }
        if let hit = cache.withLock({ $0[transform] }) { return hit }
        let lut: CubeLUT
        switch transform {
        case .none: return nil
        case .log(let curve): lut = LogToRec709(curve).cube(size: builtInCubeSize)
        case .lut(let path):
            do { lut = try CubeLUT.read(URL(fileURLWithPath: path)) } catch {
                throw Failure.unreadable(URL(fileURLWithPath: path).lastPathComponent, error)
            }
        }
        let cube = Cube(size: lut.size, data: lut.rgbaData())
        cache.withLock { $0[transform] = cube }
        return cube
    }

    /// Drops a LUT file's cached cube (loaded again, or changed on disk).
    static func forget(_ transform: InputTransform) {
        _ = cache.withLock { $0.removeValue(forKey: transform) }
    }

    /// A video composition for `asset` that runs every frame through `cube`, in Rec.709.
    static func composition(for asset: AVAsset, cube: Cube) async throws -> AVVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.unreadable("the video", CocoaError(.fileReadCorruptFile))
        }
        let (size, minFrame, rate, duration) = try await (track.load(.naturalSize), track.load(.minFrameDuration),
                                                          track.load(.nominalFrameRate), asset.load(.duration))
        let comp = AVMutableVideoComposition()
        comp.customVideoCompositorClass = Compositor.self
        comp.renderSize = size
        comp.frameDuration = minFrame.isValid && minFrame.seconds > 0 ? minFrame
            : CMTime(value: 1000, timescale: CMTimeScale(max(1, (Double(rate) * 1000).rounded())))
        comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        comp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        comp.instructions = [Instruction(timeRange: CMTimeRange(start: .zero, duration: duration), track: track.trackID,
                                         grader: Grader(cube))]
        return comp
    }

    /// The whole file, one track, graded by `grader`.
    final class Instruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
        let timeRange: CMTimeRange
        let enablePostProcessing = false
        let containsTweening = false
        let requiredSourceTrackIDs: [NSValue]?
        let passthroughTrackID = kCMPersistentTrackID_Invalid
        let track: CMPersistentTrackID
        let grader: Grader

        init(timeRange: CMTimeRange, track: CMPersistentTrackID, grader: Grader) {
            self.timeRange = timeRange
            self.track = track
            self.grader = grader
            requiredSourceTrackIDs = [NSNumber(value: track)]
        }
    }

    /// Renders each frame through its instruction's cube: the source decoded to half-float RGB
    /// (so log footage keeps its precision through the expansion), out as 10-bit 4:2:2 YCbCr
    /// tagged Rec.709, which the player shows and converts to BGRA for NDI like any decoded video.
    final class Compositor: NSObject, AVVideoCompositing, @unchecked Sendable {
        private static let context = CIContext(options: [.cacheIntermediates: false, .name: "Understudy grade"])

        let sourcePixelBufferAttributes: [String: any Sendable]? = [
            kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_64RGBAHalf],
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        ]
        let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange],
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        ]

        func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

        func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
            guard let instruction = request.videoCompositionInstruction as? Instruction,
                  let source = request.sourceFrame(byTrackID: instruction.track),
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: CocoaError(.fileReadUnknown))
                return
            }
            let image = CIImage(cvPixelBuffer: source)
            let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.itur_709)!
            CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            Self.context.render(instruction.grader.apply(to: image), to: output, bounds: image.extent, colorSpace: space)
            request.finish(withComposedVideoFrame: output)
        }

        func cancelAllPendingVideoCompositionRequests() {}
    }

    /// One colour-cube filter per composition, kept between frames so Core Image builds the
    /// cube's texture once, not every frame.
    final class Grader: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private let filter: CIFilter?
        private var colorSpace: CGColorSpace?

        init(_ cube: Cube) {
            filter = CIFilter(name: "CIColorCubeWithColorSpace")
            filter?.setValue(cube.size, forKey: "inputCubeDimension")
            filter?.setValue(cube.data, forKey: "inputCubeData")
        }

        /// The cube applied to the picture's own values: Core Image converts the frame to the
        /// cube's colour space (the frame's own, Rec.709 if untagged) first, so the LUT sees the
        /// file's code values, and the result is read back as that same space.
        func apply(to image: CIImage) -> CIImage {
            guard let filter else { return image }
            return lock.withLockUnchecked {
                let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.itur_709)
                if colorSpace !== space {
                    colorSpace = space
                    filter.setValue(space, forKey: "inputColorSpace")
                }
                filter.setValue(image, forKey: kCIInputImageKey)
                let out = filter.outputImage?.cropped(to: image.extent) ?? image
                filter.setValue(nil, forKey: kCIInputImageKey)
                return out
            }
        }
    }
}
