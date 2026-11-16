import Foundation
import Testing
@testable import UnderstudyCore

@Suite("AES67")
struct AES67Tests {
    @Test func rtpPacketLayout() {
        let samples: [Float] = [1, -1, 0, 0.5, -0.5, 0]   // 2 frames × 3 channels
        let d = samples.withUnsafeBufferPointer { AES67.rtpPacket(sequence: 0x1234, timestamp: 0xA1B2C3D4, ssrc: 0x01020304, samples: $0, channels: 3) }
        let b = [UInt8](d)
        #expect(b.count == 12 + 6 * 3)
        #expect(b[0] == 0x80 && b[1] == 96)
        #expect(b[2...3] == [0x12, 0x34])
        #expect(b[4...7] == [0xA1, 0xB2, 0xC3, 0xD4])
        #expect(b[8...11] == [1, 2, 3, 4])
        #expect(b[12...14] == [0x7F, 0xFF, 0xFF])       // +1
        #expect(b[15...17] == [0x80, 0x00, 0x01])       // −1 (−8388607)
        #expect(b[18...20] == [0, 0, 0])
        #expect(b[21...23] == [0x40, 0x00, 0x00])       // +0.5
    }

    @Test func timestampsWrap() {
        #expect(AES67.rtpTimestamp(ptpSeconds: 1) == 48_000)
        // 2^32 samples later it wraps.
        #expect(AES67.rtpTimestamp(ptpSeconds: 4_294_967_296.0 / 48_000 + 1) == 48_000)
    }

    @Test func sdpHasTheAES67Attributes() {
        let s = AES67.Stream(name: "Understudy RKS", sessionID: 42, sourceIP: "192.168.100.253", multicast: "239.69.100.253",
                             grandmaster: "00-1D-C1-FF-FE-12-34-56")
        let sdp = AES67.sdp(s)
        #expect(sdp.hasSuffix("\r\n") && sdp.contains("\r\n"))
        for line in ["v=0", "o=- 42 1 IN IP4 192.168.100.253", "s=Understudy RKS", "c=IN IP4 239.69.100.253/15",
                     "m=audio 5004 RTP/AVP 96", "a=rtpmap:96 L24/48000/3", "a=ptime:1", "a=mediaclk:direct=0",
                     "a=ts-refclk:ptp=IEEE1588-2008:00-1D-C1-FF-FE-12-34-56:0", "a=framecount:48"] {
            #expect(sdp.contains(line + "\r\n"), "missing \(line)")
        }
        #expect(AES67.defaultMulticast(for: "192.168.100.253") == "239.69.100.253")
    }

    @Test func sapPacketLayout() {
        let d = [UInt8](AES67.sapPacket(sdp: "v=0\r\n", sourceIP: "10.0.0.7", hash: 0xBEEF))
        #expect(d[0] == 0x20 && d[1] == 0 && d[2...3] == [0xBE, 0xEF] && d[4...7] == [10, 0, 0, 7])
        #expect(String(decoding: d[8..<23], as: UTF8.self) == "application/sdp" && d[23] == 0)
        #expect(String(decoding: d[24...], as: UTF8.self) == "v=0\r\n")
        #expect(AES67.sapPacket(sdp: "", sourceIP: "10.0.0.7", hash: 1, delete: true).first == 0x24)
    }

    /// A PTPv2 message: common header + 10-byte timestamp (+ Announce fields).
    func ptp(type: UInt8, seq: UInt16, clock: [UInt8], twoStep: Bool = false, seconds: UInt64 = 0, ns: UInt32 = 0, gm: [UInt8]? = nil) -> Data {
        var b = [UInt8](repeating: 0, count: type == 0xB ? 64 : 44)
        b[0] = type; b[1] = 2; b[4] = 0; b[6] = twoStep ? 0x02 : 0
        for i in 0..<8 { b[20 + i] = clock[i] }
        b[30] = UInt8(seq >> 8); b[31] = UInt8(seq & 0xFF)
        for k in 0..<6 { b[34 + k] = UInt8((seconds >> UInt64(8 * (5 - k))) & 0xFF) }
        for k in 0..<4 { b[40 + k] = UInt8((ns >> UInt32(8 * (3 - k))) & 0xFF) }
        if let gm { b[47] = 128; for i in 0..<8 { b[53 + i] = gm[i] } }
        return Data(b)
    }

    @Test func followsATwoStepMaster() {
        let clock: [UInt8] = [0x00, 0x1D, 0xC1, 0xFF, 0xFE, 0x12, 0x34, 0x56]
        #expect(AES67.parsePTP(ptp(type: 0xB, seq: 1, clock: clock, gm: clock))
                == .announce(clock: "00-1D-C1-FF-FE-12-34-56", grandmaster: "00-1D-C1-FF-FE-12-34-56", priority1: 128, domain: 0))
        var f = AES67.ClockFollower()
        f.feed(AES67.parsePTP(ptp(type: 0xB, seq: 1, clock: clock, gm: clock))!, at: 0)
        // Master is 1,000,000.25 s ahead of the local clock: Syncs every 125 ms, Follow_Ups carry the time.
        for n in 0..<12 {
            let local = 100 + Double(n) * 0.125
            let master = local + 1_000_000.25
            f.feed(AES67.parsePTP(ptp(type: 0x0, seq: UInt16(n), clock: clock, twoStep: true))!, at: local)
            let s = UInt64(master), ns = UInt32(((master - Double(s)) * 1e9).rounded())
            f.feed(AES67.parsePTP(ptp(type: 0x8, seq: UInt16(n), clock: clock, seconds: s, ns: ns))!, at: local + 0.0003)
        }
        #expect(f.grandmaster == "00-1D-C1-FF-FE-12-34-56")
        #expect(abs((f.offset ?? 0) - 1_000_000.25) < 1e-6)
        #expect(f.isLocked(at: 101.5) && !f.isLocked(at: 110))
        #expect(AES67.parsePTP(Data([0x0, 0x01] + [UInt8](repeating: 0, count: 40))) == nil)   // PTPv1: ignored
    }
}
