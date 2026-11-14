import Testing
@testable import UnderstudyCore

struct TimecodeTests {
    @Test(arguments: [FrameRate.fps29_97DF, .fps59_94DF, .fps25, .fps23_976])
    func dropFrameRoundTrip(rate: FrameRate) {
        for index in stride(from: 0, to: 40_000, by: 7) {
            let tc = Timecode(frameIndex: index, rate: rate)
            #expect(tc.frameIndex(at: rate) == index, "\(rate) \(tc)")
        }
    }

    @Test func dropFrameSkipsLabels() {
        #expect(Timecode(frameIndex: 1799, rate: .fps29_97DF).description == "00:00:59:29")
        #expect(Timecode(frameIndex: 1800, rate: .fps29_97DF).description == "00:01:00:02")
        #expect(Timecode(frameIndex: 17982, rate: .fps29_97DF).description == "00:10:00:00")
        #expect(Timecode(frameIndex: 3600, rate: .fps59_94DF).description == "00:01:00:04")
    }

    @Test func familiesShareLabelTime() throws {
        let tc = try #require(Timecode("01:00:00:00"))
        #expect(abs(tc.seconds(at: .fps29_97DF) - tc.seconds(at: .fps59_94DF)) <= 1e-9)
        #expect(abs(tc.seconds(at: .fps25) - tc.seconds(at: .fps50)) <= 1e-9)
    }

    @Test func parse() {
        #expect(Timecode("01:02:03;04") == Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4))
        #expect(Timecode("01:02:03") == nil)
        #expect(Timecode("01:72:03:00") == nil)
    }

    @Test func videoFormats() {
        #expect(FrameRate.fromVideoFormat("2160p5994", dropFrame: true) == .fps59_94DF)
        #expect(FrameRate.fromVideoFormat("4Kp5994", dropFrame: false) == .fps59_94)
        #expect(FrameRate.fromVideoFormat("2160p59.94", dropFrame: false) == .fps59_94)
        #expect(FrameRate.fromVideoFormat("1080i5994", dropFrame: true) == .fps29_97DF)
        #expect(FrameRate.fromVideoFormat("1080p25", dropFrame: false) == .fps25)
        #expect(FrameRate.fromVideoFormat("1080p23976", dropFrame: false) == .fps23_976)
        #expect(FrameRate.fromVideoFormat("none", dropFrame: false) == nil)
    }

    /// Names the HyperDeck Extreme 8K HDR can report: 8K, DCI 4K/8K and PsF variants.
    @Test(arguments: [
        ("4320p5994", FrameRate.fps59_94), ("4320p2398", .fps23_976), ("4320p50", .fps50), ("4320p60", .fps60),
        ("8Kp5994", .fps59_94), ("8KDCIp24", .fps24), ("4KDCIp25", .fps25), ("4KDCIp2398", .fps23_976),
        ("2160p2997", .fps29_97), ("1080PsF2398", .fps23_976), ("1080PsF25", .fps25), ("1080PsF2997", .fps29_97),
        ("1080i50", .fps25), ("720p5994", .fps59_94),
    ])
    func extremeFormats(name: String, rate: FrameRate) {
        #expect(FrameRate.fromVideoFormat(name, dropFrame: false) == rate, "\(name)")
    }
}
