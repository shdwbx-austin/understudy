import Foundation
import Testing
@testable import UnderstudyCore

struct WaveformBuilderTests {
    private func build(_ samples: [Float], framesPerBucket: Int, chunks: [Int]) -> WaveformPeaks {
        var builder = WaveformBuilder(sampleRate: 48_000, framesPerBucket: framesPerBucket)
        var at = 0
        samples.withUnsafeBufferPointer { all in
            for size in chunks {
                builder.add(UnsafeBufferPointer(rebasing: all[at..<min(all.count, at + size)]))
                at += size
            }
            if at < all.count { builder.add(UnsafeBufferPointer(rebasing: all[at...])) }
        }
        return builder.finish()
    }

    @Test func lowAndHighOfEachSliceScaledToTheLoudest() {
        // Three full slices of 4 and a short last one; fed in chunks that straddle slices.
        let s: [Float] = [0.1, -0.2, 0.3, 0.0,   0.5, 0.5, 0.4, 0.45,   -0.5, 0.25, 0.0, 0.1,   0.05, -0.05]
        let peaks = build(s, framesPerBucket: 4, chunks: [3, 6, 1])
        let base = peaks.levels[0]
        #expect(peaks.frameCount == 14)
        #expect(base.count == 4)
        #expect(base.highs == [76, 127, 64, 13])     // 0.3, 0.5, 0.25, 0.05 of 0.5
        #expect(base.lows == [-51, 102, -127, -13])  // -0.2, 0.4, -0.5, -0.05 of 0.5
    }

    @Test func silenceStaysZero() {
        let peaks = build([Float](repeating: 0, count: 1000), framesPerBucket: 128, chunks: [])
        #expect(peaks.levels[0].highs.allSatisfy { $0 == 0 })
        #expect(peaks.columns(from: 0, to: peaks.duration, count: 10).highs.allSatisfy { $0 == 0 })
    }

    @Test func aFewHundredSlicesASecondAtAnyRate() {
        #expect(WaveformPeaks.framesPerBucket(sampleRate: 44_100) == 128)
        #expect(WaveformPeaks.framesPerBucket(sampleRate: 48_000) == 128)
        #expect(WaveformPeaks.framesPerBucket(sampleRate: 96_000) == 256)
        #expect(WaveformPeaks.framesPerBucket(sampleRate: 192_000) == 512)
    }
}

struct WaveformPeaksTests {
    /// Deterministic noise with a slowly changing loudness, like music.
    private func music(seconds: Double, sampleRate: Double = 48_000) -> [Float] {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        let n = Int(seconds * sampleRate)
        return (0..<n).map { i in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Float(Int64(bitPattern: seed >> 1) % 2001) / 1000 - 1
            let t = Double(i) / sampleRate
            let envelope = Float(0.55 + 0.45 * sin(2 * .pi * 1.7 * t) * sin(2 * .pi * 0.13 * t))
            return noise * envelope
        }
    }

    private func peaks(_ samples: [Float], sampleRate: Double = 48_000) -> WaveformPeaks {
        var builder = WaveformBuilder(sampleRate: sampleRate)
        samples.withUnsafeBufferPointer { builder.add($0) }
        return builder.finish()
    }

    @Test func eachLevelHalvesTheOneBefore() {
        let p = peaks(music(seconds: 3))
        #expect(p.levels.count > 3)
        for (fine, coarse) in zip(p.levels, p.levels.dropFirst()) {
            #expect(coarse.framesPerBucket == fine.framesPerBucket * 2)
            #expect(coarse.count == (fine.count + 1) / 2)
            for j in 0..<coarse.count {
                let pair = (2 * j)...min(2 * j + 1, fine.count - 1)
                #expect(coarse.lows[j] == pair.map { fine.lows[$0] }.min())
                #expect(coarse.highs[j] == pair.map { fine.highs[$0] }.max())
            }
        }
        #expect(p.levels.last!.count <= 16)
    }

    /// Wide columns hold the true low and high of the audio under them, whatever level they're read from.
    @Test func columnsMatchTheAudioUnderThem() {
        let rate = 48_000.0
        let samples = music(seconds: 10)
        let p = peaks(samples)
        let top = samples.map(abs).max()!
        for count in [7, 50, 333, 1200] {
            let from = 1.25, to = 9.5
            let cols = p.columns(from: from, to: to, count: count)
            let perColumn = (to - from) * rate / Double(count)
            for i in 0..<count {
                let a = Int(from * rate + Double(i) * perColumn), b = Int(from * rate + Double(i + 1) * perColumn)
                let slice = samples[a..<b]
                // Columns may take in the buckets they touch at their edges, so they're never less
                // than the audio under them, and only a little more.
                #expect(cols.highs[i] >= slice.max()! / top - 0.01)
                #expect(cols.lows[i] <= slice.min()! / top + 0.01)
                let edge = Int(Double(p.levels.last { Double($0.framesPerBucket) <= perColumn }!.framesPerBucket))
                let wide = samples[max(0, a - edge)..<min(samples.count, b + edge)]
                #expect(cols.highs[i] <= wide.max()! / top + 0.01)
                #expect(cols.lows[i] >= wide.min()! / top - 0.01)
            }
        }
    }

