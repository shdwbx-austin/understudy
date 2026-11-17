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

/// The project's marker types, in order. Starts with seven common ones; add, rename, recolour,
/// reorder and remove freely.
public struct MarkerTypes: Codable, Equatable, Sendable {
    public var types: [MarkerType]

    public static let maxTypes = 24
    /// Types with a number key (1–9).
    public static let keyed = 9

    public static let defaults = MarkerTypes(types: [
        // Understudy's own palette: clear of the status colours (lock green, warning amber,
        // alarm red), so a marker never reads as a deck state.
        MarkerType(id: .choreo, name: "Choreo", color: "#FF7A59"),      // coral
        MarkerType(id: .audio, name: "Audio", color: "#3DB8C4"),        // teal
        MarkerType(id: .video, name: "Video", color: "#8E7CF0"),        // violet
        MarkerType(id: .notes, name: "Notes", color: "#D9D4C7"),        // stone
        MarkerType(id: .lighting, name: "Lighting", color: "#F2C14E"),  // sodium yellow
        MarkerType(id: .pyro, name: "Pyro", color: "#FF4F81"),          // hot pink
        MarkerType(id: .automation, name: "Automation", color: "#7FB3FF"), // sky
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
    public static let palette = ["#FF7A59", "#3DB8C4", "#8E7CF0", "#D9D4C7", "#F2C14E", "#FF4F81", "#7FB3FF",
                                 "#C9A27E", "#5FD3B3", "#B58BD9", "#E8E36A", "#9AA7B8"]
}

/// A point in the show worth finding again, placed on show timecode so it stays with its song
/// whatever order the set is in.
public struct Marker: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Show-code frame index at the show rate (LTC frames).
    public var frame: Int
    public var kind: MarkerKind
    public var label: String
    /// Laid out on a beat grid with others ("every 1/4 from a marker"): they share this, so the
    /// whole run can be cleared at once. nil = placed by hand.
    public var arrayID: UUID?
    /// The run's step, for showing it ("1/4").
    public var arrayStep: String?

    public init(id: UUID = UUID(), frame: Int, kind: MarkerKind, label: String = "", arrayID: UUID? = nil, arrayStep: String? = nil) {
        self.id = id
        self.frame = frame
        self.kind = kind
        self.label = label
        self.arrayID = arrayID
        self.arrayStep = arrayStep
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

/// Builds an `MA3Plan` on a grandMA3, without deleting anything that isn't Understudy's:
///
/// - **Pages** are created only when missing.
/// - **Sequences** from the pool are made in empty slots, or reused if Understudy made them (its
///   note, or its name); a sequence there that isn't Understudy's is left alone. A sequence taken
///   from an executor is the one the user pointed at. **Merge** only adds the cues that are
///   missing (existing cues keep their contents and names); **Override** first copies the
///   sequence to the next free pool number, and only replaces its cues if that copy was made.
/// - **Executors** are assigned only when empty; one holding another sequence is left alone.
/// - **Timecode shows** are replaced only when Understudy made them.
///
/// Everything runs as Lua on the console (the `Lua` keyword over OSC, or a plugin) so these
/// checks happen there. Timecode events are made with the same object calls MA3 plugins use:
/// TrackGroup → Track (target the sequence) → TimeRange → CmdSubTrack → CmdEvent (RawTime =
/// seconds × 2^24, Token, CueDestination). A new TrackGroup, Track and TimeRange only appear on a
/// later frame, so each structural step is its own chunk with a pause after it.
public enum MA3Deploy {
    public struct Step: Equatable, Sendable {
        /// Command line text for `/cmd` (a `Lua "…"` line).
        public var command: String
        /// Wait this long after sending, for MA3 to create what it made.
        public var pause: Double
    }

    public static let rawPerSecond = 16_777_216.0

    public static func rawTime(_ seconds: Double) -> Int { Int((seconds * rawPerSecond).rounded()) }

    /// Text safe inside Lua single quotes inside a command-line double-quoted string.
    static func luaText(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\n", with: " ")
    }

    static func lua(_ s: String) -> String { "'" + luaText(s) + "'" }

    /// The cue name for a marker: "01:00:24:16 Choreo – Verse 2".
    public static func cueName(_ m: Marker, rate: FrameRate, types: MarkerTypes = .defaults) -> String {
        let tc = m.timecode(rate: rate).display(dropFrame: rate.isDropFrame)
        let kind = types.name(m.kind)
        return m.label.isEmpty ? "\(tc) \(kind)" : "\(tc) \(kind) – \(m.label)"
    }

    /// Lua helpers, by name; a chunk gets the ones it uses.
    static let helpers: [(name: String, code: String)] = [
        ("O", "local function O(s) local ok,l=pcall(ObjectList,s) if ok and l then return l[1] end end"),
        ("nth", "local function nth(o,c,n) local k=0 for _,x in ipairs(o:Children()) do if x:GetClass()==c then k=k+1 if k==n then return x end end end end"),
        // Understudy's: its note says so, or its name is the one Understudy gives it (or says Understudy).
        // Never a backup Override made (its name says "before Understudy").
        ("ours", "local function ours(o,n) if not o then return false end local ok,nt,nm=pcall(function() return tostring(o.note or ''),tostring(o.name or '') end) "
            + "if not ok or nm:find('before Understudy',1,true) then return false end "
            + "return nt:find('Made by Understudy',1,true)~=nil or nm==n or nm:find('Understudy',1,true)~=nil end"),
        ("mark", "local function mark(o,n) if o then o:Set('Name',n) pcall(function() o:Set('Note','Made by Understudy') end) end end"),
        ("seqAt", "local function seqAt(p,e) local x=O('Page '..p..'.'..e) if not x then return nil end "
            + "local ok,n=pcall(function() local o=x.Object if o and o:GetClass()=='Sequence' then return o.no end end) if ok then return n end end"),
        ("free", "local function free(n) while O('Sequence '..n) do n=n+1 end return n end"),
        ("track", "local function track(g,n,o,make) local spare for _,x in ipairs(g:Children()) do if x:GetClass()=='Track' then "
            + "if tostring(x.name)==n then return x end local ok,tg=pcall(function() return x.target end) "
            + "if ok and tg and o and tg==o then return x end if not spare and not (ok and tg) then spare=x end end end "
            + "if make then local x=spare or g:Append('Track') x:Set('Name',n) return x end end"),
    ]

    static func prelude(for chunk: String) -> String {
        var used = Set<String>(["O"])
        for (name, _) in helpers where chunk.contains(name + "(") { used.insert(name) }
        if used.contains("seqAt") || used.contains("free") { used.insert("O") }
        return helpers.filter { used.contains($0.name) }.map(\.code).joined(separator: " ")
    }

    /// Lua that finds sequence `q`: sets `s` (its number), `o` (it, or nil) and `mine` (safe to write).
    static func resolve(_ q: MA3Plan.Sequence) -> String {
        if q.source == .executor, let page = q.pages.first, let exec = q.exec {
            return "local x=seqAt(\(page),\(exec)) local s=x or \(q.pool) local o=O('Sequence '..s) "
                + "local mine=o~=nil and (x~=nil or ours(o,\(lua(q.name)))) "
        }
        return "local s=\(q.pool) local o=O('Sequence '..s) local mine=o~=nil and ours(o,\(lua(q.name))) "
    }

    /// Every chunk of Lua, in order, with the pause after it.
    static func chunks(_ plan: MA3Plan, batch: Int = 25) -> [(lua: String, pause: Double)] {
        var out: [(String, Double)] = []
        for p in plan.pages {
            out.append(("if not O('Page \(p.number)') then Cmd('Store Page \(p.number) /NoConfirmation') mark(O('Page \(p.number)'),\(lua(p.name))) end", 0.2))
        }
        let top = plan.sequences.map(\.pool).max() ?? 0
        for q in plan.sequences {
            var setup = resolve(q)
                + "if not o then Cmd('Store Sequence '..s..' /NoConfirmation') o=O('Sequence '..s) mark(o,\(lua(q.name))) mine=o~=nil "
                + "elseif not mine then Printf('Understudy: Sequence '..s..' was not made by Understudy, left alone') "
            if q.write == .override {
                // The backup goes above every pool number this export uses, so no later sequence lands on it.
                setup += "else local b=free(math.max(s,\(top))+1) Cmd('Copy Sequence '..s..' At Sequence '..b..' /NoConfirmation') local c=O('Sequence '..b) "
                    + "if c then c:Set('Name',tostring(o.name)..' (before Understudy)') pcall(function() c:Set('Note','Backup by Understudy') end) "
                    + "Cmd('Delete Sequence '..s..' Cue 1 Thru /NoConfirmation') "
                    + "Printf('Understudy: Sequence '..s..' backed up to Sequence '..b) "
                    + "else mine=false Printf('Understudy: could not back up Sequence '..s..', left alone') end "
            }
            setup += "end "
            if let exec = q.exec {
                for page in q.pages {
                    setup += "if mine then local c=seqAt(\(page),\(exec)) if c==nil then Cmd('Assign Sequence '..s..' At Page \(page).\(exec) /NoConfirmation') "
                        + "elseif c~=s then Printf('Understudy: Page \(page).\(exec) holds Sequence '..c..', left alone') end end "
                }
            }
            out.append((setup, 0.2))
            var i = 0
            while i < q.cues.count {
                let calls = q.cues[i..<min(i + batch, q.cues.count)].map { "q(\($0.number),\(lua($0.name)))" }.joined(separator: " ")
                out.append((resolve(q) + "if mine then local function q(n,t) local p='Sequence '..s..' Cue '..n if not O(p) then "
                    + "Cmd('Store '..p..' /NoConfirmation') local c=O(p) if c then c:Set('Name',t) end end end \(calls) end", 0.1))
                i += batch
            }
        }
        for show in plan.timecodes {
            let tc = "Timecode \(show.number)"
            let n = lua(show.name)
            out.append(("local t=O('\(tc)') if t and not ours(t,\(n)) then Printf('Understudy: \(tc) was not made by Understudy, left alone') else "
                + "if t then Cmd('Delete \(tc) /NoConfirmation') end Cmd('Store \(tc) /NoConfirmation') mark(O('\(tc)'),\(n)) end", 0.3))
            out.append(("local t=O('\(tc)') if t and ours(t,\(n)) and not nth(t,'TrackGroup',1) then t:Append('TrackGroup') end", 0.5))
            let group = "local t=O('\(tc)') local g=t and ours(t,\(n)) and nth(t,'TrackGroup',1) "
            for tr in show.tracks {
                let q = plan.sequences[tr.sequence]
                out.append((group + resolve(q) + "if g and mine then local tr=track(g,\(lua(q.name)),o,true) tr:Set('Target',o) end", 0.5))
                var i = 0
                while i < tr.events.count {
                    let calls = tr.events[i..<min(i + batch, tr.events.count)].map { "ev(\($0.raw),\($0.cue))" }.joined(separator: " ")
                    out.append((group + resolve(q) + "if g and mine then local tr=track(g,\(lua(q.name)),o) local r=tr and nth(tr,'TimeRange',1) if r then "
                        + "local st=nth(r,'CmdSubTrack',1) or r:Append('CmdSubTrack') "
                        + "local function ev(raw,c) local e=st:Append('CmdEvent') e:Set('RawTime',raw) e:Set('Token','Goto') "
                        + "e:Set('CueDestination',O('Sequence '..s..' Cue '..c)) end \(calls) end end", 0.3))
                    i += batch
                }
            }
        }
        return out
    }

    /// Every OSC command line, in order.
    public static func steps(_ plan: MA3Plan, batch: Int = 25) -> [Step] {
        chunks(plan, batch: batch).map { Step(command: "Lua \"\(prelude(for: $0.lua)) \($0.lua)\"", pause: $0.pause) }
    }

    /// One sentence on what the plan makes, for confirmations and the log.
    public static func summary(_ plan: MA3Plan) -> String {
        let seqs = plan.sequences.map { q -> String in
            let num = q.source == .executor ? "the sequence on exec \(q.exec ?? 0) (else \(q.pool))" : "Sequence \(q.pool)"
            return num
        }
        let tcs = plan.timecodes.map { "Timecode \($0.number)" }
        func list(_ a: [String]) -> String { a.count <= 3 ? a.joined(separator: ", ") : "\(a[0]) … \(a[a.count - 1]) (\(a.count))" }
        return "\(plan.markerCount) markers into \(list(seqs))" + (tcs.isEmpty ? "" : ", fired by \(list(tcs))") + "."
    }

    /// The same build as a grandMA3 plugin (import it in the Plugins pool, then run it), for a
    /// console that isn't on the network.
    public static func pluginLua(_ plan: MA3Plan, batch: Int = 25) -> String {
        var lua = "-- Understudy markers: \(summary(plan))\n"
            + "-- Adds to what's there: it never deletes a page, executor, sequence or timecode show that Understudy didn't make.\n"
            + "-- Override backs a sequence up to the next free pool number before replacing its cues.\n"
        lua += helpers.map(\.code).joined(separator: "\n") + "\n"
        lua += "return function()\n"
        for chunk in chunks(plan, batch: batch) {
            lua += "  do \(chunk.lua) end\n  coroutine.yield(\(chunk.pause))\n"
        }
        lua += "  Printf('Understudy: \(plan.markerCount) markers sent, check the command line feedback')\nend\n"
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

/// Writes markers onto disguise tracks as notes, sections or CUE tags, by running Python in the
/// Designer session (`POST /api/session/python/execute`). Each row names its track (a song's
/// markers go on the track of the same name).
///
/// Times are placed through each track's own TC tags when it has them (a song's TC tag maps show
/// code to the track), else from the track start at the row's `trackStart` of show code.
/// Nothing is removed: a note already at a marker's beat with other text is kept, a CUE tag is
/// only added where there's none, and sections are only split.
public enum D3Push {
    /// The single style every marker had before placements per type (kept for old projects).
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
    /// gives the result). Returns {tracks: {name: placed}, placed, missing, skipped, kept, tcTags}.
    public static func script(_ rows: [D3Row], rate: FrameRate) -> String {
        let list = rows.sorted { $0.seconds < $1.seconds }.map { r in
            "(\(String(format: "%.6f", r.seconds)), \(py(r.kind)), \(py(r.label)), '\(r.placement.rawValue)', "
                + "\(r.track.map(py) ?? "None"), \(String(format: "%.6f", r.trackStart)))"
        }.joined(separator: ",\n    ")
        return """
        import re
        rows = [
            \(list)
        ]
        # Track lookup that works across Designer versions (setlist attribute names have moved).
        def find(wanted):
            found = None
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
                                found = t
                    except TypeError:
                        pass
            return found
        # TC tags map show code to track time: [(tag seconds of timecode, track seconds)].
        def anchorsOf(track):
            anchors = []
            for b in track.cueBeats():
                for tag in track.tagsAtBeat(b):
                    if int(tag.type) == 0:
                        m = re.search(r'(\\d+):(\\d+):(\\d+)[:;.](\\d+)', tag.text)
                        if m:
                            h, mi, s, f = [int(x) for x in m.groups()]
                            anchors.append((h * 3600 + mi * 60 + s + f / \(String(format: "%.6f", rate.ltcRate.exact)), track.beatToTime(b)))
            anchors.sort()
            return anchors
        cache = {}
        missing = []
        skipped = []
        kept = 0
        tcTags = 0
        counts = {}
        numbers = {}
        for (sec, kind, label, place, wanted, start) in rows:
            key = wanted or ''
            if key not in cache:
                tr = find(wanted) if wanted else guisystem.track
                an = anchorsOf(tr) if tr is not None else []
                tcTags += len(an)
                cache[key] = (tr, an)
                if tr is None:
                    missing.append(wanted)
            track, anchors = cache[key]
            if track is None:
                continue
            base = None
            for (tcSec, trackSec) in anchors:
                if tcSec <= sec + 1e-6:
                    base = (tcSec, trackSec)
            if base is None:
                t = sec - start
            else:
                t = base[1] + (sec - base[0])
            if t < 0 or t > track.lengthInSec:
                skipped.append(label or kind)
                continue
            beat = track.timeToBeat(t)
            text = kind + (': ' + label if label else '')
            if place != 'section':
                old = None
                try:
                    old = track.noteAtBeat(beat)
                except Exception:
                    old = None
                if old and str(old) != text:
                    kept += 1
                else:
                    track.setNoteAtBeat(beat, text)
            if place in ('section', 'sectionAndNote'):
                if not track.sectionAtBeat(beat):
                    track.splitSectionAtBeat(beat)
            if place == 'cueTag':
                n = numbers.get(key, 0) + 1
                numbers[key] = n
                if not [x for x in track.tagsAtBeat(beat) if int(x.type) == int(TagType.CUE)]:
                    track.setTagAtBeat(beat, Tag(TagType.CUE, str(n)))
            name = str(track.name)
            counts[name] = counts.get(name, 0) + 1
        return {'tracks': counts, 'placed': sum(counts.values()), 'missing': missing, 'skipped': skipped, 'kept': kept, 'tcTags': tcTags}
        """
    }

    /// JSON body for the execute endpoint.
    public static func body(script: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["script": script])) ?? Data()
    }
}
