import AVFoundation
import Darwin
import Foundation
import os
import UnderstudyCore

/// A test AES67 sender: the timeline's left, right and timecode as one 3-channel L24/48 kHz
/// stream (1 ms packets) to a multicast group, announced by SAP so Dante Controller lists it.
/// It follows the network's PTPv2 master when there is one (receivers need that), and free-runs
/// on this Mac's clock otherwise. Everything runs on its own threads; the main actor only passes
/// in the timeline's state and reads the status.
final class AES67Sender: @unchecked Sendable {
    struct Config: Equatable, Sendable {
        var interfaceIP: String
        var multicast: String
        var port: UInt16 = AES67.defaultPort
        var name: String
        var ttl = 15
    }

    struct Status: Equatable, Sendable {
        var sending = false
        var packets: UInt64 = 0
        var grandmaster: String?
        var ptpLocked = false
        var problem: String?
        var sendErrors: UInt64 = 0
        var lastSendError: String?
    }

    private let config: Config
    private let state = OSAllocatedUnfairLock<TimelineModel.RenderState?>(initialState: nil)
    private let clock = OSAllocatedUnfairLock(initialState: AES67.ClockFollower())
    private let statusLock = OSAllocatedUnfairLock(initialState: Status())
    private let running = OSAllocatedUnfairLock(initialState: true)
    private var media: Int32 = -1
    private var ptpEvent: Int32 = -1
    private var ptpGeneral: Int32 = -1
    private let ssrc = UInt32.random(in: 1...UInt32.max)
    private let session = UInt32(Date().timeIntervalSince1970)
    private let sapHash = UInt16.random(in: 1...UInt16.max)
    /// SDP version: bumped when the stream's description changes (a new PTP grandmaster).
    private let sdpVersion = OSAllocatedUnfairLock(initialState: (version: UInt32(1), grandmaster: String?.none))

    var status: Status { statusLock.withLock { $0 } }

    init(config: Config) {
        self.config = config
    }

    /// Opens the sockets and starts the sender, PTP and SAP threads. Returns a problem, or nil.
    func start() -> String? {
        do {
            media = try Self.socket(bindPort: 0, interfaceIP: config.interfaceIP, ttl: config.ttl)
            ptpEvent = (try? Self.socket(bindPort: AES67.ptpEventPort, interfaceIP: config.interfaceIP, join: AES67.ptpMulticast)) ?? -1
            ptpGeneral = (try? Self.socket(bindPort: AES67.ptpGeneralPort, interfaceIP: config.interfaceIP, join: AES67.ptpMulticast)) ?? -1
        } catch {
            return "AES67: \(error.localizedDescription)"
        }
        statusLock.withLock { $0.sending = true; $0.problem = ptpEvent < 0 ? "Can't listen for PTP (port 319 in use?): free-running" : nil }
        for (fd, name) in [(ptpEvent, "ptp-event"), (ptpGeneral, "ptp-general")] where fd >= 0 {
            let t = Thread { [weak self] in self?.listenPTP(fd) }
            t.name = "understudy.aes67.\(name)"
            t.qualityOfService = .userInitiated
            t.start()
        }
        let sender = Thread { [weak self] in self?.sendLoop() }
        sender.name = "understudy.aes67.send"
        sender.qualityOfService = .userInteractive
        sender.start()
        let sap = Thread { [weak self] in self?.announceLoop() }
        sap.name = "understudy.aes67.sap"
        sap.start()
        return nil
    }

    func stop() {
        guard running.withLock({ let was = $0; $0 = false; return was }) else { return }
        sendSAP(delete: true)
        for fd in [media, ptpEvent, ptpGeneral] where fd >= 0 { close(fd) }
        statusLock.withLock { $0.sending = false }
    }

    deinit { stop() }

    /// The timeline as it is now (cheap: call whenever it changes).
    func update(_ s: TimelineModel.RenderState) {
        state.withLock { $0 = s }
    }

    // MARK: Clock

    /// PTP time now (seconds since the PTP epoch): the master's when locked, else this Mac's
    /// (Unix time + 37 s for TAI, so a free-running stream still has plausible timestamps).
    private func ptpTime(host: Double) -> Double {
        let follower = clock.withLock { $0 }
        if follower.isLocked(at: host), let offset = follower.offset { return host + offset }
        return host + Self.hostToUnix + 37
    }

    private static let hostToUnix: Double = Date().timeIntervalSince1970 - HostClock.now()

