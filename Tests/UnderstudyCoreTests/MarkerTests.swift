import Foundation
import Testing
@testable import UnderstudyCore

@Suite("Markers")
struct MarkerTests {
    let rate = FrameRate.fps30
    func frame(_ tc: String) -> Int { Timecode(tc)!.frameIndex(at: .fps30) }

    @Test func defaultTypesHaveKeysAndAliases() {
        let t = MarkerTypes.defaults
        #expect(t.number(.choreo) == 1 && t.number(.automation) == 7)
        #expect(t.kind(forArgument: "5") == .lighting)
        #expect(t.kind(forArgument: "LX") == .lighting)
        #expect(t.kind(forArgument: "Pyro") == .pyro)
        #expect(t.kind(forArgument: "8") == nil && t.kind(forArgument: "banana") == nil)
    }

    /// Custom types: added, renamed, recoloured, reordered; their names reach every export.
    @Test func customTypes() throws {
        var t = MarkerTypes.defaults
        let cam = t.add(name: "Camera Move", color: "#F2B544")
        let cam2 = t.add(name: "Camera Move", color: "#000000")
        #expect(cam.rawValue == "cameramove" && cam2.rawValue == "cameramove2")
        t.types.removeAll { $0.id == .audio }
        let moved = t.types.remove(at: t.types.count - 2)   // Camera Move to the top
        t.types.insert(moved, at: 0)
        #expect(t.number(cam) == 1 && t.number(.choreo) == 2)
        #expect(t.kind(forArgument: "1") == cam && t.kind(forArgument: "camera move") == cam && t.kind(forArgument: "cameramove") == cam)
        #expect(t.kind(forArgument: "sfx") == nil)          // alias for a type that's gone
        // A type removed from the list still reads, by its id.
        #expect(t.name(.audio) == "Audio" && t.type(.audio).color == "#9A9A9A")
        let m = Marker(frame: frame("01:00:24:16"), kind: cam, label: "")
        #expect(m.displayName(in: t) == "Camera Move")
        #expect(MarkerExport.csv([m], rate: rate, types: t).contains("01:00:24:16,Camera Move,,"))
        #expect(MA3Deploy.cueName(m, rate: rate, types: t) == "01:00:24:16 Camera Move")
        #expect(D3Push.script([m], rate: rate, trackName: nil, style: .notes, trackStartSeconds: 0, types: t).contains("'Camera Move'"))
        #expect(RemoteControl.command(for: OSCMessage("/understudy/marker/1"), types: t) == .addMarker(cam, label: ""))
        #expect(RemoteControl.command(for: OSCMessage("/understudy/marker", [.string("Camera Move"), .string("Push in")]), types: t)
                == .addMarker(cam, label: "Push in"))
        // Types travel with the project; old files get the defaults; markers keep their ids.
        var show = ShowContent()
        show.markerTypes = t
        show.markers = [m]
        let back = try JSONDecoder().decode(ShowContent.self, from: JSONEncoder().encode(show))
        #expect(back.markerTypes == t && back.markers?.first?.kind == cam)
        let old = try JSONDecoder().decode(Marker.self, from: Data(#"{"id":"6B0C1D2E-3F40-4A5B-8C6D-7E8F90A1B2C3","frame":5,"kind":"pyro","label":""}"#.utf8))
        #expect(old.kind == .pyro)
        #expect(String(data: try JSONEncoder().encode(old.kind), encoding: .utf8) == "\"pyro\"")
    }

    /// Markers sit on show code, so they follow their song whatever the set order.
    @Test func placedFollowTheirSongInAnyOrder() {
        let a = Song(name: "A", start: Timecode("01:00:00:00")!, duration: 200)
        let b = Song(name: "B", start: Timecode("02:00:00:00")!, duration: 100)
        let mA = Marker(frame: frame("01:00:24:16"), kind: .choreo, label: "Verse")
        let mB = Marker(frame: frame("02:00:10:00"), kind: .pyro)
        let off = Marker(frame: frame("05:00:00:00"), kind: .notes)   // not on the set
        let ab = TimelineLayout(ordered: [a, b], rate: rate, gap: 2)
        let ba = TimelineLayout(ordered: [b, a], rate: rate, gap: 2)
        let placedAB = ab.placed([mB, mA, off])
        #expect(placedAB.map(\.marker.id) == [mA.id, mB.id])
        #expect(abs(placedAB[0].time - (2 + 24 + 16.0 / 30)) < 1e-6)
        let placedBA = ba.placed([mA, mB, off])
        #expect(placedBA.map(\.marker.id) == [mB.id, mA.id])
        #expect(abs(placedBA[0].time - 12) < 1e-6)
        #expect(abs(placedBA[1].time - (2 + 100 + 2 + 24 + 16.0 / 30)) < 1e-6)
    }

    @Test func csvExport() {
        let a = Song(name: "All's Well That Ends", start: Timecode("01:00:00:00")!, duration: 210)
        let csv = MarkerExport.csv([Marker(frame: frame("01:00:47:16"), kind: .lighting, label: "Chorus, big"),
                                    Marker(frame: frame("01:00:24:16"), kind: .choreo)], rate: rate, songs: [a])
        let lines = csv.split(separator: "\n")
        #expect(lines[0] == "Timecode,Type,Label,Song,Seconds")
        #expect(lines[1] == "01:00:24:16,Choreo,,All's Well That Ends,3624.533")
        #expect(lines[2] == "01:00:47:16,Lighting,\"Chorus, big\",All's Well That Ends,3647.533")
    }

    @Test func ma3StepsBuildSequenceAndTimecode() {
        let ms = [Marker(frame: frame("01:00:47:16"), kind: .lighting, label: "Drop \"big\""),
                  Marker(frame: frame("01:00:24:16"), kind: .choreo)]
        let steps = MA3Deploy.steps(ms, rate: rate, sequence: 201, timecode: 3, name: "RKS markers").map(\.command)
        #expect(steps.contains("Store Sequence 201 Cue 1 /NoConfirmation"))
        #expect(steps.contains("Label Sequence 201 Cue 1 \"01:00:24:16 Choreo\""))
        #expect(steps.contains("Label Sequence 201 Cue 2 \"01:00:47:16 Lighting – Drop 'big'\""))
        #expect(steps.contains("Store Timecode 3 /NoConfirmation"))
        // Every Lua line is a single double-quoted command with no inner double quotes.
        for s in steps where s.hasPrefix("Lua ") {
            #expect(s.hasPrefix("Lua \"") && s.hasSuffix("\""))
            #expect(s.dropFirst(5).dropLast().contains("\"") == false)
        }
        let events = steps.last!
        // 01:00:24:16 = 3624.5333 s → raw = s × 2^24.
        #expect(events.contains("ev(\(MA3Deploy.rawTime(3624 + 16.0 / 30)),1)"))
        #expect(events.contains("ev(\(MA3Deploy.rawTime(3647 + 16.0 / 30)),2)"))
        #expect(events.contains("e:Set('Token','Goto')"))
        // Large sets go in batches.
        let many = (0..<60).map { Marker(frame: 108_000 + $0 * 30, kind: .notes) }
        #expect(MA3Deploy.steps(many, rate: rate, sequence: 1, timecode: 1, name: "x", batch: 25).filter { $0.command.contains("ev(") }.count == 3)
        #expect(MA3Deploy.rawTime(1) == 16_777_216)
    }

    @Test func ma3PluginIsSelfContained() {
        let lua = MA3Deploy.pluginLua([Marker(frame: frame("01:00:24:16"), kind: .choreo, label: "It's on")], rate: rate,
                                      sequence: 201, timecode: 3, name: "RKS")
        #expect(lua.contains("{raw=\(MA3Deploy.rawTime(3624 + 16.0 / 30)), name='01:00:24:16 Choreo – It\\'s on'}"))
        #expect(lua.contains("return function()"))
        let xml = MA3Deploy.pluginXML(name: "Understudy markers", luaFile: "understudy_markers.lua")
        #expect(xml.contains("FileName=\"understudy_markers.lua\""))
    }

    @Test func d3ScriptPlacesThroughTCTags() {
        let script = D3Push.script([Marker(frame: frame("01:00:24:16"), kind: .choreo, label: "Verse 'two'")], rate: rate,
                                   trackName: "All's Well", style: .cueTags, trackStartSeconds: 3600)
        #expect(script.contains("markers = [(3624.533333, 'Choreo', 'Verse \\'two\\'')]"))
        #expect(script.contains("wanted = 'All\\'s Well'"))
        #expect(script.contains("track.setNoteAtBeat(beat, text)"))
        #expect(script.contains("track.setTagAtBeat(beat, Tag(TagType.CUE, str(number)))"))
        #expect(script.contains("t = sec - 3600.000000"))
        #expect(script.contains("return {'track': str(track.name)"))
        let notes = D3Push.script([], rate: rate, trackName: nil, style: .notes, trackStartSeconds: 0)
        #expect(notes.contains("wanted = None") && !notes.contains("setTagAtBeat") && !notes.contains("splitSectionAtBeat"))
        let body = try! JSONSerialization.jsonObject(with: D3Push.body(script: "return 1")) as! [String: String]
        #expect(body == ["script": "return 1"])
    }
}

@Suite("OSC")
struct OSCTests {
    @Test func roundTrip() {
        let m = OSCMessage("/understudy/marker", [.string("lighting"), .string("Drop"), .int(3), .float(0.5), .bool(true)])
        let data = m.encoded()
        #expect(data.count % 4 == 0)
        #expect(OSCMessage.decode(data) == [m])
    }

