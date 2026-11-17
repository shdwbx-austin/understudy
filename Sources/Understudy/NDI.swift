import CNDI
import CoreVideo
import Darwin
import Foundation

/// NDI, loaded at run time: libndi.dylib bundled in the app (Contents/Frameworks), else an
/// installed NDI runtime or SDK. `UNDERSTUDY_LIBNDI` points at another copy (testing).
final class NDILibrary: @unchecked Sendable {
    static let shared = NDILibrary()

    typealias Initialize = @convention(c) () -> Bool
    typealias SendCreate = @convention(c) (UnsafePointer<cndi_send_create_t>?) -> OpaquePointer?
    typealias SendDestroy = @convention(c) (OpaquePointer?) -> Void
    typealias SendVideo = @convention(c) (OpaquePointer?, UnsafePointer<cndi_video_frame_v2_t>?) -> Void
    typealias FindCreate = @convention(c) (UnsafePointer<cndi_find_create_t>?) -> OpaquePointer?
    typealias FindWait = @convention(c) (OpaquePointer?, UInt32) -> Bool
    typealias FindSources = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt32>?) -> UnsafePointer<cndi_source_t>?
    typealias FindDestroy = @convention(c) (OpaquePointer?) -> Void
    typealias RecvCreate = @convention(c) (UnsafePointer<cndi_recv_create_v3_t>?) -> OpaquePointer?
    typealias RecvCapture = @convention(c) (OpaquePointer?, UnsafeMutablePointer<cndi_video_frame_v2_t>?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32) -> Int32
    typealias RecvFreeVideo = @convention(c) (OpaquePointer?, UnsafePointer<cndi_video_frame_v2_t>?) -> Void
    typealias RecvDestroy = @convention(c) (OpaquePointer?) -> Void

    let path: String?
    let sendCreate: SendCreate?
    let sendDestroy: SendDestroy?
    let sendVideo: SendVideo?
    let findCreate: FindCreate?
    let findWait: FindWait?
    let findSources: FindSources?
    let findDestroy: FindDestroy?
    let recvCreate: RecvCreate?
    let recvCapture: RecvCapture?
    let recvFreeVideo: RecvFreeVideo?
    let recvDestroy: RecvDestroy?

    var isAvailable: Bool { sendCreate != nil && sendVideo != nil }

    static var candidates: [String] {
        var list: [String] = []
        if let env = ProcessInfo.processInfo.environment["UNDERSTUDY_LIBNDI"], !env.isEmpty { list.append(env) }
        if let frameworks = Bundle.main.privateFrameworksPath { list.append(frameworks + "/libndi.dylib") }
        list += ["/usr/local/lib/libndi.dylib", "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
                 "/Library/NDI SDK for macOS/lib/macOS/libndi.dylib"]
        return list
    }

    private init() {
        var handle: UnsafeMutableRawPointer?
        var found: String?
        for p in Self.candidates where FileManager.default.fileExists(atPath: p) {
            if let h = dlopen(p, RTLD_NOW | RTLD_LOCAL) { handle = h; found = p; break }
        }
        path = found
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let handle, let s = dlsym(handle, name) else { return nil }
            return unsafeBitCast(s, to: T.self)
        }
        if let initialize = sym("NDIlib_initialize", Initialize.self), !initialize() { handle = nil }
        sendCreate = sym("NDIlib_send_create", SendCreate.self)
        sendDestroy = sym("NDIlib_send_destroy", SendDestroy.self)
        sendVideo = sym("NDIlib_send_send_video_v2", SendVideo.self)
        findCreate = sym("NDIlib_find_create_v2", FindCreate.self)
        findWait = sym("NDIlib_find_wait_for_sources", FindWait.self)
        findSources = sym("NDIlib_find_get_current_sources", FindSources.self)
        findDestroy = sym("NDIlib_find_destroy", FindDestroy.self)
        recvCreate = sym("NDIlib_recv_create_v3", RecvCreate.self)
        recvCapture = sym("NDIlib_recv_capture_v2", RecvCapture.self)
        recvFreeVideo = sym("NDIlib_recv_free_video_v2", RecvFreeVideo.self)
        recvDestroy = sym("NDIlib_recv_destroy", RecvDestroy.self)
    }
}

/// One NDI output ("Understudy ME 1"), sending opaque BGRA frames (as BGRX).
final class NDISender: @unchecked Sendable {
    let name: String
    private let instance: OpaquePointer?
    private let lib = NDILibrary.shared

    init?(name: String) {
        guard lib.isAvailable, let create = lib.sendCreate else { return nil }
        self.name = name
        instance = name.withCString { cName in
            var settings = cndi_send_create_t(p_ndi_name: cName, p_groups: nil, clock_video: false, clock_audio: false)
            return create(&settings)
        }
        guard instance != nil else { return nil }
    }

    /// Sends one BGRA pixel buffer (copied by NDI before it returns). `aspect` is the picture's
    /// display aspect (nil: width / height); `metadata` is per-frame NDI XML.
    func send(_ buffer: CVPixelBuffer, fps: Double, aspect: Float? = nil, interlaced: Bool = false, metadata: String? = nil) {
        guard let instance, let sendVideo = lib.sendVideo else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let (n, d) = Self.rational(fps)
        var frame = cndi_video_frame_v2_t()
        frame.xres = Int32(w)
        frame.yres = Int32(h)
        frame.FourCC = Self.fourCCBGRX
        frame.frame_rate_N = n
        frame.frame_rate_D = d
        frame.picture_aspect_ratio = aspect ?? Float(w) / Float(max(h, 1))
        frame.frame_format_type = Int32(interlaced ? CNDI_FRAME_FORMAT_INTERLEAVED : CNDI_FRAME_FORMAT_PROGRESSIVE)
        frame.timecode = Int64.max
        frame.p_data = base.assumingMemoryBound(to: UInt8.self)
        frame.line_stride_in_bytes = Int32(CVPixelBufferGetBytesPerRow(buffer))
        if let metadata {
            metadata.withCString { xml in
                frame.p_metadata = xml
                sendVideo(instance, &frame)
            }
        } else {
            sendVideo(instance, &frame)
        }
    }

    /// NDI's FourCC for 8-bit BGRX ("BGRX", little-endian): BGRA memory, alpha ignored. The
    /// pictures are opaque, and sent as BGRA NDI carries an alpha plane and its colours came back
    /// a few steps further off (measured: up to 9/255 vs 3.5/255 through NDI's codec).
    static let fourCCBGRX: UInt32 = UInt32(UInt8(ascii: "B")) | UInt32(UInt8(ascii: "G")) << 8
        | UInt32(UInt8(ascii: "R")) << 16 | UInt32(UInt8(ascii: "X")) << 24

    /// 29.97 → 30000/1001, 25 → 25000/1000.
    static func rational(_ fps: Double) -> (Int32, Int32) {
        let rounded = fps.rounded()
        if abs(fps - rounded) > 0.01 { return (Int32(rounded * 1000), 1001) }
        return (Int32(rounded * 1000), 1000)
    }

    deinit { lib.sendDestroy?(instance) }
}
