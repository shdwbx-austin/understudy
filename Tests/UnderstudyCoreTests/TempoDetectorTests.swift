import Foundation
import Testing
@testable import UnderstudyCore

/// Tempo detection on generated audio with known answers.
struct TempoDetectorTests {
    static let rate = 48_000.0

    /// A deterministic noise source.
    struct Noise {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 1) % 2_000_000) / 1_000_000 - 1
        }
    }

    /// Adds a decaying sine (kick-like when low, click-like when high) at `time`.
    static func hit(_ out: inout [Float], at time: Double, freq: Double, decay: Double, gain: Float) {
        let start = Int(time * rate)
        let length = Int(decay * 6 * rate)
        for i in 0..<length where start + i < out.count && start + i >= 0 {
            let t = Double(i) / rate
            out[start + i] += gain * Float(sin(2 * .pi * freq * t) * exp(-t / decay))
        }
    }

    static func burst(_ out: inout [Float], at time: Double, length: Double, gain: Float, noise: inout Noise) {
        let start = Int(time * rate)
        let n = Int(length * rate)
        for i in 0..<n where start + i < out.count {
            let env = Float(exp(-Double(i) / (Double(n) / 4)))
            out[start + i] += gain * env * noise.next()
        }
    }

    static func detect(_ audio: [Float], hint: Double? = nil) -> TempoEstimate? {
        var env = OnsetEnvelope(sampleRate: rate)
        env.feed(audio)
        return TempoDetector.estimate(env, hint: hint)
    }

    /// Distance from `t` to the nearest beat of a grid (period, origin), in seconds.
    static func offGrid(_ t: Double, period: Double, origin: Double) -> Double {
        let r = (t - origin).truncatingRemainder(dividingBy: period)
        let x = r < 0 ? r + period : r
        return min(x, period - x)
    }

    @Test func clickTrackWithAccentedOne() throws {
        // 128 BPM, 40 s, first beat at 0.7 s; beat one lower and louder.
        var audio = [Float](repeating: 0, count: Int(40 * Self.rate))
        let period = 60.0 / 128
        var k = 0
        while 0.7 + Double(k) * period < 39.5 {
            let one = k % 4 == 0
            Self.hit(&audio, at: 0.7 + Double(k) * period, freq: one ? 90 : 1500, decay: one ? 0.03 : 0.004, gain: one ? 0.9 : 0.5)
            k += 1
        }
        let e = try #require(Self.detect(audio))
        #expect(e.bpm == 128)
        #expect(e.isConfident)
        #expect(Self.offGrid(e.firstBeat, period: period, origin: 0.7) < 0.015)
        #expect(Self.offGrid(e.downbeat, period: period * 4, origin: 0.7) < 0.015)
    }

    @Test func drumGrooveIsNotHalvedOrDoubled() throws {
        // 96 BPM: kick on 1 and 3, snare on 2 and 4, hats on eighths, 45 s.
        var audio = [Float](repeating: 0, count: Int(45 * Self.rate))
        var noise = Noise()
        let beat = 60.0 / 96
        var k = 0
        while Double(k) * beat < 44 {
            let t = 0.25 + Double(k) * beat
            if k % 2 == 0 { Self.hit(&audio, at: t, freq: 55, decay: 0.06, gain: 0.9) } else { Self.burst(&audio, at: t, length: 0.12, gain: 0.5, noise: &noise) }
            Self.burst(&audio, at: t, length: 0.02, gain: 0.15, noise: &noise)
            Self.burst(&audio, at: t + beat / 2, length: 0.02, gain: 0.15, noise: &noise)
            k += 1
        }
        let e = try #require(Self.detect(audio))
        #expect(e.bpm == 96)
        #expect(Self.offGrid(e.firstBeat, period: beat, origin: 0.25) < 0.015)
        // Beat one is a kick bar line (every 4 beats from 0.25, or the other kick, 2 beats on).
        #expect(Self.offGrid(e.downbeat, period: beat * 2, origin: 0.25) < 0.015)
    }

    @Test func fractionalTempoStaysFractional() throws {
        var audio = [Float](repeating: 0, count: Int(60 * Self.rate))
        let period = 60.0 / 106.67
        var k = 0
        while Double(k) * period < 59 {
            Self.hit(&audio, at: 0.1 + Double(k) * period, freq: 1200, decay: 0.004, gain: 0.6)
            k += 1
        }
        let e = try #require(Self.detect(audio))
        #expect(abs(e.bpm - 106.67) < 0.05)
    }

    @Test func aHintSettlesTheTempoAndTheAudioPlacesTheBeats() throws {
        // A sparse 72 BPM part (a chord every half note) that could read as 36 or 144.
        var audio = [Float](repeating: 0, count: Int(50 * Self.rate))
        let beat = 60.0 / 72
        var k = 0
        while Double(k) * beat < 49 {
            if k % 2 == 0 { Self.hit(&audio, at: 1.3 + Double(k) * beat, freq: 220, decay: 0.2, gain: 0.7) }
            k += 1
        }
        let e = try #require(Self.detect(audio, hint: 72))
        #expect(e.bpm == 72)
        #expect(Self.offGrid(e.firstBeat, period: beat, origin: 1.3) < 0.02)
    }

    @Test func noiseAndSilenceAreNotATempo() {
        #expect(Self.detect([Float](repeating: 0, count: Int(20 * Self.rate))) == nil)
        var noise = Noise()
        let hiss = (0..<Int(20 * Self.rate)).map { _ in noise.next() * 0.2 }
        let e = Self.detect(hiss)
        #expect(e == nil || e!.isConfident == false)
    }

    @Test func aClickChannelBeatsAMushyMix() {
        let mix = TempoEstimate(bpm: 63, firstBeat: 0, downbeat: 0, strength: 1.4)
        let click = TempoEstimate(bpm: 126, firstBeat: 0.2, downbeat: 0.2, strength: 3.1)
        let won = TempoDetector.best(mix: mix, channels: [3: click])
        #expect(won?.bpm == 126 && won?.channel == 3)
        // A channel only a little stronger doesn't beat the mix.
        let near = TempoEstimate(bpm: 64, firstBeat: 0, downbeat: 0, strength: 1.5)
        #expect(TempoDetector.best(mix: mix, channels: [1: near])?.channel == nil)
    }
}

