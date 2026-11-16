import Foundation

// MARK: - Markers

/// A marker's type, by id (what each marker stores). The seven built-in ids are the original
/// fixed types, so markers saved before types were editable keep theirs.
public struct MarkerKind: RawRepresentable, Hashable, Codable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ id: String) { rawValue = id }

    public static let choreo = MarkerKind("choreo")
    public static let audio = MarkerKind("audio")
    public static let video = MarkerKind("video")
    public static let notes = MarkerKind("notes")
    public static let lighting = MarkerKind("lighting")
    public static let pyro = MarkerKind("pyro")
    public static let automation = MarkerKind("automation")
}

/// A marker type: its name and colour. Its place in the list gives its key (1–9).
public struct MarkerType: Codable, Identifiable, Equatable, Sendable {
    public var id: MarkerKind
    public var name: String
    /// "#RRGGBB".
    public var color: String

    public init(id: MarkerKind, name: String, color: String) {
        self.id = id
        self.name = name
        self.color = color
    }
}

/// The project's marker types, in order. Starts as CuePoints' seven; add, rename, recolour,
/// reorder and remove freely.
public struct MarkerTypes: Codable, Equatable, Sendable {
    public var types: [MarkerType]

    public static let maxTypes = 24
    /// Types with a number key (1–9).
    public static let keyed = 9

    public static let defaults = MarkerTypes(types: [
        MarkerType(id: .choreo, name: "Choreo", color: "#F27354"),
        MarkerType(id: .audio, name: "Audio", color: "#54ADEB"),
        MarkerType(id: .video, name: "Video", color: "#9473F2"),
        MarkerType(id: .notes, name: "Notes", color: "#668FFA"),
        MarkerType(id: .lighting, name: "Lighting", color: "#F24D5C"),
        MarkerType(id: .pyro, name: "Pyro", color: "#5CCC73"),
        MarkerType(id: .automation, name: "Automation", color: "#DB66DB"),
    ])

    public init(types: [MarkerType]) { self.types = types }

    public func type(_ kind: MarkerKind) -> MarkerType {
        types.first { $0.id == kind }
            ?? MarkerType(id: kind, name: kind.rawValue.prefix(1).uppercased() + kind.rawValue.dropFirst(), color: "#9A9A9A")
    }

    public func name(_ kind: MarkerKind) -> String { type(kind).name }

    /// Its key (1–9), if it has one.
    public func number(_ kind: MarkerKind) -> Int? {
        guard let i = types.firstIndex(where: { $0.id == kind }), i < Self.keyed else { return nil }
        return i + 1
    }

    /// From an OSC or text argument: a number (its key), its name, or its id; a few common
    /// abbreviations match the built-in types when they're in the list.
    public func kind(forArgument argument: String) -> MarkerKind? {
        let a = argument.trimmingCharacters(in: .whitespaces).lowercased()
        guard !a.isEmpty else { return nil }
        if let n = Int(a) { return types.indices.contains(n - 1) ? types[n - 1].id : nil }
        if let t = types.first(where: { $0.name.lowercased() == a || $0.id.rawValue == a }) { return t.id }
        let aliases: [String: MarkerKind] = ["lx": .lighting, "light": .lighting, "lights": .lighting,
                                             "vx": .video, "vid": .video, "sfx": .audio, "sound": .audio,
                                             "note": .notes, "auto": .automation, "chor": .choreo,
                                             "choreography": .choreo, "fx": .pyro]
        if let k = aliases[a], types.contains(where: { $0.id == k }) { return k }
        return nil
    }

    /// Adds a type with a fresh id; returns it.
    @discardableResult
    public mutating func add(name: String, color: String) -> MarkerKind {
        let base = name.lowercased().filter { $0.isLetter || $0.isNumber }
        var id = base.isEmpty ? "type" : base
        var n = 2
        while types.contains(where: { $0.id.rawValue == id }) { id = (base.isEmpty ? "type" : base) + "\(n)"; n += 1 }
        types.append(MarkerType(id: MarkerKind(id), name: name, color: color))
        return MarkerKind(id)
    }

    /// Colours offered for a new type, in turn.
    public static let palette = ["#F27354", "#54ADEB", "#9473F2", "#668FFA", "#F24D5C", "#5CCC73", "#DB66DB",
                                 "#F2B544", "#4DD9C9", "#B3B3B3", "#F28CB8", "#8CC63F"]
}

