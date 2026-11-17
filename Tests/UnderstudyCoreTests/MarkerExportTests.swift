import Foundation
import Testing
@testable import UnderstudyCore

@Suite("Marker export")
struct MarkerExportTests {
    let rate = FrameRate.fps30
    func frame(_ tc: String) -> Int { Timecode(tc)!.frameIndex(at: .fps30) }
    func secs(_ tc: String) -> Double { Double(frame(tc)) / 30 }

    // Two songs on the set; one marker that's on neither.
    let allsWell = Song(name: "ALL'S WELL THAT ENDS", start: Timecode("01:00:00:00")!, duration: 200)
    let bones = Song(name: "BONES", start: Timecode("11:00:00:00")!, duration: 150)
    var songs: [ExportSong] { ExportSong.set(TimelineLayout(ordered: [allsWell, bones], rate: rate, gap: 2)) }
    var markers: [Marker] {
        [Marker(frame: frame("11:00:20:00"), kind: .pyro, label: "Gerbs"),
         Marker(frame: frame("01:00:24:16"), kind: .choreo, label: "Verse"),
         Marker(frame: frame("01:00:47:16"), kind: .lighting, label: "Drop \"big\""),
         Marker(frame: frame("11:00:10:00"), kind: .choreo),
         Marker(frame: frame("05:00:00:00"), kind: .notes)]
    }

    @Test func markersSplitBySong() {
        let (buckets, outside) = MarkerBuckets.split(markers, songs: songs, rate: rate)
        #expect(outside == 1)
        #expect(buckets.map { $0.song?.name } == ["ALL'S WELL THAT ENDS", "BONES"])
        #expect(buckets.map(\.markers.count) == [2, 2])
        #expect(buckets[1].index == 1)
        // A marker in the lead-in belongs to the song after it.
        let leadIn = Marker(frame: frame("10:59:59:00"), kind: .notes)
        #expect(MarkerBuckets.split([leadIn], songs: songs, rate: rate).buckets.first?.song?.name == "BONES")
        // No set: one bucket, no song.
        let none = MarkerBuckets.split(markers, songs: [], rate: rate)
        #expect(none.buckets.count == 1 && none.buckets[0].song == nil && none.outside == 0)
    }

