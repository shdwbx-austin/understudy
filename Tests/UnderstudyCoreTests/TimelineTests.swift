import Foundation
import Testing
@testable import UnderstudyCore

struct SongListCSVTests {
    @Test func headerDecidesColumnsAndQuotesKeepCommas() throws {
        let csv = """
        Start,Song,End
        01:00:00:00,"Jesus Paid It All, Reprise",01:04:10:00
        02:00:00:00,He Arose,
        """
        let songs = try SongListCSV.parse(csv)
        #expect(songs.count == 2)
        #expect(songs[0].name == "Jesus Paid It All, Reprise")
        #expect(songs[0].start == Timecode("01:00:00:00"))
        #expect(songs[0].end == Timecode("01:04:10:00"))
        #expect(songs[1].name == "He Arose")
        #expect(songs[1].end == nil)
    }

    @Test func noHeaderSemicolonsAndSecondsOnly() throws {
        let songs = try SongListCSV.parse("Opener;01:00:00\r\nClose;\"03:00:05;12\"\r\n")
        #expect(songs.map(\.name) == ["Opener", "Close"])
        #expect(songs[0].start == Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0))
        #expect(songs[1].start == Timecode("03:00:05:12"))
    }

    /// The RKS26 programming sheet: "LTC Start Point" in H:MM:SS, a Duration in m:ss, a dashed
    /// rule under the header, and songs with no start (blank or n/a) that can't be placed.
    @Test func programmingSheetWithDurationsAndUnplacedSongs() throws {
        let csv = """
        SONG,Duration,LTC Start Point
        ———,———,———
        100 Summers,4:01,9:20:00
        All's Well That Ends,3:30,1:00:00
        Bare Bones,3:20,
        Bare Bones (Acoustic),3:20,n/a
        First Class,6:00,2:50:00
        Mr. Brightside,3:37,12:10:00
        """
        let result = try SongListCSV.read(csv)
        #expect(result.songs.map(\.name) == ["100 Summers", "All's Well That Ends", "First Class", "Mr. Brightside"])
        #expect(result.skipped == ["Bare Bones", "Bare Bones (Acoustic)"])
        #expect(result.songs[0].start == Timecode("09:20:00:00"))
        #expect(result.songs[0].duration == 241)
        #expect(result.songs[2].duration == 360)
        #expect(result.songs[3].start == Timecode("12:10:00:00"))
        // Durations set the song lengths on the timeline.
        let layout = TimelineLayout(ordered: result.songs, rate: .fps30, gap: 2)
        #expect(layout.items.map(\.duration) == [241, 210, 360, 217])
    }

    @Test func durationFormats() {
        #expect(SongListCSV.seconds("4:01") == 241)
        #expect(SongListCSV.seconds("1:02:03") == 3723)
        #expect(SongListCSV.seconds("95") == 95)
        #expect(SongListCSV.seconds("n/a") == nil)
    }

    @Test func badRowNamesTheLine() {
        #expect(throws: SongListError.badRow(line: 3, reason: "start timecode should be HH:MM:SS:FF, got \"soon\".")) {
            try SongListCSV.parse("Name,Start\nA,01:00:00:00\nB,soon\n")
        }
        #expect(throws: SongListError.empty) { try SongListCSV.parse("Name,Start\n") }
    }
}

struct TimelineLayoutTests {
    private let a = Song(name: "A", start: Timecode("01:00:00:00")!, end: Timecode("01:03:00:00")!)
    private let b = Song(name: "B", start: Timecode("02:00:00:00")!, audioDuration: 200)
    private let c = Song(name: "C", start: Timecode("03:00:00:00")!)

    @Test func durationsFromEndNextSongOrAudio() {
        let layout = TimelineLayout(ordered: [a, b, c], rate: .fps30, gap: 2)
        #expect(layout.items.map(\.duration) == [180, 200, TimelineLayout.openEndedDuration])
        // A: lead-in 0–2, plays 2–182; B: lead-in 182–184, plays 184–384.
        #expect(layout.items.map(\.timelineStart) == [2, 184, 386])
    }

    @Test func reorderedPlaylistCountsShowCodeThroughLeadIns() throws {
        let layout = TimelineLayout(ordered: [c, a], rate: .fps30, gap: 2)
        #expect(layout.items.map(\.song.name) == ["C", "A"])
        // C's lead-in counts up to 03:00:00:00.
        #expect(try #require(layout.showSeconds(at: 0)) == 3 * 3600 - 2)
        #expect(try #require(layout.showSeconds(at: 2)) == 3 * 3600)
        // Just after C ends, A's lead-in counts toward 01:00:00:00.
        let aLeadIn = 2 + TimelineLayout.openEndedDuration + 0.5
        #expect(try #require(layout.showSeconds(at: aLeadIn)) == 3600 - 1.5)
        #expect(layout.index(at: aLeadIn) == 1)
        #expect(layout.index(at: layout.totalDuration) == nil)
    }