/// A point in the show worth finding again, placed on show timecode so it stays with its song
/// whatever order the set is in.
public struct Marker: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Show-code frame index at the show rate (LTC frames).
    public var frame: Int
    public var kind: MarkerKind
    public var label: String

    public init(id: UUID = UUID(), frame: Int, kind: MarkerKind, label: String = "") {
        self.id = id
        self.frame = frame
        self.kind = kind
        self.label = label
    }

    public func timecode(rate: FrameRate) -> Timecode { Timecode(frameIndex: frame, rate: rate.ltcRate) }
    /// Seconds of show code (real time, frame / exact rate).
    public func seconds(rate: FrameRate) -> Double { Double(frame) / rate.ltcRate.exact }
    /// The label, or the type's name when there's no label.
    public func displayName(in types: MarkerTypes) -> String { label.isEmpty ? types.name(kind) : label }
}

extension TimelineLayout {
    /// Timeline time of show second `show`, inside the first set song (or its lead-in) that covers it.
    public func timelineTime(forShowSeconds show: Double) -> Double? {
        for item in items {
            let leadIn = item.timelineStart - gap
            let t = item.timelineStart + (show - item.showStart)
            if t >= max(0, leadIn) - 1e-9, t < item.timelineEnd { return t }
        }
        return nil
    }

    /// Markers on the set, in timeline order, with their timeline time.
    public func placed(_ markers: [Marker]) -> [(marker: Marker, time: Double)] {
        markers.compactMap { m in timelineTime(forShowSeconds: m.seconds(rate: rate)).map { (m, $0) } }
            .sorted { $0.time < $1.time }
    }
}

// MARK: - Export

