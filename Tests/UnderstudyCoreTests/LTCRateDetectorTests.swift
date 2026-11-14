import Testing
@testable import UnderstudyCore

struct LTCRateDetectorTests {
    /// Feeds `seconds` of frames at `rate`, starting at `t0`, with up to ±`jitter` s timing noise.
    @discardableResult
    private func feed(
        _ d: inout LTCRateDetector, rate: FrameRate, seconds: Double, t0: Double = 0, jitter: Double = 0
    ) -> Double {
        let frames = Int(seconds * rate.exact)
        var t = t0
        for k in 0..<frames {
            t = t0 + Double(k + 1) / rate.exact + (jitter == 0 ? 0 : Double.random(in: -jitter...jitter))
            d.ingest(dropFrameFlag: rate.isDropFrame, time: t)
        }
        return t
    }

    @Test(arguments: [FrameRate.fps23_976, .fps24, .fps25, .fps29_97DF, .fps29_97, .fps30])
    func detectsEachRate(rate: FrameRate) {
        var d = LTCRateDetector()
        // ±2 samples of edge jitter at 48 kHz.
        feed(&d, rate: rate, seconds: 3, jitter: 2.0 / 48_000)
        #expect(d.detected == rate)
    }

    @Test func waitsForEnoughCode() {
        var d = LTCRateDetector()
        feed(&d, rate: .fps25, seconds: 1.5)
        #expect(d.detected == nil)
        feed(&d, rate: .fps25, seconds: 1.5, t0: 1.5 - 1.0 / 25)
        #expect(d.detected == .fps25)
    }

    @Test func gapRestartsMeasurement() {
        var d = LTCRateDetector()
        feed(&d, rate: .fps25, seconds: 1.5)
        // Half a second of silence, then 1.5 s more: neither run is long enough on its own.
        feed(&d, rate: .fps25, seconds: 1.5, t0: 2.0)
        #expect(d.detected == nil)
    }

    @Test func switchesRateOnlyOnceConfirmed() {
        var d = LTCRateDetector()
        var t = feed(&d, rate: .fps25, seconds: 3)
        #expect(d.detected == .fps25)
        // A new source at 23.976 after a short break. After 2.5 s it's measured but not yet trusted.
        t = feed(&d, rate: .fps23_976, seconds: 2.5, t0: t + 0.5)
        #expect(d.detected == .fps25)
        feed(&d, rate: .fps23_976, seconds: 2.5, t0: t)
        #expect(d.detected == .fps23_976)
    }

    /// A noisy cable losing one frame in ten must not turn 30 into 29.97 (or 24 into 23.976).
    @Test(arguments: [FrameRate.fps30, .fps24, .fps25, .fps29_97])
    func missedFramesDontBiasTheRate(rate: FrameRate) {
        var d = LTCRateDetector()
        for k in 0..<Int(6 * rate.exact) where k % 10 != 7 {
            d.ingest(dropFrameFlag: false, time: Double(k + 1) / rate.exact)
        }
        #expect(d.detected == rate)
    }

    @Test func ignoresNonsense() {
        #expect(LTCRateDetector.classify(fps: 27.5, dropFrame: false) == nil)
        #expect(LTCRateDetector.classify(fps: 29.97, dropFrame: true) == .fps29_97DF)
        #expect(LTCRateDetector.classify(fps: 25, dropFrame: true) == .fps25)
    }

    /// Real LTC audio through the decoder, timed on the sample clock as the app does.
    @Test(arguments: [FrameRate.fps23_976, .fps24, .fps25, .fps29_97DF, .fps29_97, .fps30])
    func detectsFromDecodedAudio(rate: FrameRate) throws {
        let sampleRate = 48_000.0
        let start = try #require(Timecode("01:00:00:00"))
        let audio = LTCEncoder.render(start: start, frameCount: Int(4 * rate.exact), rate: rate, sampleRate: sampleRate)
        let decoder = LTCDecoder(sampleRate: sampleRate)
        var d = LTCRateDetector()
        audio.withUnsafeBufferPointer { buf in
            decoder.process(buf.baseAddress!, count: buf.count) { frame in
                d.ingest(dropFrameFlag: frame.dropFrameFlag, time: Double(frame.boundarySample) / sampleRate)
            }
        }
        #expect(d.detected == rate)
        let measured = try #require(d.measuredFPS)
        #expect(abs(measured - rate.exact) < 0.002)
    }
}
