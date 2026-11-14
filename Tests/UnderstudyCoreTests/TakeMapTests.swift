import Foundation
import Testing
@testable import UnderstudyCore

struct TakeMapTests {
    /// Readings every 0.1 s while recording: show code `ltc0 + t`, deck clock `deck0 + t`,
    /// with up to ±`jitter` seconds of network noise on the deck reading.
    private func readings(
        _ builder: inout TakeMapBuilder, ltc0: Double, deck0: Double, seconds: Double, jitter: Double = 0
    ) {
        var noise = SystemRandomNumberGenerator()
        for k in 0..<Int(seconds * 10) {
            let t = Double(k) * 0.1
            let j = jitter == 0 ? 0 : Double.random(in: -jitter...jitter, using: &noise)
            builder.add(ltc: ltc0 + t, deck: deck0 + t + j)
        }
    }

    @Test func steadyCodeIsOneSegment() throws {
        var b = TakeMapBuilder()
        readings(&b, ltc0: 3600, deck0: 100, seconds: 60, jitter: 0.02)
        let map = b.map
        try #require(map.segments.count == 1)
        #expect(abs(map.segments[0].offset - (100 - 3600)) < 0.01)
        let deck = try #require(map.deckSeconds(atLTC: 3630))
        #expect(abs(deck - 130) < 0.01)
        #expect(map.deckSeconds(atLTC: 3500) == nil)
    }

    @Test func dropoutWithSteadyOffsetKeepsOneSegment() throws {
        var b = TakeMapBuilder()
        readings(&b, ltc0: 3600, deck0: 0, seconds: 10)
        // 20 s with no LTC (no readings), then code returns where it should be.
        readings(&b, ltc0: 3630, deck0: 30, seconds: 10)
        let map = b.map
        try #require(map.segments.count == 1)
        // Inside the dropout the deck was still recording, so that code still maps.
        let deck = try #require(map.deckSeconds(atLTC: 3620))
        #expect(abs(deck - 20) < 1e-9)
    }

    @Test func jumpStartsNewSegment() throws {
        var b = TakeMapBuilder()
        readings(&b, ltc0: 3600, deck0: 0, seconds: 30)           // song 1 at 01:00:00
        readings(&b, ltc0: 7200, deck0: 35, seconds: 30)          // code jumps to 02:00:00
        let map = b.map
        try #require(map.segments.count == 2)
        #expect(abs((map.deckSeconds(atLTC: 3610) ?? -1) - 10) < 1e-9)
        #expect(abs((map.deckSeconds(atLTC: 7210) ?? -1) - 45) < 1e-9)
    }

    @Test func singleLateReadingDoesNotSplit() {
        var b = TakeMapBuilder()
        readings(&b, ltc0: 3600, deck0: 0, seconds: 5)
        b.add(ltc: 3605, deck: 5.4)                                // one reply 0.4 s late
        readings(&b, ltc0: 3605.1, deck0: 5.1, seconds: 5)
        #expect(b.map.segments.count == 1)
    }

    @Test func reRolledCodePlaysLatestPerformance() throws {
        var b = TakeMapBuilder()
        readings(&b, ltc0: 3600, deck0: 0, seconds: 60)           // first pass of the song
        readings(&b, ltc0: 3600, deck0: 70, seconds: 30)          // re-rolled from the top
        let map = b.map
        // The re-roll wins where they overlap; the rest of the first pass is still there.
        #expect(abs((map.deckSeconds(atLTC: 3610) ?? -1) - 80) < 1e-9)
        #expect(abs((map.deckSeconds(atLTC: 3650) ?? -1) - 50) < 1e-9)
        for (a, b) in zip(map.segments, map.segments.dropFirst()) {
            #expect(a.ltcEnd <= b.ltcStart)
        }
    }

    @Test func resumeBridgesDowntimeWhenCodeStillLinesUp() throws {
        var first = TakeMapBuilder()
        readings(&first, ltc0: 3600, deck0: 0, seconds: 10)
        // App was down from 10 s to 15 s; the deck kept recording.
        var resumed = TakeMapBuilder(resuming: first.map)
        readings(&resumed, ltc0: 3615, deck0: 15, seconds: 10)
        let map = resumed.map
        #expect(map.segments.count == 1)
        #expect(abs((map.deckSeconds(atLTC: 3612) ?? -1) - 12) < 1e-9)
    }

