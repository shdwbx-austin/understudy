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