    @Test func songNavigation() {
        let layout = TimelineLayout(ordered: [a, b], rate: .fps30, gap: 2)
        #expect(layout.nextSongStart(after: 10) == 184)
        #expect(layout.nextSongStart(after: 190) == nil)
        #expect(layout.previousSongStart(before: 184.5) == 2)
        #expect(layout.previousSongStart(before: 190) == 184)
    }
}

struct TimelineTransportTests {
    private let layout = TimelineLayout(
        ordered: [Song(name: "C", start: Timecode("03:00:00:00")!, end: Timecode("03:00:10:00")!),
                  Song(name: "A", start: Timecode("01:00:00:00")!, end: Timecode("01:00:10:00")!)],
        rate: .fps30, gap: 2)

    @Test func feedsRollingCodeAndFlagsReorderJumpOnce() throws {
        var transport = TimelineTransport()
        transport.seek(to: 11, at: 0)
        transport.play(at: 0)
        let first = transport.snapshot(at: 0, layout: layout)
        #expect(first.rolling)
        #expect(!first.jumped)
        // 0.5 s later, still in C.
        let steady = transport.snapshot(at: 0.5, layout: layout)
        #expect(!steady.jumped)
        #expect(abs((steady.position ?? 0) - (first.position ?? 0) - 15) < 0.001)
        // Past C's end (t = 12) into A's lead-in: show code jumps back two hours.
        let crossed = transport.snapshot(at: 1.5, layout: layout)
        #expect(crossed.jumped)
        #expect(!transport.snapshot(at: 1.6, layout: layout).jumped)
    }

    @Test func seekWhilePlayingIsAJumpAndPauseStopsRolling() {
        var transport = TimelineTransport()
        transport.play(at: 0)
        _ = transport.snapshot(at: 0.1, layout: layout)
        transport.seek(to: 6, at: 0.2)
        #expect(transport.snapshot(at: 0.2, layout: layout).jumped)
        transport.pause(at: 0.5)
        #expect(abs(transport.position(at: 9) - 6.3) < 1e-9)
        #expect(!transport.snapshot(at: 9, layout: layout).rolling)
    }
}

struct LTCGeneratorTests {
    @Test func streamedLTCDecodesAndFollowsAJump() {
        let sampleRate = 48_000.0
        var generator = LTCGenerator(rate: .fps30, sampleRate: sampleRate)
        let start = Double(Timecode("01:00:00:00")!.frameIndex(at: .fps30))
        let jumpTo = Double(Timecode("05:00:00:00")!.frameIndex(at: .fps30))
        let block = 512
        var samples = [Float](repeating: 0, count: block)
        var decoded: [Timecode] = []
        let decoder = LTCDecoder(sampleRate: sampleRate)
        var position = start
        for n in 0..<(Int(sampleRate * 2) / block) {
            if n == Int(sampleRate) / block { position = jumpTo }   // jump after ~1 s
            samples.withUnsafeMutableBufferPointer { generator.render(into: $0.baseAddress!, count: block, framePosition: position) }
            samples.withUnsafeBufferPointer { buf in
                decoder.process(buf.baseAddress!, count: block) { decoded.append($0.timecode) }
            }
            position += Double(block) * 30 / sampleRate
        }
        #expect(decoded.contains(Timecode("01:00:00:10")!))
        #expect(decoded.contains(Timecode("05:00:00:10")!))
        // Consecutive frames before the jump.
        let early = decoded.filter { $0.hours == 1 }.map { $0.frameIndex(at: .fps30) }
        #expect(early.count > 20)
        #expect(zip(early, early.dropFirst()).allSatisfy { $1 - $0 == 1 })
    }

    @Test func stoppedIsSilence() {
        var generator = LTCGenerator(rate: .fps30, sampleRate: 48_000)
        var samples = [Float](repeating: 1, count: 64)
        samples.withUnsafeMutableBufferPointer { generator.render(into: $0.baseAddress!, count: 64, framePosition: nil) }
        #expect(samples.allSatisfy { $0 == 0 })
    }
}

struct SongLibraryTests {
    private func song(_ name: String, _ tc: String, inSet: Bool = true) -> Song {
        Song(name: name, start: Timecode(tc)!, duration: 200, inSet: inSet)
    }

    @Test func alphabeticalImportFillsTheLibraryNotTheSet() {
        let imported = [song("Bearwalk", "01:30:00:00"), song("Cold Love", "01:50:00:00"), song("All's Well", "01:00:00:00")]
            .sorted { $0.name < $1.name }
        let merged = SongLibrary.merge(imported, into: [], rate: .fps30)
        #expect(merged.allSatisfy { !$0.inSet })
        // Library in timecode order.
        #expect(merged.map(\.name) == ["All's Well", "Bearwalk", "Cold Love"])
    }

    @Test func runningOrderImportIsTheSet() {
        let imported = [song("Cold Love", "01:50:00:00"), song("All's Well", "01:00:00:00"), song("Bearwalk", "01:30:00:00")]
        let merged = SongLibrary.merge(imported, into: [], rate: .fps30)
        #expect(merged.allSatisfy { $0.inSet })
        #expect(merged.map(\.name) == ["Cold Love", "All's Well", "Bearwalk"])
    }

