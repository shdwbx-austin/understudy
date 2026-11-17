import AVFoundation
import CoreImage
import Foundation
import os
import UnderstudyCore

/// Applies a feed's Playback LUT (.cube) to the viewer's player item on the GPU, in the item's
/// video composition. The viewer and NDI both show the output of that item, so they always match.
///
/// The LUT sees the file's own code values: no colour management on the way in (wide-gamut and
/// HDR files are handed over as recorded, not converted to Rec.709 first), and its output is taken
/// as Rec.709. Files without a Playback LUT have no composition at all.
enum VideoGrade {
    /// What the GPU needs from a .cube file.
    struct Chain: Sendable {
        var title: String
        /// 1D: RGB float entries over 0–1, after mapping the input range with scale/bias.
        var shaper: (data: Data, scale: [Double], bias: [Double])?
        /// 3D: size and RGBA float entries over 0–1, after mapping the input range with scale/bias.
        var cube: (size: Int, data: Data, scale: [Double], bias: [Double])?

        init(_ lut: LUTFile, title: String) {
            self.title = title
            if let s = lut.shaper { shaper = (s.rgbData(), s.domain.scale, s.domain.bias) }
            if let c = lut.cube { cube = (c.size, c.rgbaData(), lut.cubeDomain.scale, lut.cubeDomain.bias) }
        }
    }

    enum Failure: Error, LocalizedError {
        case unreadable(String, Error)
        case noFilter(String)
        case noVideo
        var errorDescription: String? {
            switch self {
            case .unreadable(let name, let error): return "Couldn't read \(name): \(error.localizedDescription)"
            case .noFilter(let name): return "Core Image has no \(name) filter here"
            case .noVideo: return "The file has no video track"
            }
        }
    }

    private static let cache = OSAllocatedUnfairLock<[InputTransform: Chain]>(initialState: [:])

    /// The chain for a transform (nil for none), read once.
    static func chain(for transform: InputTransform) throws -> Chain? {
        guard case .lut(let path) = transform else { return nil }
        if let hit = cache.withLock({ $0[transform] }) { return hit }
        let url = URL(fileURLWithPath: path)
        let lut: LUTFile
        do { lut = try LUTFile.read(url) } catch { throw Failure.unreadable(url.lastPathComponent, error) }
        let chain = Chain(lut, title: url.deletingPathExtension().lastPathComponent)
        // Fail now (shown on the deck) rather than pass the log picture through later.
        _ = try Grader.filters(for: chain)
        cache.withLock { $0[transform] = chain }
        return chain
    }

    /// Drops a LUT file's cached chain (loaded again, or changed on disk).
    static func forget(_ transform: InputTransform) {
        _ = cache.withLock { $0.removeValue(forKey: transform) }
    }