    private func listenPTP(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 1500)
        while running.withLock({ $0 }) {
            let n = recv(fd, &buf, buf.count, 0)
            let at = HostClock.now()
            guard n > 0, let message = AES67.parsePTP(Data(buf[0..<n])) else { continue }
            clock.withLock { $0.feed(message, at: at) }
            let f = clock.withLock { $0 }
            statusLock.withLock { $0.grandmaster = f.grandmaster; $0.ptpLocked = f.isLocked(at: at) }
        }
    }

    // MARK: Sending

    private func sendLoop() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let channels = 3
        var samples = [Float](repeating: 0, count: AES67.samplesPerPacket * channels)
        var renderer = TimelineRenderer()
        var sequence = UInt16.random(in: 0...UInt16.max)
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = config.port.bigEndian
        inet_pton(AF_INET, config.multicast, &dest.sin_addr)
        // Packets go out on the millisecond boundaries of PTP time.
        var next = (ptpTime(host: HostClock.now()) * 1000).rounded(.up)
        while running.withLock({ $0 }) {
            let host = HostClock.now()
            let offset = ptpTime(host: host) - host
            let due = next / 1000 - offset                     // host time of this packet's first sample
            if due - host > 0.0005 {
                let ticks = UInt64((due - 0.0002) * 1e9) * UInt64(timebase.denom) / UInt64(timebase.numer)
                mach_wait_until(ticks)
                continue
            }
            if host - due > 0.05 { next = (ptpTime(host: host) * 1000).rounded(.up); continue }   // fell behind: catch up
            let snapshot = state.withLock { $0 }
            samples.withUnsafeMutableBufferPointer { out in
                renderer.render(snapshot, hostStart: due, frames: AES67.samplesPerPacket, into: out)
            }
            let packet = samples.withUnsafeBufferPointer {
                AES67.rtpPacket(sequence: sequence, timestamp: AES67.rtpTimestamp(ptpSeconds: next / 1000), ssrc: ssrc, samples: $0, channels: channels)
            }
            let sent = packet.withUnsafeBytes { raw in
                withUnsafePointer(to: &dest) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(media, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            let failure = sent < 0 ? String(cString: strerror(errno)) : nil
            sequence &+= 1
            next += 1
            statusLock.withLock {
                if let failure { $0.sendErrors += 1; $0.lastSendError = failure } else { $0.packets += 1 }
            }
        }
    }

    // MARK: SAP

    private func sdp() -> String {
        let gm = statusLock.withLock { $0.ptpLocked ? $0.grandmaster : nil }
        let version = sdpVersion.withLock { v -> UInt32 in
            if v.grandmaster != gm { v.grandmaster = gm; v.version += 1 }
            return v.version
        }
        return AES67.sdp(AES67.Stream(name: config.name, sessionID: session, version: version, sourceIP: config.interfaceIP,
                                      multicast: config.multicast, port: config.port, ttl: config.ttl, grandmaster: gm))
    }

    private func sendSAP(delete: Bool = false) {
        guard media >= 0 else { return }
        let packet = AES67.sapPacket(sdp: sdp(), sourceIP: config.interfaceIP, hash: sapHash, delete: delete)
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = AES67.sapPort.bigEndian
        inet_pton(AF_INET, AES67.sapAddress, &dest.sin_addr)
        _ = packet.withUnsafeBytes { raw in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(media, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Announces every 5 s for the first 30 s (so it appears quickly), then every 30 s, and at
    /// once when the PTP grandmaster changes (receivers check the clock it names).
    private func announceLoop() {
        let start = HostClock.now()
        while running.withLock({ $0 }) {
            sendSAP()
            let announced = statusLock.withLock { $0.ptpLocked ? $0.grandmaster : nil }
            let interval = HostClock.now() - start < 30 ? 5.0 : 30.0
            var waited = 0.0
            while waited < interval, running.withLock({ $0 }) {
                Thread.sleep(forTimeInterval: 0.25); waited += 0.25
                if statusLock.withLock({ $0.ptpLocked ? $0.grandmaster : nil }) != announced { break }
            }
        }
    }

    // MARK: Sockets

    private static func socket(bindPort: UInt16, interfaceIP: String, ttl: Int = 15, join group: String? = nil) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw posix("socket") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = bindPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { close(fd); throw posix("bind port \(bindPort)") }
        var iface = in_addr()
        inet_pton(AF_INET, interfaceIP, &iface)
        // Send multicast out of the chosen port, with a TTL, and loop it back (so this Mac can monitor it).
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &iface, socklen_t(MemoryLayout<in_addr>.size))
        var t = UInt8(clamping: ttl)
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &t, socklen_t(MemoryLayout<UInt8>.size))
        var loop: UInt8 = 1
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<UInt8>.size))
        if let group {
            var mreq = ip_mreq()
            inet_pton(AF_INET, group, &mreq.imr_multiaddr)
            mreq.imr_interface = iface
            guard setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 else {
                close(fd); throw posix("join \(group)")
            }
            var timeout = timeval(tv_sec: 1, tv_usec: 0)   // so the listener notices stop()
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        return fd
    }

    private static func posix(_ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(errno)))"])
    }
}