    @Test func reimportKeepsTheSetItsOrderAndAudio() {
        var opener = song("Opener", "01:00:00:00")
        opener.audioPath = "/audio/opener.wav"
        opener.audioDuration = 210
        let previous = [song("Closer", "03:00:00:00"), opener, song("Middle", "02:00:00:00", inSet: false)]
        let imported = [song("Closer", "03:00:00:01"), song("Middle", "02:00:00:00"), song("New", "04:00:00:00"),
                        song("Opener", "01:00:00:00")]
        let merged = SongLibrary.merge(imported, into: previous, rate: .fps30)
        #expect(merged.filter(\.inSet).map(\.name) == ["Closer", "Opener"])
        #expect(merged.first { $0.name == "Opener" }?.audioPath == "/audio/opener.wav")
        #expect(merged.first { $0.name == "Closer" }?.start == Timecode("03:00:00:01"))
        #expect(merged.filter { !$0.inSet }.map(\.name) == ["Middle", "New"])
    }

    @Test func aDifferentShowStartsFresh() {
        let previous = [song("Old Opener", "01:00:00:00"), song("Old Closer", "02:00:00:00")]
        let imported = [song("New A", "05:00:00:00"), song("New B", "06:00:00:00")]
        let merged = SongLibrary.merge(imported, into: previous, rate: .fps30)
        // Two songs isn't an alphabetical library, so it's the running order: all on the set.
        #expect(merged.filter { $0.inSet }.map(\.name) == ["New A", "New B"])
    }

    @Test func layoutUsesOnlyTheSetButTheWholeLibraryForLengths() {
        // A set song with no end or duration runs to the next song in the library, not the set.
        let a = Song(name: "A", start: Timecode("01:00:00:00")!)
        let b = Song(name: "B", start: Timecode("01:04:00:00")!, inSet: false)
        let c = Song(name: "C", start: Timecode("02:00:00:00")!, duration: 100)
        let songs = SongLibrary.arranged([a, b, c], rate: .fps30)
        let layout = TimelineLayout(ordered: songs.filter(\.inSet), rate: .fps30, gap: 2, library: songs)
        #expect(layout.items.map(\.song.name) == ["A", "C"])
        #expect(layout.items.first?.duration == 240)
    }

    @Test func oldSavedSongsLoadIntoTheSet() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old","start":{"hours":1,"minutes":0,"seconds":0,"frames":0}}"#
        let song = try JSONDecoder().decode(Song.self, from: Data(json.utf8))
        #expect(song.inSet)
        #expect(song.name == "Old")
    }
}

struct ShowCodeSourceTests {
    @Test func defaultsToTheLTCInputAndSurvivesASaveRoundTrip() throws {
        #expect(AppSettings().showCodeSource == .input)
        var settings = AppSettings()
        settings.showCodeSource = .timeline
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.showCodeSource == .timeline)
        // Settings saved before this option existed load with the LTC input.
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(old.showCodeSource == .input)
    }
}

struct SetlistTests {
    private func song(_ name: String, _ tc: String) -> Song {
        Song(name: name, start: Timecode(tc)!, duration: 200, inSet: false)
    }

    @Test func applyingASetlistPutsItsSongsOnTheSetInOrder() {
        let songs = [song("A", "01:00:00:00"), song("B", "02:00:00:00"), song("C", "03:00:00:00")]
        let result = SongLibrary.applying(Setlist(name: "Night 1", songs: ["C", "Missing", "A"]), to: songs, rate: .fps30)
        #expect(result.filter { $0.inSet }.map(\.name) == ["C", "A"])
        #expect(result.filter { !$0.inSet }.map(\.name) == ["B"])
    }

    /// A take recorded C first (deck 0–200 s), then A (deck 230–430 s), and only 4 s of B.
    @Test func runningOrderComesFromWhereEachSongLandedInTheTake() {
        let a = song("A", "01:00:00:00"), b = song("B", "02:00:00:00"), c = song("C", "03:00:00:00")
        let sec = { (s: Song) in s.start.seconds(at: .fps30) }
        let map = TakeMap(segments: [
            .init(ltcStart: sec(c) - 2, ltcEnd: sec(c) + 200, offset: 2 - sec(c)),     // deck 0 → 202
            .init(ltcStart: sec(a), ltcEnd: sec(a) + 200, offset: 230 - sec(a)),       // deck 230 → 430
            .init(ltcStart: sec(b), ltcEnd: sec(b) + 4, offset: 440 - sec(b)),         // a false start
        ])
        let placed = RunningOrder.placed(songs: [a, b, c].map { ($0.id, sec($0), 200) }, in: map)
        #expect(placed.map(\.id) == [c.id, a.id])
        #expect(abs(placed[0].takeTime - 2) < 1e-6)
        #expect(abs(placed[1].takeTime - 230) < 1e-6)
    }
}