    @Test func resumeAfterJumpKeepsBothStretches() throws {
        var first = TakeMapBuilder()
        readings(&first, ltc0: 3600, deck0: 0, seconds: 10)
        var resumed = TakeMapBuilder(resuming: first.map)
        readings(&resumed, ltc0: 7200, deck0: 15, seconds: 10)
        let map = resumed.map
        #expect(abs((map.deckSeconds(atLTC: 3605) ?? -1) - 5) < 1e-9)
        #expect(abs((map.deckSeconds(atLTC: 7205) ?? -1) - 20) < 1e-9)
    }

    @Test func offsetChangeMidRunLeavesNoGap() throws {
        var b = TakeMapBuilder()
        readings(&b, ltc0: 3600, deck0: 0, seconds: 10)
        // Show code slips 0.2 s with no dropout.
        readings(&b, ltc0: 3610, deck0: 10.2, seconds: 10)
        let map = b.map
        try #require(map.segments.count == 2)
        #expect(map.segments[0].ltcEnd == map.segments[1].ltcStart)
        #expect(map.deckSeconds(atLTC: 3609.95) != nil)
    }

    @Test func clippedToOneClip() throws {
        let map = TakeMap(segments: [.init(ltcStart: 3600, ltcEnd: 3700, offset: -3500)])  // deck 100...200
        let clipped = map.clipped(toDeck: 150, 400)
        try #require(clipped.segments.count == 1)
        #expect(clipped.segments[0].ltcStart == 3650)
        #expect(clipped.segments[0].ltcEnd == 3700)
        #expect(map.clipped(toDeck: 300, 400).isEmpty)
    }

    @Test func identityMatchesClipTimecode() {
        let map = TakeMap.identity(deckStart: 3600, duration: 60)
        #expect(map.deckSeconds(atLTC: 3630) == 3630)
        #expect(map.deckSeconds(atLTC: 3660) == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        var b = TakeMapBuilder()
        readings(&b, ltc0: 3600, deck0: 0, seconds: 10)
        readings(&b, ltc0: 7200, deck0: 12, seconds: 10)
        let data = try JSONEncoder().encode(b.map)
        #expect(try JSONDecoder().decode(TakeMap.self, from: data) == b.map)
    }
}

struct SettingsTests {
    @Test func loadsSettingsSavedByVersion010() throws {
        // As saved by 0.1.0: no recordMode / freewheelSeconds, and a field that no longer exists.
        let json = """
        {"decks":[{"id":0,"name":"PGM","host":"10.0.0.11","enabled":true,"playOffsetFrames":2.5},
                  {"id":1,"name":"ME 2","host":"10.0.0.12","enabled":true,"playOffsetFrames":0},
                  {"id":2,"name":"ME 3","host":"","enabled":false,"playOffsetFrames":0},
                  {"id":3,"name":"ME 4","host":"","enabled":true,"playOffsetFrames":0}],
         "ltcRate":"25","audioChannel":2,"followLatestTake":false,"deckTimecodeAtVideoRate":true,
         "nativeRecordTrigger":false,
         "chase":{"prerollSeconds":2,"cueSettleSeconds":0.5,"toleranceFrames":1.5,"driftStrikes":4,
                  "recueCooldownSeconds":1,"playGraceSeconds":0.75}}
        """
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.decks[0].host == "10.0.0.11")
        #expect(s.decks[0].name == "PGM")
        #expect(s.decks[0].playOffsetFrames == 2.5)
        #expect(s.decks[2].enabled == false)
        #expect(s.ltcRate == .fps25)
        #expect(s.audioChannel == 2)
        #expect(s.chase.prerollSeconds == 2)
        #expect(s.recordMode == .continuous)
        #expect(s.freewheelSeconds == 2.0)
    }

    @Test func repairsWrongDeckCount() throws {
        let json = #"{"decks":[{"id":1,"name":"B","host":"10.0.0.2"}]}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.decks.map(\.id) == [0, 1, 2, 3])
        #expect(s.decks[1].host == "10.0.0.2")
    }
}