/// Renders the timeline at 48 kHz for the AES67 sender: left and right from each song's audio,
/// timecode from the song's own timecode channel or generated, as LTC out does. Song files are
/// read in 100 ms blocks and resampled linearly (fine for a test feed).
struct TimelineRenderer {
    private var readers: [String: BlockReader] = [:]
    private var generator: LTCGenerator?
    private var genRate: FrameRate?

    /// Fills `out` (interleaved L, R, TC) for `frames` samples starting at host time `hostStart`.
    mutating func render(_ s: TimelineModel.RenderState?, hostStart: Double, frames: Int, into out: UnsafeMutableBufferPointer<Float>) {
        for i in out.indices { out[i] = 0 }
        guard let s, s.transport.isPlaying, !s.scrubbing else {
            generator = nil
            return
        }
        if genRate != s.rate { generator = LTCGenerator(rate: s.rate, sampleRate: Double(AES67.sampleRate)); genRate = s.rate }
        let dt = 1.0 / Double(AES67.sampleRate)
        let t0 = s.transport.position(at: hostStart)
        // Timecode: from the song's own channel inside its file, else generated show code.
        var tc = [Float](repeating: 0, count: frames)
        var trackCode = false
        if let i = s.layout.index(at: t0) {
            let item = s.layout.items[i]
            let fileStart = item.timelineStart + (item.song.audioOffset ?? 0)
            if let src = s.sources[item.song.id] {
                if let music = src.music, var reader = readers[music] ?? BlockReader(path: music) {
                    for f in 0..<frames {
                        let t = t0 + Double(f) * dt
                        guard t >= fileStart, t < item.timelineEnd else { continue }
                        let (l, r) = reader.sample(at: t - fileStart)
                        out[f * 3] = l
                        out[f * 3 + 1] = r
                    }
                    readers[music] = reader
                }
                if let code = src.timecode, var reader = readers[code] ?? BlockReader(path: code), t0 >= fileStart, t0 < item.timelineEnd {
                    for f in 0..<frames { tc[f] = reader.sample(at: t0 + Double(f) * dt - fileStart).0 }
                    readers[code] = reader
                    trackCode = true
                }
            }
        }
        if !trackCode {
            let frame = s.layout.showSeconds(at: t0).map { $0 * s.rate.ltcRate.exact }
            tc.withUnsafeMutableBufferPointer { generator?.render(into: $0.baseAddress!, count: frames, framePosition: frame) }
        }
        for f in 0..<frames { out[f * 3 + 2] = tc[f] }
        if readers.count > 8 { readers = readers.filter { _ in false } }   // a set change: start fresh
    }
}

/// Reads a file in blocks for sample-by-sample access at any rate.
struct BlockReader {
    private let file: AVAudioFile
    private let rate: Double
    private let channels: Int
    private var block: [[Float]] = []
    private var blockStart: AVAudioFramePosition = -1
    private static let blockFrames: AVAudioFrameCount = 4800

    init?(path: String) {
        guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        file = f
        rate = f.processingFormat.sampleRate
        channels = Int(f.processingFormat.channelCount)
    }

    /// Left and right (mono files give the same to both) at `seconds` into the file, 0 outside it.
    mutating func sample(at seconds: Double) -> (Float, Float) {
        let pos = seconds * rate
        let i = AVAudioFramePosition(pos.rounded(.down))
        guard i >= 0, i + 1 < file.length else { return (0, 0) }
        let frac = Float(pos - Double(i))
        func value(_ c: Int, _ k: AVAudioFramePosition) -> Float {
            if k < blockStart || k >= blockStart + AVAudioFramePosition(block.first?.count ?? 0) { load(k) }
            let ch = block.indices.contains(c) ? c : 0
            let idx = Int(k - blockStart)
            return block.indices.contains(ch) && block[ch].indices.contains(idx) ? block[ch][idx] : 0
        }
        let l = value(0, i) * (1 - frac) + value(0, i + 1) * frac
        let r = channels > 1 ? value(1, i) * (1 - frac) + value(1, i + 1) * frac : l
        return (l, r)
    }

    private mutating func load(_ k: AVAudioFramePosition) {
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: Self.blockFrames) else { return }
        file.framePosition = k
        try? file.read(into: buf, frameCount: Self.blockFrames)
        let n = Int(buf.frameLength)
        block = (0..<channels).map { c in
            guard let d = buf.floatChannelData?[c] else { return [] }
            return Array(UnsafeBufferPointer(start: d, count: n))
        }
        blockStart = k
    }
}
