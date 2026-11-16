import Foundation

/// AES67 sending, the parts that are pure data: RTP packets of 24-bit audio, the SDP that
/// describes the stream, the SAP packet that announces it (so Dante Controller lists it), and
/// reading PTPv2 messages to follow the network's clock.
public enum AES67 {
    public static let sampleRate = 48_000
    /// Samples per packet: 1 ms at 48 kHz (AES67's required packet time).
    public static let samplesPerPacket = 48
    public static let payloadType: UInt8 = 96
    public static let defaultPort: UInt16 = 5004
    public static let sapAddress = "239.255.255.255"
    public static let sapPort: UInt16 = 9875
    public static let ptpEventPort: UInt16 = 319
    public static let ptpGeneralPort: UInt16 = 320
    public static let ptpMulticast = "224.0.1.129"

    // MARK: RTP

    /// One RTP packet: 12-byte header, then `frames` of `channels` 24-bit big-endian samples,
    /// interleaved. `samples` is interleaved floats, −1…1.
    public static func rtpPacket(sequence: UInt16, timestamp: UInt32, ssrc: UInt32,
                                 samples: UnsafeBufferPointer<Float>, channels: Int) -> Data {
        var d = Data(capacity: 12 + samples.count * 3)
        d.append(0x80)                 // V=2, no padding, extension or CSRC
        d.append(payloadType & 0x7F)   // M=0
        d.append(UInt8(sequence >> 8)); d.append(UInt8(sequence & 0xFF))
        for shift in stride(from: 24, through: 0, by: -8) { d.append(UInt8((timestamp >> UInt32(shift)) & 0xFF)) }
        for shift in stride(from: 24, through: 0, by: -8) { d.append(UInt8((ssrc >> UInt32(shift)) & 0xFF)) }
        for s in samples {
            let v = Int32((max(-1, min(1, s)) * 8_388_607).rounded())
            d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8(v & 0xFF))
        }
        return d
    }

    /// The RTP timestamp for a media-clock time in seconds since the PTP epoch
    /// (`mediaclk:direct=0`: samples since the epoch, mod 2^32).
    public static func rtpTimestamp(ptpSeconds: Double) -> UInt32 {
        let samples = (ptpSeconds * Double(sampleRate)).rounded(.down)
        return UInt32(truncatingIfNeeded: Int64(samples.truncatingRemainder(dividingBy: 4_294_967_296)))
    }

    // MARK: SDP

    public struct Stream: Equatable, Sendable {
        public var name: String
        public var sessionID: UInt32
        public var version: UInt32
        public var sourceIP: String
        public var multicast: String
        public var port: UInt16
        public var channels: Int
        public var ttl: Int
        /// The PTP grandmaster's clock identity ("00-1D-C1-FF-FE-12-34-56"), nil while free-running.
        public var grandmaster: String?
        public var domain: Int

        public init(name: String, sessionID: UInt32, version: UInt32 = 1, sourceIP: String, multicast: String,
                    port: UInt16 = AES67.defaultPort, channels: Int = 3, ttl: Int = 15, grandmaster: String? = nil, domain: Int = 0) {
            self.name = name
            self.sessionID = sessionID
            self.version = version
            self.sourceIP = sourceIP
            self.multicast = multicast
            self.port = port
            self.channels = channels
            self.ttl = ttl
            self.grandmaster = grandmaster
            self.domain = domain
        }
    }

    /// The SDP for a stream (RFC 4566 with the AES67 attributes), CRLF line ends.
    public static func sdp(_ s: Stream) -> String {
        let gm = s.grandmaster ?? "00-00-00-00-00-00-00-00"
        return [
            "v=0",
            "o=- \(s.sessionID) \(s.version) IN IP4 \(s.sourceIP)",
            "s=\(s.name)",
            "c=IN IP4 \(s.multicast)/\(s.ttl)",
            "t=0 0",
            "a=clock-domain:PTPv2 \(s.domain)",
            "m=audio \(s.port) RTP/AVP \(payloadType)",
            "i=Left, Right, Timecode",
            "c=IN IP4 \(s.multicast)/\(s.ttl)",
            "a=rtpmap:\(payloadType) L24/\(sampleRate)/\(s.channels)",
            "a=sync-time:0",
            "a=framecount:\(samplesPerPacket)",
            "a=ptime:1",
            "a=mediaclk:direct=0",
            "a=ts-refclk:ptp=IEEE1588-2008:\(gm):\(s.domain)",
            "a=recvonly",
        ].joined(separator: "\r\n") + "\r\n"
    }

    // MARK: SAP (RFC 2974)

    /// An announcement (or, with `delete`, a withdrawal) of `sdp` from `sourceIP`.
    public static func sapPacket(sdp: String, sourceIP: String, hash: UInt16, delete: Bool = false) -> Data {
        var d = Data()
        d.append(delete ? 0x24 : 0x20)   // V=1, IPv4, announce/delete, not encrypted or compressed
        d.append(0)                      // no authentication data
        d.append(UInt8(hash >> 8)); d.append(UInt8(hash & 0xFF))
        d.append(contentsOf: ipv4Bytes(sourceIP))
        d.append(contentsOf: Array("application/sdp".utf8)); d.append(0)
        d.append(contentsOf: Array(sdp.utf8))
        return d
    }

    public static func ipv4Bytes(_ ip: String) -> [UInt8] {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : [0, 0, 0, 0]
    }

    /// A multicast address in AES67's usual range for this Mac (239.69.x.y from its address), so
    /// two Macs don't pick the same one.
    public static func defaultMulticast(for ip: String) -> String {
        let b = ipv4Bytes(ip)
        return "239.69.\(b[2]).\(max(1, b[3]))"
    }

    // MARK: PTPv2

    public enum PTPMessage: Equatable, Sendable {
        /// Sync: two-step masters send the precise time in the Follow_Up.
        case sync(sequence: UInt16, clock: String, twoStep: Bool, origin: Double)
        case followUp(sequence: UInt16, clock: String, preciseOrigin: Double)
        case announce(clock: String, grandmaster: String, priority1: UInt8, domain: UInt8)
    }

    /// Reads the PTPv2 messages a follower needs (Sync, Follow_Up, Announce); nil for others.
    public static func parsePTP(_ data: Data) -> PTPMessage? {
        let b = [UInt8](data)
        guard b.count >= 34, b[1] & 0x0F == 2 else { return nil }   // PTP version 2
        let type = b[0] & 0x0F
        let domain = b[4]
        let twoStep = b[6] & 0x02 != 0
        let clock = b[20..<28].map { String(format: "%02X", $0) }.joined(separator: "-")
        let sequence = UInt16(b[30]) << 8 | UInt16(b[31])
        func timestamp(at i: Int) -> Double? {
            guard b.count >= i + 10 else { return nil }
            var s: UInt64 = 0
            for k in 0..<6 { s = s << 8 | UInt64(b[i + k]) }
            var ns: UInt32 = 0
            for k in 6..<10 { ns = ns << 8 | UInt32(b[i + k]) }
            return Double(s) + Double(ns) / 1e9
        }
        switch type {
        case 0x0:
            guard let t = timestamp(at: 34) else { return nil }
            return .sync(sequence: sequence, clock: clock, twoStep: twoStep, origin: t)
        case 0x8:
            guard let t = timestamp(at: 34) else { return nil }
            return .followUp(sequence: sequence, clock: clock, preciseOrigin: t)
        case 0xB:
            guard b.count >= 64 else { return nil }
            let gm = b[53..<61].map { String(format: "%02X", $0) }.joined(separator: "-")
            return .announce(clock: clock, grandmaster: gm, priority1: b[47], domain: domain)
        default:
            return nil
        }
    }

    /// Follows a PTP master well enough for a test sender: pairs each Sync's local arrival time
    /// with the master's origin time (from the Sync, or its Follow_Up) and keeps the median
    /// offset of the last few. Path delay (tens of µs on a LAN) is ignored; receivers buffer ≥1 ms.
    public struct ClockFollower: Sendable {
        public private(set) var grandmaster: String?
        public private(set) var offset: Double?     // master time − local time, seconds
        private var pending: [UInt16: Double] = [:] // Sync sequence → local arrival time
        private var recent: [Double] = []
        private var master: String?
        public private(set) var lastSync: Double = -.infinity

        public init() {}

        /// Feed a message with its local arrival time (seconds).
        public mutating func feed(_ message: PTPMessage, at local: Double) {
            switch message {
            case let .announce(clock, gm, _, _):
                if master == nil || master == clock { master = clock; grandmaster = gm }
            case let .sync(sequence, clock, twoStep, origin):
                guard master == nil || master == clock else { return }
                master = clock
                lastSync = local
                if twoStep { pending[sequence] = local; if pending.count > 16 { pending.removeAll() } }
                else { add(origin - local) }
            case let .followUp(sequence, clock, precise):
                guard clock == master, let arrived = pending.removeValue(forKey: sequence) else { return }
                add(precise - arrived)
            }
        }

        private mutating func add(_ o: Double) {
            recent = Array((recent + [o]).suffix(9))
            let s = recent.sorted()
            offset = s[s.count / 2]
        }

        /// Locked: a Sync in the last 3 s.
        public func isLocked(at local: Double) -> Bool { offset != nil && local - lastSync < 3 }
    }
}
