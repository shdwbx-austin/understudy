import Foundation
import Testing
@testable import UnderstudyCore

struct AudioMatcherTests {
    private let songs = ["100 Summers", "Matchbox", "Matchbox (no intro)", "Mr. Brightside", "Heart", "Hell Nah",
                         "Sugar We're Goin Down", "Seven"]

    @Test func matchesFileNamesWithExtrasToTheMostSpecificSong() {
        let files = [
            "/show/01 100 Summers.wav",
            "/show/Matchbox.wav",
            "/show/Matchbox (No Intro).wav",
            "/show/TP - Mr. Brightside - 148bpm - SMPTE 12.aif",
            "/show/Heart (Acoustic).wav",
            "/show/Heart.wav",
            "/show/Sugar Were Goin Down.m4a",
            "/show/notes.txt",
            "/show/Seven - Click.wav",
        ]
        let matched = AudioMatcher.match(songs: songs, files: files)
        #expect(matched["100 Summers"] == "/show/01 100 Summers.wav")
        #expect(matched["Matchbox"] == "/show/Matchbox.wav")
        #expect(matched["Matchbox (no intro)"] == "/show/Matchbox (No Intro).wav")
        #expect(matched["Mr. Brightside"] == "/show/TP - Mr. Brightside - 148bpm - SMPTE 12.aif")
        #expect(matched["Heart"] == "/show/Heart.wav")
        #expect(matched["Sugar We're Goin Down"] == "/show/Sugar Were Goin Down.m4a")
        #expect(matched["Hell Nah"] == nil)
        // A click track is not the song.
        #expect(matched["Seven"] == nil)
    }

    @Test func apostrophesAndPunctuationDontMatter() {
        let matched = AudioMatcher.match(songs: ["Sugar We're Goin Down", "All's Well That Ends"],
                                         files: ["/a/Sugar We're Goin Down.wav", "/a/Alls Well That Ends.wav"])
        #expect(matched["Sugar We're Goin Down"] == "/a/Sugar We're Goin Down.wav")
        #expect(matched["All's Well That Ends"] == "/a/Alls Well That Ends.wav")
    }

    @Test func onlyAnAcousticFileLeavesThePlainSongEmpty() {
        let matched = AudioMatcher.match(songs: ["Heart"], files: ["/a/Heart (Acoustic).wav"])
        #expect(matched.isEmpty)
    }
}

struct PeakAccumulatorTests {
    @Test func loudestSampleInEachSlice() {
        var acc = PeakAccumulator(totalFrames: 8, buckets: 4)
        let values: [Float] = [0.1, 0.5, 0.2, 0.2, 0.9, 0.0, 0.3, 0.4]
        values.withUnsafeBufferPointer { acc.add(UnsafeBufferPointer(rebasing: $0[0..<3])) }   // chunked
        values.withUnsafeBufferPointer { acc.add(UnsafeBufferPointer(rebasing: $0[3..<8])) }
        #expect(acc.peaks == [0.5, 0.2, 0.9, 0.4])
        #expect(abs((acc.normalized.first ?? 0) - Float(0.5) / Float(0.9)) < 1e-6)
    }

    @Test func fewerFramesThanBuckets() {
        let acc = PeakAccumulator(totalFrames: 3, buckets: 100)
        #expect(acc.peaks.count == 3)
    }
}

struct LTCChannelScannerTests {
    /// Stereo stems-style file: music on the left, LTC on the right starting 2 s before the song.
    @Test func findsTheTimecodeChannelAndWhereTheFileStarts() throws {
        let sampleRate = 48_000.0
        let start = Timecode("09:19:58:00")!
        let ltc = LTCEncoder.render(start: start, frameCount: 300, rate: .fps30, sampleRate: sampleRate)
        let music = (0..<ltc.count).map { Float(sin(Double($0) * 2 * .pi * 220 / sampleRate)) * 0.5 }
        let scanner = LTCChannelScanner(channels: 2, sampleRate: sampleRate, rate: .fps30)
        // Fed in blocks, both channels in step.
        var n = 0
        while n < ltc.count {
            let count = min(1024, ltc.count - n)
            music.withUnsafeBufferPointer { scanner.feed(channel: 0, $0.baseAddress! + n, count: count) }
            ltc.withUnsafeBufferPointer { scanner.feed(channel: 1, $0.baseAddress! + n, count: count) }
            n += count
        }
        let result = try #require(scanner.result())
        #expect(result.channel == 1)
        #expect(abs(result.fileStartSeconds - start.seconds(at: .fps30)) < 0.002)
        // Against the song list's 09:20:00:00: the file has 2 s of pre-roll.
        let offset = try #require(result.offset(fromSongStart: Timecode("09:20:00:00")!.seconds(at: .fps30)))
        #expect(abs(offset + 2) < 0.002)
        // A file whose code is an hour away isn't this song's show code.
        #expect(result.offset(fromSongStart: Timecode("10:20:00:00")!.seconds(at: .fps30)) == nil)
    }

    @Test func musicAloneHasNoTimecode() {
        let music = (0..<96_000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        let scanner = LTCChannelScanner(channels: 1, sampleRate: 48_000, rate: .fps30)
        music.withUnsafeBufferPointer { scanner.feed(channel: 0, $0.baseAddress!, count: $0.count) }
        #expect(scanner.result() == nil)
    }
}
