import CNDI
import CoreVideo
import Foundation
import os

/// NDI sources on the network (for the recorder's source list). One finder for the app's life;
/// listing waits briefly for sources to answer, off the main thread.
final class NDIFinder: @unchecked Sendable {
    static let shared = NDIFinder()

    private let lib = NDILibrary.shared
    /// Only touched on `queue`.
    private var finder: OpaquePointer?
    private let queue = DispatchQueue(label: "understudy.ndi.find", qos: .utility)

    var isAvailable: Bool { lib.findCreate != nil && lib.findSources != nil }

    /// Calls `done` on the main queue with the source names (e.g. "STUDIO-MAC (Program)").
    func list(wait: Double = 1.0, done: @escaping @MainActor @Sendable ([String]) -> Void) {
        queue.async { [self] in
            let names = sources(wait: wait)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(names) } }
        }
    }

    /// Blocking: waits up to `wait` seconds for sources to change, then lists them.
    func currentSources(wait: Double) -> [String] {
        queue.sync { sources(wait: wait) }
    }

    private func sources(wait: Double) -> [String] {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let create = lib.findCreate, let sources = lib.findSources else { return [] }
        if finder == nil {
            var settings = cndi_find_create_t(show_local_sources: true, p_groups: nil, p_extra_ips: nil)
            finder = create(&settings)
        }
        guard let finder else { return [] }
        _ = lib.findWait?(finder, UInt32(max(0, wait) * 1000))
        var count: UInt32 = 0
        guard let list = sources(finder, &count) else { return [] }
        return (0..<Int(count)).compactMap { i in list[i].p_ndi_name.map { String(cString: $0) } }
    }
}

/// Receives video from one NDI source on its own thread and hands each frame over as a
/// CVPixelBuffer (UYVY as 2vuy, or BGRA when the source has alpha), stamped with the sender's
/// timestamp and the host time it arrived.
final class NDIReceiver: @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let buffer: CVPixelBuffer
        /// Sender's clock, seconds (from NDI's timestamp), or nil if it didn't send one.
        let sourceTime: Double?
        /// HostClock seconds when it arrived.
        let arrived: Double
        /// Declared frame rate.
        let fps: Double
    }

    /// NDIlib_recv_color_format_UYVY_BGRA: UYVY normally, BGRA when the picture has alpha. Half the
    /// bytes of BGRA, and what the encoders want anyway.
    private static let colorUYVYorBGRA: Int32 = 1
    private static let frameTypeVideo: Int32 = 1
    private static let frameTypeError: Int32 = 4
    static let fourCCUYVY: UInt32 = fourCC("UYVY")
    static let fourCCBGRA: UInt32 = fourCC("BGRA")
    static let fourCCBGRX: UInt32 = fourCC("BGRX")

    static func fourCC(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    let sourceName: String
    private let lib = NDILibrary.shared
    private var instance: OpaquePointer?
    private var thread: Thread?
    private let running = OSAllocatedUnfairLock(initialState: false)
    private var pools: [String: CVPixelBufferPool] = [:]

    /// Called on the receive thread for every video frame.
    var onFrame: (@Sendable (Frame) -> Void)?
    /// Called on the receive thread if the connection fails.
    var onError: (@Sendable (String) -> Void)?

    init(sourceName: String) {
        self.sourceName = sourceName
    }

    /// Nil on success, else what's wrong.
    func start() -> String? {
        guard let create = lib.recvCreate, lib.recvCapture != nil, lib.recvFreeVideo != nil else {
            return NDILibrary.shared.path == nil ? "NDI isn't installed on this Mac." : "This NDI library can't receive."
        }
        instance = sourceName.withCString { cName in
            "Understudy recorder".withCString { recvName in
                var settings = cndi_recv_create_v3_t(
                    source_to_connect_to: cndi_source_t(p_ndi_name: cName, p_url_address: nil),
                    color_format: Self.colorUYVYorBGRA,
                    bandwidth: Int32(CNDI_RECV_BANDWIDTH_HIGHEST),
                    allow_video_fields: false,
                    p_ndi_recv_name: recvName)
                return create(&settings)
            }
        }
        guard instance != nil else { return "Couldn't connect to \(sourceName)." }
        running.withLock { $0 = true }
        let thread = Thread { [self] in loop() }
        thread.name = "understudy.ndi.recv"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        return nil
    }

    func stop() {
        running.withLock { $0 = false }
        // The loop wakes within its capture timeout, sees it should stop and destroys the receiver.
    }

    private func loop() {
        guard let capture = lib.recvCapture, let free = lib.recvFreeVideo else { return }
        var frame = cndi_video_frame_v2_t()
        while running.withLock({ $0 }) {
            let type = capture(instance, &frame, nil, nil, 200)
            if type == Self.frameTypeVideo {
                let arrived = HostClock.now()
                let copied = copy(frame)
                let fps = frame.frame_rate_D > 0 ? Double(frame.frame_rate_N) / Double(frame.frame_rate_D) : 0
                // NDI timestamps are 100 ns ticks; 0 or INT64_MAX means "not sent".
                let ts = frame.timestamp
                let sourceTime: Double? = (ts == 0 || ts == Int64.max) ? nil : Double(ts) / 10_000_000
                free(instance, &frame)
                if let copied { onFrame?(Frame(buffer: copied, sourceTime: sourceTime, arrived: arrived, fps: fps)) }
            } else if type == Self.frameTypeError {
                onError?("The NDI connection to \(sourceName) failed.")
            }
        }
        lib.recvDestroy?(instance)
        instance = nil
    }

    /// Copies NDI's frame into a pooled pixel buffer (NDI owns its memory only until freed).
    private func copy(_ frame: cndi_video_frame_v2_t) -> CVPixelBuffer? {
        let w = Int(frame.xres), h = Int(frame.yres)
        guard w > 0, h > 0, let src = frame.p_data else { return nil }
        let format: OSType
        switch frame.FourCC {
        case Self.fourCCUYVY: format = kCVPixelFormatType_422YpCbCr8
        case Self.fourCCBGRA, Self.fourCCBGRX: format = kCVPixelFormatType_32BGRA
        default: return nil
        }
        guard let pool = pool(width: w, height: h, format: format) else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let buffer = out else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let dst = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let srcStride = Int(frame.line_stride_in_bytes)
        let dstStride = CVPixelBufferGetBytesPerRow(buffer)
        let rowBytes = min(srcStride, dstStride, w * (format == kCVPixelFormatType_32BGRA ? 4 : 2))
        if srcStride == dstStride {
            memcpy(dst, src, srcStride * h)
        } else {
            for y in 0..<h { memcpy(dst + y * dstStride, src + y * srcStride, rowBytes) }
        }
        return buffer
    }

    private func pool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        let key = "\(width)x\(height)/\(format)"
        if let p = pools[key] { return p }
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: format,
                                    kCVPixelBufferWidthKey as String: width,
                                    kCVPixelBufferHeightKey as String: height,
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary,
                                attrs as CFDictionary, &pool)
        if let pool { pools = [key: pool] }
        return pool
    }
}