    /// Bytes as MA3 / Companion send them: "/cmd" ",s" "Go+ Exec 201".
    @Test func knownBytes() {
        let data = OSCMessage("/gma3/cmd", [.string("Go+ Exec 201")]).encoded()
        // Built step by step: one long `+` chain of literals is too slow for older compilers to type-check.
        var expected = [UInt8]("/gma3/cmd".utf8)
        expected += [0, 0, 0]
        expected += [UInt8](",s".utf8)
        expected += [0, 0]
        expected += [UInt8]("Go+ Exec 201".utf8)
        expected += [0, 0, 0, 0]
        #expect([UInt8](data) == expected)
    }

    @Test func bundles() {
        let a = OSCMessage("/understudy/play").encoded()
        let b = OSCMessage("/understudy/marker/3").encoded()
        var bundle = Data("#bundle".utf8)
        bundle.append(0)
        bundle.append(Data(count: 8))
        for part in [a, b] {
            withUnsafeBytes(of: UInt32(part.count).bigEndian) { bundle.append(contentsOf: $0) }
            bundle.append(part)
        }
        #expect(OSCMessage.decode(bundle).map(\.address) == ["/understudy/play", "/understudy/marker/3"])
    }

    @Test func commands() {
        func cmd(_ a: String, _ args: [OSCArgument] = []) -> RemoteCommand? { RemoteControl.command(for: OSCMessage(a, args)) }
        #expect(cmd("/understudy/play") == .play)
        #expect(cmd("/play") == .play)
        #expect(cmd("/understudy/play", [.int(1)]) == .play)
        #expect(cmd("/understudy/play", [.int(0)]) == nil)          // button release
        #expect(cmd("/understudy/toggle", [.float(1)]) == .togglePlay)
        #expect(cmd("/understudy/song", [.int(3)]) == .gotoSong(3))
        #expect(cmd("/understudy/song/next") == .nextSong)
        #expect(cmd("/understudy/marker") == .addMarker(nil, label: ""))
        #expect(cmd("/understudy/marker", [.int(1)]) == .addMarker(nil, label: ""))   // press value, not a type
        #expect(cmd("/understudy/marker", [.string("lx"), .string("Drop")]) == .addMarker(.lighting, label: "Drop"))
        #expect(cmd("/understudy/marker", [.string("Verse 2")]) == .addMarker(nil, label: "Verse 2"))
        #expect(cmd("/understudy/marker/pyro") == .addMarker(.pyro, label: ""))
        #expect(cmd("/understudy/marker/3", [.int(1)]) == .addMarker(.video, label: ""))
        #expect(cmd("/understudy/marker/next") == .nextMarker)
        #expect(cmd("/understudy/mode", [.string("Timeline")]) == .mode("timeline"))
        #expect(cmd("/understudy/mode/record") == .mode("record"))
        #expect(cmd("/understudy/banana") == nil)
    }
}