    /// One click in a long, quiet file still shows at the whole-show zoom.
    @Test func aClickIsNeverLostWhenZoomedOut() {
        var samples = [Float](repeating: 0.01, count: 48_000 * 60)
        samples[1_234_567] = 0.9
        let p = peaks(samples)
        let cols = p.columns(from: 0, to: 60, count: 100)
        #expect(cols.highs.max()! > 0.99)
        #expect(cols.highs.firstIndex { $0 > 0.99 } == Int(1_234_567.0 / Double(samples.count) * 100))
    }

    /// The old waveform was 3000 bars a song: in a 4-minute song each was 80 ms, about 60 pixels
    /// at the closest zoom, so a drum hit was a wide block. Now a 5 ms burst stays a few pixels
    /// wide, and zoomed in further its edge is a ramp rather than a step.
    @Test func closeUpsKeepDetail() {
        let rate = 48_000.0
        var samples = music(seconds: 240).map { $0 * 0.05 }
        let burst = Int(122 * rate)
        for i in burst..<(burst + 240) { samples[i] = i % 2 == 0 ? 0.9 : -0.9 }
        let p = peaks(samples)
        // 4 s across a 1500-point window on a Retina screen.
        let wide = p.columns(from: 120, to: 124, count: 3000)
        let loud = wide.highs.indices.filter { wide.highs[$0] > 0.5 }
        #expect((3...10).contains(loud.count))
        #expect(loud.last! - loud.first! == loud.count - 1)
        #expect(abs(Double(loud.first!) - 1500) <= 3)
        // 10 ms across 200 pixels: the rise is spread over the bucket, not one jump.
        let deep = p.columns(from: 121.995, to: 122.005, count: 200)
        let steps = zip(deep.highs.dropFirst(), deep.highs).map { abs($0 - $1) }
        #expect(deep.highs.max()! > 0.99)
        #expect(steps.max()! < 0.05)
    }

    @Test func columnsOutsideTheFileAreEmpty() {
        let p = peaks(music(seconds: 1))
        let cols = p.columns(from: -1, to: 2, count: 30)
        #expect(cols.highs[0..<9].allSatisfy { $0 == 0 })
        #expect(cols.highs[21...].allSatisfy { $0 == 0 })
        #expect(cols.highs[11..<19].allSatisfy { $0 > 0 })
        #expect(p.columns(from: 0, to: 1, count: 0).highs.isEmpty)
        #expect(p.columns(from: 1, to: 1, count: 5).highs == [0, 0, 0, 0, 0])
    }

    @Test func emptyFile() {
        let p = WaveformBuilder(sampleRate: 48_000).finish()
        #expect(p.frameCount == 0)
        #expect(p.columns(from: 0, to: 1, count: 4).highs == [0, 0, 0, 0])
        #expect(WaveformPeaks(encoded: p.encoded())?.frameCount == 0)
    }
}

struct WaveformCacheFileTests {
    private let sample: WaveformPeaks = {
        var b = WaveformBuilder(sampleRate: 44_100)
        let s = (0..<100_000).map { Float(sin(Double($0) * 0.001)) * Float($0 % 7) / 7 }
        s.withUnsafeBufferPointer { b.add($0) }
        return b.finish()
    }()

    @Test func roundTrips() throws {
        let back = try #require(WaveformPeaks(encoded: sample.encoded()))
        #expect(back.sampleRate == 44_100)
        #expect(back.frameCount == 100_000)
        #expect(back.levels == sample.levels)
        #expect(sample.encoded().count == 32 + 2 * sample.levels[0].count)
    }

    @Test func refusesAnythingElse() {
        let good = sample.encoded()
        #expect(WaveformPeaks(encoded: Data()) == nil)
        #expect(WaveformPeaks(encoded: good.dropLast()) == nil)
        // An old analysis.json's peaks, or another file.
        #expect(WaveformPeaks(encoded: Data("{\"peaks\":[0.1,0.2]}".utf8)) == nil)
        // A later format version.
        var newer = good
        newer[4] = UInt8(WaveformPeaks.formatVersion + 1)
        #expect(WaveformPeaks(encoded: newer) == nil)
        // A bucket count that doesn't fit the length.
        var wrong = good
        wrong[28] &+= 1
        #expect(WaveformPeaks(encoded: wrong) == nil)
    }
}