    /// A video composition for `asset` that runs every frame through `grader`.
    static func composition(for asset: AVAsset, grader: Grader) async throws -> AVVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let (size, minFrame, rate, duration) = try await (track.load(.naturalSize), track.load(.minFrameDuration),
                                                          track.load(.nominalFrameRate), asset.load(.duration))
        let comp = AVMutableVideoComposition()
        comp.customVideoCompositorClass = Compositor.self
        comp.renderSize = size
        comp.frameDuration = minFrame.isValid && minFrame.seconds > 0 ? minFrame
            : CMTime(value: 1000, timescale: CMTimeScale(max(1, (Double(rate) * 1000).rounded())))
        // No colour properties on the composition: set, AVFoundation converts every source to them
        // (a BT.2020 file to Rec.709) before the LUT sees it. The compositor tags its output Rec.709.
        comp.instructions = [Instruction(timeRange: CMTimeRange(start: .zero, duration: duration), track: track.trackID,
                                         grader: grader)]
        return comp
    }

    /// The grader inside an item's composition, if it has one of ours.
    @MainActor static func grader(of item: AVPlayerItem) -> Grader? {
        (item.videoComposition?.instructions.first as? Instruction)?.grader
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

    /// Renders each frame through its instruction's LUT: the source as half-float RGB code values
    /// (wide-gamut and HDR sources as recorded), out as 10-bit 4:2:2 YCbCr tagged Rec.709, which the
    /// output converts to BGRA for NDI and the viewer like any decoded video. A frame that can't be
    /// graded goes out ungraded (and says so); the player item never fails because of the LUT.
    final class Compositor: NSObject, AVVideoCompositing, @unchecked Sendable {
        /// No colour management anywhere: pixels in are the file's values, pixels out are the LUT's.
        private static let context = CIContext(options: [.cacheIntermediates: false, .name: "Understudy grade",
                                                         .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                                         .workingFormat: CIFormat.RGBAh])
        private static let rec709 = CGColorSpace(name: CGColorSpace.itur_709)

        let sourcePixelBufferAttributes: [String: any Sendable]? = [
            kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_64RGBAHalf],
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        ]
        let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange],
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        ]
        /// Hand over wide-gamut and HDR frames as they are, so the LUT sees the camera's values.
        let supportsWideColorSourceFrames = true
        let supportsHDRSourceFrames = true

        private let lock = OSAllocatedUnfairLock()
        private nonisolated(unsafe) var lastOutput: CVPixelBuffer?

        func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

        func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
            guard let instruction = request.videoCompositionInstruction as? Instruction,
                  let source = request.sourceFrame(byTrackID: instruction.track) else {
                // Nothing to grade: repeat the last picture rather than fail the item.
                if let last = lock.withLockUnchecked({ lastOutput }) {
                    request.finish(withComposedVideoFrame: last)
                } else {
                    request.finishCancelledRequest()
                }
                return
            }
            guard let output = request.renderContext.newPixelBuffer() ?? Self.makeBuffer(like: request.renderContext) else {
                // No buffer to draw into: the frame as it is (ungraded) beats a failed item.
                instruction.grader.report("Couldn't get a frame buffer; showing it ungraded")
                request.finish(withComposedVideoFrame: source)
                return
            }
            let image = CIImage(cvPixelBuffer: source, options: [.colorSpace: NSNull()])
            Self.tag709(output)
            Self.context.render(instruction.grader.apply(to: image), to: output, bounds: image.extent, colorSpace: nil)
            lock.withLockUnchecked { lastOutput = output }
            request.finish(withComposedVideoFrame: output)
        }

        func cancelAllPendingVideoCompositionRequests() {}

        /// Rec.709 tags, and the colour space a decoded Rec.709 frame carries too (without it,
        /// displays use another 709 curve and shadows look lifted next to an ungraded deck).
        private static func tag709(_ buffer: CVPixelBuffer) {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            let space = CVBufferCopyAttachments(buffer, .shouldPropagate)
                .flatMap { CVImageBufferCreateColorSpaceFromAttachments($0)?.takeRetainedValue() } ?? rec709
            if let space { CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate) }
        }

        private static func makeBuffer(like context: AVVideoCompositionRenderContext) -> CVPixelBuffer? {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(context.size.width), Int(context.size.height),
                                kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                                [kCVPixelBufferIOSurfacePropertiesKey: [String: String]()] as CFDictionary, &buffer)
            return buffer
        }
    }

    /// One LUT's filters per composition, kept between frames so Core Image builds their textures
    /// once. Changing the LUT swaps the filters in place (no new composition, so no hitch).
    final class Grader: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private nonisolated(unsafe) var filters: Filters
        private nonisolated(unsafe) var reported = false
        /// Told when frames go out ungraded, and why (once per LUT).
        private let onProblem: @Sendable (String) -> Void

        struct Filters {
            var shaperRange: CIFilter?, shaper: CIFilter?, cubeRange: CIFilter?, cube: CIFilter?
        }

        init(_ chain: Chain, onProblem: @escaping @Sendable (String) -> Void) throws {
            filters = try Self.filters(for: chain)
            self.onProblem = onProblem
        }

        /// Another LUT, from the next frame on.
        func setChain(_ chain: Chain) throws {
            let new = try Self.filters(for: chain)
            lock.withLockUnchecked {
                filters = new
                reported = false
            }
        }

        static func filters(for chain: Chain) throws -> Filters {
            var f = Filters()
            if let shaper = chain.shaper {
                f.shaperRange = try rangeFilter(scale: shaper.scale, bias: shaper.bias)
                guard let curves = CIFilter(name: "CIColorCurves") else { throw Failure.noFilter("CIColorCurves") }
                curves.setValue(shaper.data, forKey: "inputCurvesData")
                curves.setValue(CIVector(x: 0, y: 1), forKey: "inputCurvesDomain")
                f.shaper = curves
            }
            if let cube = chain.cube {
                f.cubeRange = try rangeFilter(scale: cube.scale, bias: cube.bias)
                guard let filter = CIFilter(name: "CIColorCube") else { throw Failure.noFilter("CIColorCube") }
                filter.setValue(cube.size, forKey: "inputCubeDimension")
                filter.setValue(cube.data, forKey: "inputCubeData")
                f.cube = filter
            }
            return f
        }

        /// Maps an input range onto 0–1 (nil when it already is 0–1).
        private static func rangeFilter(scale: [Double], bias: [Double]) throws -> CIFilter? {
            if scale == [1, 1, 1], bias == [0, 0, 0] { return nil }
            guard let m = CIFilter(name: "CIColorMatrix") else { throw Failure.noFilter("CIColorMatrix") }
            m.setValue(CIVector(x: scale[0], y: 0, z: 0, w: 0), forKey: "inputRVector")
            m.setValue(CIVector(x: 0, y: scale[1], z: 0, w: 0), forKey: "inputGVector")
            m.setValue(CIVector(x: 0, y: 0, z: scale[2], w: 0), forKey: "inputBVector")
            m.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            m.setValue(CIVector(x: bias[0], y: bias[1], z: bias[2], w: 0), forKey: "inputBiasVector")
            return m
        }

        func apply(to image: CIImage) -> CIImage {
            let result: CIImage? = lock.withLockUnchecked {
                var out = image
                for filter in [filters.shaperRange, filters.shaper, filters.cubeRange, filters.cube].compactMap({ $0 }) {
                    filter.setValue(out, forKey: kCIInputImageKey)
                    guard let next = filter.outputImage else { return nil }
                    filter.setValue(nil, forKey: kCIInputImageKey)
                    out = next
                }
                return out.cropped(to: image.extent)
            }
            if let result { return result }
            report("Core Image couldn't apply the LUT; showing the picture ungraded")
            return image
        }

        /// Says once (per LUT) that frames go out ungraded.
        func report(_ problem: String) {
            let first = lock.withLockUnchecked { () -> Bool in
                defer { reported = true }
                return !reported
            }
            if first { onProblem(problem) }
        }
    }
}