public enum MarkerExport {
    /// Spreadsheet-friendly: Timecode, Type, Label, Song, Seconds. One row per marker, in time order.
    public static func csv(_ markers: [Marker], rate: FrameRate, songs: [Song] = [], types: MarkerTypes = .defaults) -> String {
        func esc(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var lines = ["Timecode,Type,Label,Song,Seconds"]
        for m in markers.sorted(by: { $0.frame < $1.frame }) {
            let song = songName(for: m, rate: rate, songs: songs) ?? ""
            lines.append([m.timecode(rate: rate).display(dropFrame: rate.isDropFrame), esc(types.name(m.kind)), esc(m.label), esc(song),
                          String(format: "%.3f", m.seconds(rate: rate))].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The song whose show code contains the marker (by start and length).
    public static func songName(for m: Marker, rate: FrameRate, songs: [Song]) -> String? {
        let s = m.seconds(rate: rate)
        return songs.first { song in
            let start = Double(song.start.frameIndex(at: rate.ltcRate)) / rate.ltcRate.exact
            let length = song.duration ?? song.audioDuration ?? 0
            return s >= start && s < start + max(length, 1)
        }?.name
    }
}

// MARK: - grandMA3

/// Builds the markers in grandMA3 over OSC command lines: a sequence with one cue per marker, and
/// a timecode show whose events Goto those cues at the marker times (so MA3 fires them from LTC).
///
/// The timecode events can't be made from the command line, so they're made in Lua (the `Lua`
/// keyword) with the same object calls MA3 plugins use: TrackGroup → Track (target the sequence)
/// → TimeRange → CmdSubTrack → CmdEvent (RawTime = seconds × 2^24, Token, CueDestination). A new
/// TrackGroup, Track and TimeRange only appear on a later frame, so each structural step is its own
/// message with a pause after it.
public enum MA3Deploy {
    public struct Step: Equatable, Sendable {
        /// Command line text for `/cmd`.
        public var command: String
        /// Wait this long after sending, for MA3 to create what it made.
        public var pause: Double
    }

    public static let rawPerSecond = 16_777_216.0

    public static func rawTime(_ seconds: Double) -> Int { Int((seconds * rawPerSecond).rounded()) }

    /// Quotes a label for the command line (MA3 has no escape for a double quote: use single).
    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ") + "\""
    }

    /// A label safe inside Lua single quotes inside a command-line double-quoted string.
    static func luaText(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\n", with: " ")
    }

    /// The cue name for a marker: "01:00:24:16 Choreo – Verse 2".
    public static func cueName(_ m: Marker, rate: FrameRate, types: MarkerTypes = .defaults) -> String {
        let tc = m.timecode(rate: rate).display(dropFrame: rate.isDropFrame)
        let kind = types.name(m.kind)
        return m.label.isEmpty ? "\(tc) \(kind)" : "\(tc) \(kind) – \(m.label)"
    }

    /// Every message, in order. Replaces sequence `sequence` and timecode show `timecode`.
    public static func steps(_ markers: [Marker], rate: FrameRate, sequence: Int, timecode: Int,
                             name: String, types: MarkerTypes = .defaults, batch: Int = 25) -> [Step] {
        let sorted = markers.sorted { $0.frame < $1.frame }
        var out: [Step] = []
        func cmd(_ c: String, _ pause: Double = 0.05) { out.append(Step(command: c, pause: pause)) }
        // Sequence: one empty cue per marker, named.
        cmd("Delete Sequence \(sequence) /NoConfirmation", 0.2)
        cmd("Store Sequence \(sequence) /NoConfirmation", 0.2)
        cmd("Label Sequence \(sequence) \(quoted(name))")
        for (i, m) in sorted.enumerated() {
            cmd("Store Sequence \(sequence) Cue \(i + 1) /NoConfirmation")
            cmd("Label Sequence \(sequence) Cue \(i + 1) \(quoted(cueName(m, rate: rate, types: types)))")
        }
        // Timecode show: one track on the sequence, one Goto event per marker.
        cmd("Delete Timecode \(timecode) /NoConfirmation", 0.2)
        cmd("Store Timecode \(timecode) /NoConfirmation", 0.3)
        cmd("Label Timecode \(timecode) \(quoted(name))", 0.2)
        let find = "local function nth(o,c,n) local k=0 for _,x in ipairs(o:Children()) do if x:GetClass()==c then k=k+1 if k==n then return x end end end end "
            + "local tc=ObjectList('Timecode \(timecode)')[1] "
        cmd("Lua \"\(find)tc:Append('TrackGroup')\"", 0.5)
        cmd("Lua \"\(find)local g=nth(tc,'TrackGroup',1) local t=nth(g,'Track',1) or g:Append('Track') t:Set('Target',ObjectList('Sequence \(sequence)')[1])\"", 0.5)
        // Events in batches, each its own command line.
        let base = "\(find)local g=nth(tc,'TrackGroup',1) local t=nth(g,'Track',1) local r=nth(t,'TimeRange',1) "
            + "local st=nth(r,'CmdSubTrack',1) or r:Append('CmdSubTrack') "
            + "local function ev(raw,cue) local e=st:Append('CmdEvent') e:Set('RawTime',raw) e:Set('Token','Goto') e:Set('CueDestination',ObjectList('Sequence \(sequence) Cue '..cue)[1]) end "
        var i = 0
        while i < sorted.count {
            let chunk = sorted[i..<min(i + batch, sorted.count)]
            let calls = chunk.enumerated().map { j, m in "ev(\(rawTime(m.seconds(rate: rate))),\(i + j + 1))" }.joined(separator: " ")
            cmd("Lua \"\(base)\(calls)\"", 0.3)
            i += batch
        }
        return out
    }

    /// The same build as a grandMA3 plugin (import it in the Plugins pool, then run it), for a
    /// console that isn't on the network.
    public static func pluginLua(_ markers: [Marker], rate: FrameRate, sequence: Int, timecode: Int, name: String,
                                 types: MarkerTypes = .defaults) -> String {
        let sorted = markers.sorted { $0.frame < $1.frame }
        var lua = """
        -- Understudy markers: \(sorted.count) as Sequence \(sequence) (one cue each) and Timecode \(timecode) (Goto events).
        -- Replaces Sequence \(sequence) and Timecode \(timecode).
        local markers = {

        """
        for m in sorted {
            lua += "  {raw=\(rawTime(m.seconds(rate: rate))), name='\(luaText(cueName(m, rate: rate, types: types)))'},\n"
        }
        lua += """
        }
        local function nth(o,c,n) local k=0 for _,x in ipairs(o:Children()) do if x:GetClass()==c then k=k+1 if k==n then return x end end end end
        local function waitFor(f) for _=1,50 do local v=f() if v then return v end coroutine.yield(0.05) end end
        return function()
          Cmd('Delete Sequence \(sequence) /NoConfirmation')
          Cmd('Store Sequence \(sequence) /NoConfirmation')
          Cmd('Label Sequence \(sequence) "\(luaText(name))"')
          for i,m in ipairs(markers) do
            Cmd('Store Sequence \(sequence) Cue '..i..' /NoConfirmation')
            Cmd('Label Sequence \(sequence) Cue '..i..' "'..m.name..'"')
          end
          Cmd('Delete Timecode \(timecode) /NoConfirmation')
          Cmd('Store Timecode \(timecode) /NoConfirmation')
          Cmd('Label Timecode \(timecode) "\(luaText(name))"')
          local tc = ObjectList('Timecode \(timecode)')[1]
          tc:Append('TrackGroup')
          local g = waitFor(function() return nth(tc,'TrackGroup',1) end)
          local t = waitFor(function() return nth(g,'Track',1) end) or g:Append('Track')
          t:Set('Target', ObjectList('Sequence \(sequence)')[1])
          local r = waitFor(function() return nth(t,'TimeRange',1) end)
          local st = nth(r,'CmdSubTrack',1) or r:Append('CmdSubTrack')
          for i,m in ipairs(markers) do
            local e = st:Append('CmdEvent')
            e:Set('RawTime', m.raw)
            e:Set('Token', 'Goto')
            e:Set('CueDestination', ObjectList('Sequence \(sequence) Cue '..i)[1])
          end
          Printf('Understudy: %d markers in Sequence \(sequence) and Timecode \(timecode)', #markers)
        end

        """
        return lua
    }

    /// The plugin's XML wrapper, referencing `luaFile`.
    public static func pluginXML(name: String, luaFile: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <GMA3 DataVersion="2.0.0.0">
          <Plugin Name="\(xmlEscape(name))" Version="1.0.0.0">
            <ComponentLua Name="\(xmlEscape(name))" FileName="\(xmlEscape(luaFile))"/>
          </Plugin>
        </GMA3>

        """
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - disguise

/// Writes markers onto a disguise track as notes (and optionally sections or CUE tags), by
/// running Python in the Designer session (`POST /api/session/python/execute`).
///
/// Times are placed through the track's own TC tags when it has them (a song's TC tag maps show
/// code to the track), else from the track start at `trackStartSeconds` of show code.
public enum D3Push {
    public enum Style: String, Codable, CaseIterable, Sendable {
        case notes, sectionsAndNotes, cueTags
        public var title: String {
            switch self {
            case .notes: return "Notes"
            case .sectionsAndNotes: return "Sections + notes"
            case .cueTags: return "CUE tags + notes"
            }
        }
    }

    static func py(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ") + "'"
    }

    /// Python 2.7 for the execute endpoint (run inside Designer's `runner` function, so `return`
    /// gives the result). Returns {track, placed, skipped, tcTags}.
    public static func script(_ markers: [Marker], rate: FrameRate, trackName: String?, style: Style,
                              trackStartSeconds: Double, types: MarkerTypes = .defaults) -> String {
        let rows = markers.sorted { $0.frame < $1.frame }.map { m in
            "(\(String(format: "%.6f", m.seconds(rate: rate))), \(py(types.name(m.kind))), \(py(m.label)))"
        }.joined(separator: ", ")
        // Track lookup that works across Designer versions (setlist attribute names have moved).
        let pick = """
        track = None
        wanted = \(trackName.map(py) ?? "None")
        if wanted:
            for holder in [guisystem, getattr(guisystem, 'currentSetList', None), getattr(guisystem, 'transport', None)]:
                lists = []
                if holder is not None:
                    for attr in ['tracks', 'setList', 'currentSetList']:
                        v = getattr(holder, attr, None)
                        if v is not None:
                            lists.append(getattr(v, 'tracks', v))
                for l in lists:
                    try:
                        for t in l:
                            if getattr(t, 'name', None) == wanted:
                                track = t
                    except TypeError:
                        pass
        if track is None:
            track = guisystem.track
        """
        return """
        import re
        markers = [\(rows)]
        \(pick)
        # TC tags map show code to track time: [(tag seconds of timecode, track seconds)].
        anchors = []
        for b in track.cueBeats():
            for tag in track.tagsAtBeat(b):
                if int(tag.type) == 0:
                    m = re.search(r'(\\d+):(\\d+):(\\d+)[:;.](\\d+)', tag.text)
                    if m:
                        h, mi, s, f = [int(x) for x in m.groups()]
                        anchors.append((h * 3600 + mi * 60 + s + f / \(String(format: "%.6f", rate.ltcRate.exact)), track.beatToTime(b)))
        anchors.sort()
        placed = 0
        skipped = []
        number = 0
        for (sec, kind, label) in markers:
            base = None
            for (tcSec, trackSec) in anchors:
                if tcSec <= sec + 1e-6:
                    base = (tcSec, trackSec)
            if base is None:
                t = sec - \(String(format: "%.6f", trackStartSeconds))
            else:
                t = base[1] + (sec - base[0])
            if t < 0 or t > track.lengthInSec:
                skipped.append(label or kind)
                continue
            beat = track.timeToBeat(t)
            text = kind + (': ' + label if label else '')
            number += 1
            track.setNoteAtBeat(beat, text)
            \(style == .cueTags ? "track.setTagAtBeat(beat, Tag(TagType.CUE, str(number)))" : "")
            \(style == .sectionsAndNotes ? "if not track.sectionAtBeat(beat): track.splitSectionAtBeat(beat)" : "")
            placed += 1
        return {'track': str(track.name), 'placed': placed, 'skipped': skipped, 'tcTags': len(anchors)}
        """
    }

    /// JSON body for the execute endpoint.
    public static func body(script: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["script": script])) ?? Data()
    }
}
