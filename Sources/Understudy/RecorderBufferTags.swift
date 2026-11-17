@preconcurrency import AVFoundation
import CoreVideo
import UnderstudyCore
import VideoToolbox

// The recorder's colour and field tags, read from and written to pixel buffers and the writer.
// Every buffer reaching the writer carries both, so what's encoded and what's tagged in the file
// agree: capture devices tag their own; NDI and the test pattern are tagged where they're made.
// Nothing here changes pixels: the recorder never applies a LUT or any colour conversion of its own.

extension RecorderColor {
    /// The buffer's own tags, with anything missing taken from its height (709 HD, 601 SD).
    init(buffer: CVPixelBuffer) {
        func tag(_ key: CFString) -> String? {
            CVBufferCopyAttachment(buffer, key, nil) as? String
        }
        self = RecorderColor.from(primaries: tag(kCVImageBufferColorPrimariesKey), transfer: tag(kCVImageBufferTransferFunctionKey),
                                  matrix: tag(kCVImageBufferYCbCrMatrixKey), height: CVPixelBufferGetHeight(buffer))
    }

    /// Tags `buffer` (kept by anything made from it, and read by the encoder).
    func attach(to buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries as CFString, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer as CFString, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix as CFString, .shouldPropagate)
    }

    /// AVVideoColorPropertiesKey for the writer.
    var writerProperties: [String: Any] {
        [AVVideoColorPrimariesKey: primaries, AVVideoTransferFunctionKey: transfer, AVVideoYCbCrMatrixKey: matrix]
    }
}

extension RecorderScan {
    /// From the buffer's field tags (capture devices set them for interlaced inputs).
    init(buffer: CVPixelBuffer) {
        guard let count = CVBufferCopyAttachment(buffer, kCVImageBufferFieldCountKey, nil) as? NSNumber, count.intValue == 2 else {
            self = .progressive
            return
        }
        let detail = CVBufferCopyAttachment(buffer, kCVImageBufferFieldDetailKey, nil) as? String
        let bottomFirst = [kCVImageBufferFieldDetailSpatialFirstLineLate as String, kCVImageBufferFieldDetailTemporalBottomFirst as String]
        self = detail.map(bottomFirst.contains) == true ? .bottomFieldFirst : .topFieldFirst
    }

    func attach(to buffer: CVPixelBuffer) {
        guard isInterlaced else {
            CVBufferSetAttachment(buffer, kCVImageBufferFieldCountKey, 1 as NSNumber, .shouldPropagate)
            CVBufferRemoveAttachment(buffer, kCVImageBufferFieldDetailKey)
            return
        }
        CVBufferSetAttachment(buffer, kCVImageBufferFieldCountKey, 2 as NSNumber, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferFieldDetailKey, fieldDetail, .shouldPropagate)
    }

    /// Woven fields: which spatial line is earlier in time.
    var fieldDetail: CFString {
        self == .bottomFieldFirst ? kCVImageBufferFieldDetailSpatialFirstLineLate : kCVImageBufferFieldDetailSpatialFirstLineEarly
    }

    /// Compression properties that mark the encoded frames as fields (ProRes keeps them;
    /// the H.264/HEVC encoders here code progressive frames only).
    var proResCompressionProperties: [String: Any] {
        guard isInterlaced else { return [:] }
        return [kVTCompressionPropertyKey_FieldCount as String: 2,
                kVTCompressionPropertyKey_FieldDetail as String: fieldDetail as String]
    }
}
