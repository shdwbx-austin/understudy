import CNDI
import CoreVideo
import Foundation
import UnderstudyCore
import VideoToolbox

/// Converts the BGRA test pattern into other pixel formats and sizes, the way a sender would:
/// with the given Y'CbCr matrix, keeping the primaries (so only the matrix decides the colours).
final class PictureConverter {
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    let width: Int, height: Int, format: OSType
    let matrix: CFString

    init(width: Int, height: Int, format: OSType, matrix: CFString) {
        self.width = width
        self.height = height
        self.format = format
        self.matrix = matrix
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        if let session {
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: matrix)
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        }
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: format,
                                    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    func convert(_ bgra: CVPixelBuffer) -> CVPixelBuffer? {
        guard let session, let pool else { return nil }
        // The pattern is drawn in sRGB: Rec. 709 primaries.
        CVBufferSetAttachment(bgra, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(bgra, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return nil }
        CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return VTPixelTransferSessionTransferImage(session, from: bgra, to: out) == noErr ? out : nil
    }
}

/// Sends UYVY (2vuy buffers) over NDI, progressive or interleaved, as a camera or switcher does;
/// or, with `fourCC` BGRA, BGRA buffers as a source with alpha (a graphics feed).
final class UYVYSender: @unchecked Sendable {
    private let instance: OpaquePointer?
    private let lib = NDILibrary.shared
    let fourCC: UInt32

    init?(name: String, fourCC: UInt32 = NDIReceiver.fourCCUYVY) {
        self.fourCC = fourCC
        guard let create = lib.sendCreate else { return nil }
        instance = name.withCString { n in
            var settings = cndi_send_create_t(p_ndi_name: n, p_groups: nil, clock_video: false, clock_audio: false)
            return create(&settings)
        }
        guard instance != nil else { return nil }
    }

    /// `formatType`: NDI frame_format_type (1 progressive, 0 interleaved, 2/3 field 0/1).
    func send(_ buffer: CVPixelBuffer, rate: FrameRate, interleaved: Bool) {
        send(buffer, rate: rate, formatType: interleaved ? 0 : Int32(CNDI_FRAME_FORMAT_PROGRESSIVE))
    }

    func send(_ buffer: CVPixelBuffer, rate: FrameRate, formatType: Int32) {
        guard let sendVideo = lib.sendVideo else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let (n, d) = NDISender.rational(rate.exact)
        var frame = cndi_video_frame_v2_t()
        frame.xres = Int32(w)
        frame.yres = Int32(h)
        frame.FourCC = fourCC
        frame.frame_rate_N = n
        frame.frame_rate_D = d
        frame.picture_aspect_ratio = 16.0 / 9.0
        frame.frame_format_type = formatType
        frame.timecode = Int64.max
        frame.p_data = base.assumingMemoryBound(to: UInt8.self)
        frame.line_stride_in_bytes = Int32(CVPixelBufferGetBytesPerRow(buffer))
        sendVideo(instance, &frame)
    }

    deinit { lib.sendDestroy?(instance) }
}