    /// The defaults build what Understudy always built: one sequence, one timecode show.
    @Test func defaultPlanIsOneSequenceAndOneShow() {
        let plan = MA3Plan.make(markers, songs: songs, rate: rate, types: .defaults, settings: MA3ExportSettings(),
                                sequenceStart: 1001, timecodeStart: 101, name: "Understudy · Summer")
        #expect(plan.sequences.count == 1)
        let q = plan.sequences[0]
        #expect(q.pool == 1001 && q.name == "Understudy · Summer" && q.exec == nil && q.pages.isEmpty)
        #expect(q.cues.map(\.name) == ["01:00:24:16 Choreo – Verse", "01:00:47:16 Lighting – Drop \"big\"",
                                       "11:00:10:00 Choreo", "11:00:20:00 Pyro – Gerbs"])
        #expect(plan.timecodes.count == 1 && plan.timecodes[0].number == 101)
        #expect(plan.timecodes[0].tracks.count == 1)
        #expect(plan.timecodes[0].tracks[0].events.first == MA3Plan.Event(raw: MA3Deploy.rawTime(3624 + 16.0 / 30), cue: 1))
        #expect(plan.pages.isEmpty)
        #expect(plan.markerCount == 4)
        #expect(plan.warnings.first?.contains("1 marker isn't on a song") == true)
        #expect(MA3Deploy.rawTime(1) == 16_777_216)
    }

    /// CuePoints-style: a sequence per song and type, a page per song, an exec per type, a timecode
    /// show per song, events a couple of frames early.
    @Test func perSongAndTypeOnPagesAndExecs() {
        var s = MA3ExportSettings()
        s.sequences = .perSongAndType
        s.songOffset = 20
        s.timecodes = .perSong
        s.pages = .perSong
        s.page = 3
        s.latencyFrames = 2
        s.types[MarkerKind.choreo.rawValue] = .init(exec: 201)
        s.types[MarkerKind.lighting.rawValue] = .init(exec: 205)
        s.songs[bones.id.uuidString] = .init(page: 10)
        let plan = MA3Plan.make(markers, songs: songs, rate: rate, types: .defaults, settings: s,
                                sequenceStart: 4225, timecodeStart: 15, name: "Set")
        // Pool: start + song × offset + the type's place in the list (choreo 0, lighting 4, pyro 5).
        #expect(plan.sequences.map(\.pool) == [4225, 4229, 4245, 4250])
        #expect(plan.sequences.map(\.name) == ["ALL'S WELL THAT ENDS · Choreo", "ALL'S WELL THAT ENDS · Lighting",
                                               "BONES · Choreo", "BONES · Pyro"])
        #expect(plan.sequences.map(\.exec) == [201, 205, 201, nil])
        #expect(plan.sequences.map(\.pages) == [[3], [3], [10], []])
        #expect(plan.pages == [MA3Plan.Page(number: 3, name: "ALL'S WELL THAT ENDS"), MA3Plan.Page(number: 10, name: "BONES")])
        #expect(plan.timecodes.map(\.number) == [15, 16])
        #expect(plan.timecodes.map(\.name) == ["ALL'S WELL THAT ENDS", "BONES"])
        #expect(plan.timecodes[0].tracks.map(\.sequence) == [0, 1])
        #expect(plan.timecodes[1].tracks.map(\.sequence) == [2, 3])
        // Two frames early.
        #expect(plan.timecodes[1].tracks[0].events == [MA3Plan.Event(raw: MA3Deploy.rawTime(secs("11:00:10:00") - 2.0 / 30), cue: 1)])
        #expect(plan.warnings == ["1 marker isn't on a song in the set: left out."])
    }

    @Test func typesAndSongsCanBeLeftOut() {
        var s = MA3ExportSettings()
        s.sequences = .perType
        s.types[MarkerKind.lighting.rawValue] = .init(include: false)
        s.songs[allsWell.id.uuidString] = .init(include: false)
        let plan = MA3Plan.make(markers, songs: songs, rate: rate, types: .defaults, settings: s,
                                sequenceStart: 100, timecodeStart: 1, name: "Set")
        #expect(plan.sequences.map(\.name) == ["Choreo", "Pyro"])
        #expect(plan.sequences.map(\.pool) == [100, 105])
        #expect(plan.markerCount == 2)
    }

    /// One sequence per type on a page per song: the same sequence goes on each song's page.
    @Test func perTypeSequenceOnEverySongPage() {
        var s = MA3ExportSettings()
        s.sequences = .perType
        s.pages = .perSong
        s.page = 1
        s.types[MarkerKind.choreo.rawValue] = .init(exec: 101)
        let plan = MA3Plan.make(markers, songs: songs, rate: rate, types: .defaults, settings: s,
                                sequenceStart: 1, timecodeStart: 1, name: "Set")
        let choreo = plan.sequences.first { $0.kind == .choreo }!
        #expect(choreo.pages == [1, 2] && choreo.exec == 101)
        #expect(plan.pages.map(\.number) == [1, 2])
    }

    @Test func executorSourceNeedsAPage() {
        var s = MA3ExportSettings()
        s.single = .init(exec: 201, source: .executor, write: .override)
        let plan = MA3Plan.make(markers, songs: songs, rate: rate, types: .defaults, settings: s,
                                sequenceStart: 1, timecodeStart: 1, name: "Set")
        #expect(plan.sequences[0].source == .pool && plan.sequences[0].exec == nil)
        #expect(plan.warnings.contains { $0.contains("needs a page and an executor") })
    }

    /// The Lua never deletes or reassigns what isn't Understudy's.
    @Test func ma3LuaIsNonDestructive() {
        var s = MA3ExportSettings()
        s.sequences = .perSongAndType
        s.timecodes = .perSong
        s.pages = .fixed
        s.page = 5
        s.types[MarkerKind.choreo.rawValue] = .init(exec: 201, source: .executor, write: .override)
        s.types[MarkerKind.lighting.rawValue] = .init(exec: 202)
        let plan = MA3Plan.make(markers, songs: songs, rate: rate, types: .defaults, settings: s,
                                sequenceStart: 4225, timecodeStart: 15, name: "Set")
        let steps = MA3Deploy.steps(plan).map(\.command)
        for c in steps {
            // One double-quoted Lua line with no inner double quotes.
            #expect(c.hasPrefix("Lua \"") && c.hasSuffix("\""))
            #expect(!c.dropFirst(5).dropLast().contains("\""))
        }
        let all = steps.joined(separator: "\n")
        // Pages only when missing; executors only when empty.
        #expect(all.contains("if not O('Page 5') then Cmd('Store Page 5 /NoConfirmation')"))
        #expect(all.contains("local c=seqAt(5,202) if c==nil then Cmd('Assign Sequence '..s..' At Page 5.202 /NoConfirmation')"))
        // The executor's own sequence for choreo, falling back to the pool number.
        #expect(all.contains("local x=seqAt(5,201) local s=x or 4225"))
        // Sequences: never deleted; a taken slot is left alone; override copies first.
        #expect(!all.contains("Delete Sequence '..s..' /") && !all.contains("Delete Sequence 4"))
        #expect(all.contains("was not made by Understudy, left alone"))
        #expect(all.contains("local b=free(math.max(s,4250)+1) Cmd('Copy Sequence '..s..' At Sequence '..b..' /NoConfirmation') local c=O('Sequence '..b) if c then"))
        // A backup is never taken for Understudy's own.
        #expect(all.contains("if not ok or nm:find('before Understudy',1,true) then return false end"))
        #expect(all.contains("c:Set('Note','Backup by Understudy')"))
        #expect(steps.filter { $0.contains("Delete Sequence '..s..' Cue 1 Thru") }.count == 2)   // the two choreo sequences
        // Cues only when missing.
        #expect(all.contains("if not O(p) then Cmd('Store '..p..' /NoConfirmation')"))
        #expect(all.contains("q(1,'01:00:47:16 Lighting – Drop big')"))
        // Timecode shows replaced only when Understudy's.
        #expect(all.contains("local t=O('Timecode 15') if t and not ours(t,'ALL\\'S WELL THAT ENDS') then"))
        #expect(all.contains("e:Set('Token','Goto')"))
        #expect(all.contains("ev(\(MA3Deploy.rawTime(3624 + 16.0 / 30)),1)"))
        // A merge-only plan has no delete of cues at all.
        s.types[MarkerKind.choreo.rawValue]?.write = .merge
        let merge = MA3Deploy.steps(MA3Plan.make(markers, songs: songs, rate: rate, types: .defaults, settings: s,
                                                 sequenceStart: 4225, timecodeStart: 15, name: "Set")).map(\.command)
        #expect(!merge.contains { $0.contains("Delete Sequence") || $0.contains("Copy Sequence") })
        // Each chunk carries only the helpers it uses.
        #expect(!steps[0].contains("local function track("))
    }

    @Test func ma3BatchesAndPlugin() {
        let many = (0..<60).map { Marker(frame: 108_000 + $0 * 30, kind: .notes) }
        let plan = MA3Plan.make(many, songs: [], rate: rate, types: .defaults, settings: MA3ExportSettings(),
                                sequenceStart: 1, timecodeStart: 1, name: "x")
        let steps = MA3Deploy.steps(plan, batch: 25)
        #expect(steps.filter { $0.command.contains("ev(") }.count == 3)
        #expect(steps.filter { $0.command.contains(" q(") }.count == 3)
        let lua = MA3Deploy.pluginLua(MA3Plan.make([Marker(frame: frame("01:00:24:16"), kind: .choreo, label: "It's on")], songs: [],
                                                   rate: rate, types: .defaults, settings: MA3ExportSettings(),
                                                   sequenceStart: 201, timecodeStart: 3, name: "RKS"))
        #expect(lua.contains("q(1,'01:00:24:16 Choreo – It\\'s on')"))
        #expect(lua.contains("return function()") && lua.contains("coroutine.yield(0.5)"))
        #expect(lua.contains("local function seqAt(p,e)"))
        let xml = MA3Deploy.pluginXML(name: "Understudy markers", luaFile: "understudy_markers.lua")
        #expect(xml.contains("FileName=\"understudy_markers.lua\""))
    }

    // MARK: disguise

    @Test func d3RowsGoOnTracksNamedAfterSongs() {
        var s = D3ExportSettings()
        s.types[MarkerKind.pyro.rawValue] = .section
        s.types[MarkerKind.lighting.rawValue] = .off
        s.songs[bones.id.uuidString] = .init(track: "BONES v2")
        let (rows, outside) = D3Row.rows(markers, songs: songs, rate: rate, types: .defaults, settings: s,
                                         singleTrack: nil, singleStart: 0)
        #expect(outside == 1)
        #expect(rows.map(\.track) == ["ALL'S WELL THAT ENDS", "BONES v2", "BONES v2"])
        #expect(rows.map(\.placement) == [.note, .note, .section])
        // Tracks without TC tags start at their song's first frame.
        #expect(rows.map(\.trackStart) == [3600, 39600, 39600])
        // A song can be left out; the old single style is the default placement.
        s.songs[allsWell.id.uuidString] = .init(include: false)
        let cue = D3Row.rows(markers, songs: songs, rate: rate, types: .defaults, settings: s, fallback: .cueTags,
                             singleTrack: nil, singleStart: 0).rows
        #expect(cue.map(\.placement) == [.cueTag, .section])
    }

    @Test func d3OneTrack() {
        var s = D3ExportSettings()
        s.target = .single
        let rows = D3Row.rows(markers, songs: songs, rate: rate, types: .defaults, settings: s,
                              singleTrack: "Main", singleStart: 3600).rows
        #expect(rows.count == 5 && rows.allSatisfy { $0.track == "Main" && $0.trackStart == 3600 })
    }

    @Test func d3ScriptPlacesPerTrackWithoutOverwriting() {
        let rows = [D3Row(seconds: secs("01:00:24:16"), kind: "Choreo", label: "Verse 'two'", placement: .cueTag,
                          track: "All's Well", trackStart: 3600),
                    D3Row(seconds: secs("11:00:10:00"), kind: "Pyro", label: "", placement: .section, track: nil, trackStart: 39600)]
        let script = D3Push.script(rows, rate: rate)
        #expect(script.contains("(3624.533333, 'Choreo', 'Verse \\'two\\'', 'cueTag', 'All\\'s Well', 3600.000000)"))
        #expect(script.contains("(39610.000000, 'Pyro', '', 'section', None, 39600.000000)"))
        #expect(script.contains("tr = find(wanted) if wanted else guisystem.track"))
        // Existing notes are kept; CUE tags only where there's none; sections only split.
        #expect(script.contains("if old and str(old) != text:"))
        #expect(script.contains("if not [x for x in track.tagsAtBeat(beat) if int(x.type) == int(TagType.CUE)]:"))
        #expect(script.contains("track.splitSectionAtBeat(beat)"))
        #expect(!script.contains("delete") && !script.contains("remove"))
        #expect(script.contains("return {'tracks': counts"))
        let body = try! JSONSerialization.jsonObject(with: D3Push.body(script: "return 1")) as! [String: String]
        #expect(body == ["script": "return 1"])
    }

    // MARK: Saved setup

    @Test func setupTravelsWithTheProjectAndOldFilesLoad() throws {
        var t = ShowTargets()
        t.ma3Host = "10.0.0.5"
        t.markerExport.ma3.sequences = .perSongAndType
        t.markerExport.ma3.types["choreo"] = .init(exec: 201, source: .executor, write: .override)
        t.markerExport.d3.types["pyro"] = .section
        let back = try JSONDecoder().decode(ShowTargets.self, from: JSONEncoder().encode(t))
        #expect(back == t)
        // A project from before the export setup keeps its addresses.
        let old = try JSONDecoder().decode(ShowTargets.self, from: Data(#"{"ma3Host":"10.0.0.9","ma3Port":8000,"ma3Prefix":"gma3","ma3Sequence":7,"ma3Timecode":8,"d3Host":"","d3Track":"","d3Style":"cueTags","d3TrackStart":"00:00:00:00"}"#.utf8))
        #expect(old.ma3Host == "10.0.0.9" && old.ma3Sequence == 7 && old.d3Style == .cueTags)
        #expect(old.markerExport == MarkerExportSetup())
        // Unknown or partial fields fall back rather than losing the rest.
        let partial = try JSONDecoder().decode(MA3ExportSettings.self, from: Data(#"{"sequences":"perType","types":{"choreo":{"exec":5}}}"#.utf8))
        #expect(partial.sequences == .perType && partial.target(.choreo) == .init(exec: 5) && partial.songOffset == 20)
        var settings = AppSettings()
        settings.markerExport.d3.target = .single
        let s2 = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(s2.markerExport.d3.target == .single)
    }
}
