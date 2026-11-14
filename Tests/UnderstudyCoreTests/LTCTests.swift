import Testing
@testable import UnderstudyCore

struct LTCTests {
    private func decode(_ samples: [Float], sampleRate: Double) -> [LTCFrame] {
        let decoder = LTCDecoder(sampleRate: sampleRate)
        var frames: [LTCFrame] = []
        samples.withUnsafeBufferPointer { buf in
            decoder.process(buf.baseAddress!, count: buf.count) { frames.append($0) }
        }
        return frames
    }

    @Test(arguments: [44_100.0, 48_000.0, 96_000.0])
    func decodesEncodedLTCAcrossRates(sampleRate: Double) throws {
        let start = try #require(Timecode("00:59:59:00"))
        for rate in [FrameRate.fps23_976, .fps24, .fps25, .fps29_97DF, .fps30] {
            let audio = LTCEncoder.render(start: start, frameCount: 60, rate: rate, sampleRate: sampleRate)
            for signal in [audio, audio.map { -$0 * 0.3 }] {
                let frames = decode(signal, sampleRate: sampleRate)
                #expect(frames.count >= 58, "\(rate) @ \(sampleRate)")
                guard let first = frames.first else { continue }
                let firstIndex = first.timecode.frameIndex(at: rate)
                for (k, f) in frames.enumerated() {
                    #expect(f.timecode == Timecode(frameIndex: firstIndex + k, rate: rate))
                    #expect(f.dropFrameFlag == rate.isDropFrame)
                }
            }
        }
    }

    @Test func clockRollsAndDetectsJumps() throws {
        var clock = LTCClock(rate: .fps25)
        let start = try #require(Timecode("10:00:00:00")).frameIndex(at: .fps25)
        for k in 0..<10 {
            clock.ingest(Timecode(frameIndex: start + k, rate: .fps25), dropFrameFlag: false, boundaryTime: Double(k + 1) / 25)
        }
        let now = 10.0 / 25 + 0.02
        #expect(clock.isRolling(at: now))
        let position = try #require(clock.position(at: now))
        #expect(abs(position - (Double(start + 10) + 0.5)) <= 1e-6)
        #expect(!clock.snapshot(at: now).jumped)

        // A jump takes two agreeing frames.
        clock.ingest(Timecode(frameIndex: start + 500, rate: .fps25), dropFrameFlag: false, boundaryTime: 11.0 / 25)
        #expect(!clock.snapshot(at: 11.0 / 25).jumped)
        clock.ingest(Timecode(frameIndex: start + 501, rate: .fps25), dropFrameFlag: false, boundaryTime: 12.0 / 25)
        #expect(clock.snapshot(at: 12.0 / 25).jumped)
        #expect(!clock.isRolling(at: 12.0 / 25 + 2.5))
    }

    @Test func freewheelsThroughDropout() throws {
        var clock = LTCClock(rate: .fps25, freewheel: 2.0)
        let start = try #require(Timecode("10:00:00:00")).frameIndex(at: .fps25)
        for k in 0..<25 {
            clock.ingest(Timecode(frameIndex: start + k, rate: .fps25), dropFrameFlag: false, boundaryTime: Double(k + 1) / 25)
        }
        // LTC vanishes at t = 1.0 s. At 2.0 s the clock is still counting on its own.
        #expect(clock.isRolling(at: 2.0))
        #expect(clock.isFreewheeling(at: 2.0))
        let position = try #require(clock.position(at: 2.0))
        #expect(abs(position - Double(start + 50)) <= 1e-6)
        // Past the freewheel window it stops.
        #expect(!clock.isRolling(at: 3.1))

        // Code comes back at 1.5 s where it should be: no jump, no longer freewheeling.
        clock.ingest(Timecode(frameIndex: start + 36, rate: .fps25), dropFrameFlag: false, boundaryTime: 1.5)
        #expect(!clock.snapshot(at: 1.5).jumped)
        #expect(!clock.isFreewheeling(at: 1.55))
    }

    @Test func freewheelCatchesJumpAfterDropout() throws {
        var clock = LTCClock(rate: .fps25, freewheel: 2.0)
        let start = try #require(Timecode("10:00:00:00")).frameIndex(at: .fps25)
        for k in 0..<25 {
            clock.ingest(Timecode(frameIndex: start + k, rate: .fps25), dropFrameFlag: false, boundaryTime: Double(k + 1) / 25)
        }
        // After a 1 s gap, code returns somewhere else (two frames confirm it).
        clock.ingest(Timecode(frameIndex: start + 9_000, rate: .fps25), dropFrameFlag: false, boundaryTime: 2.0)
        clock.ingest(Timecode(frameIndex: start + 9_001, rate: .fps25), dropFrameFlag: false, boundaryTime: 2.04)
        #expect(clock.snapshot(at: 2.04).jumped)
    }

    @Test func singleCorruptFrameIsIgnored() throws {
        var clock = LTCClock(rate: .fps30, freewheel: 2.0)
        let start = try #require(Timecode("01:00:00:00")).frameIndex(at: .fps30)
        for k in 0..<30 {
            clock.ingest(Timecode(frameIndex: start + k, rate: .fps30), dropFrameFlag: false, boundaryTime: Double(k + 1) / 30)
        }
        // One bit flipped: 01:00:01:00 decodes as 03:00:01:00. The next frame is back on track.
        clock.ingest(Timecode(frameIndex: start + 30 + 2 * 3600 * 30, rate: .fps30), dropFrameFlag: false, boundaryTime: 31.0 / 30)
        clock.ingest(Timecode(frameIndex: start + 31, rate: .fps30), dropFrameFlag: false, boundaryTime: 32.0 / 30)
        #expect(!clock.snapshot(at: 32.0 / 30).jumped)
        let position = try #require(clock.position(at: 32.0 / 30))
        #expect(abs(position - Double(start + 32)) < 0.01)
    }

    @Test func heldFrameStopsAtOnce() throws {
        var clock = LTCClock(rate: .fps25, freewheel: 2.0)
        let tc = try #require(Timecode("10:00:00:00"))
        clock.ingest(tc, dropFrameFlag: false, boundaryTime: 0.04)
        clock.ingest(tc, dropFrameFlag: false, boundaryTime: 0.08)
        #expect(!clock.isRolling(at: 0.1))
    }
}
