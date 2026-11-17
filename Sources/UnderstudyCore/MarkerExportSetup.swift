import Foundation

// MARK: - Export setup (saved with the project)

/// How markers go to grandMA3 and disguise: which types and songs, and where they land.
public struct MarkerExportSetup: Codable, Equatable, Sendable {
    public var ma3 = MA3ExportSettings()
    public var d3 = D3ExportSettings()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ma3 = (try? c.decodeIfPresent(MA3ExportSettings.self, forKey: .ma3)) ?? MA3ExportSettings()
        d3 = (try? c.decodeIfPresent(D3ExportSettings.self, forKey: .d3)) ?? D3ExportSettings()
    }
}

/// grandMA3: sequences (one, per marker type, or per song and type), the pages and executors they
/// go on, and the timecode shows that fire them. Nothing that isn't Understudy's is deleted.
public struct MA3ExportSettings: Codable, Equatable, Sendable {
    public enum Sequences: String, Codable, CaseIterable, Sendable {
        case single, perType, perSongAndType
        public var title: String {
            switch self {
            case .single: return "One sequence"
            case .perType: return "Sequence per marker type"
            case .perSongAndType: return "Sequence per song and type"
            }
        }
    }

    public enum Timecodes: String, Codable, CaseIterable, Sendable {
        case single, perSong
        public var title: String { self == .single ? "One timecode show" : "Timecode show per song" }
    }

    public enum Pages: String, Codable, CaseIterable, Sendable {
        case none, fixed, perSong
        public var title: String {
            switch self {
            case .none: return "Don't assign"
            case .fixed: return "One page"
            case .perSong: return "Page per song"
            }
        }
    }

    /// Where a sequence comes from: a pool number, or whatever is already on its executor.
    public enum Source: String, Codable, CaseIterable, Sendable {
        case pool, executor
        public var title: String { self == .pool ? "New" : "On exec" }
    }

    /// What happens to a sequence that's already there. Merge only adds; Override backs the
    /// sequence up to a free pool number first, then replaces its cues.
    public enum Write: String, Codable, CaseIterable, Sendable {
        case merge, override
        public var title: String { self == .merge ? "Merge" : "Override" }
    }

    public struct Target: Codable, Equatable, Sendable {
        public var include = true
        /// Executor number on the page (e.g. 201); nil = not assigned.
        public var exec: Int?
        public var source: Source = .pool
        public var write: Write = .merge

        public init(include: Bool = true, exec: Int? = nil, source: Source = .pool, write: Write = .merge) {
            self.include = include
            self.exec = exec
            self.source = source
            self.write = write
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            include = (try? c.decodeIfPresent(Bool.self, forKey: .include)) ?? true
            exec = try? c.decodeIfPresent(Int.self, forKey: .exec)
            source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .pool
            write = (try? c.decodeIfPresent(Write.self, forKey: .write)) ?? .merge
        }
    }

    public struct SongSetting: Codable, Equatable, Sendable {
        public var include = true
        /// This song's page, instead of the next in order.
        public var page: Int?
        public init(include: Bool = true, page: Int? = nil) {
            self.include = include
            self.page = page
        }
    }

    public var sequences: Sequences = .single
    /// Pool numbers between songs (per song and type): song n's types start at start + n × offset.
    public var songOffset = 20
    public var timecodes: Timecodes = .single
    public var pages: Pages = .none
    /// The page (one page), or the first song's page (page per song).
    public var page = 1
    /// Fire every event this many frames early (console latency).
    public var latencyFrames = 0
    /// Per marker type, by its id.
    public var types: [String: Target] = [:]
    /// The one sequence's executor (one sequence).
    public var single = Target()
    /// Per song, by its id.
    public var songs: [String: SongSetting] = [:]

    public init() {}

    public func target(_ kind: MarkerKind) -> Target { types[kind.rawValue] ?? Target() }
    public func song(_ id: UUID) -> SongSetting { songs[id.uuidString] ?? SongSetting() }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MA3ExportSettings()
        sequences = (try? c.decodeIfPresent(Sequences.self, forKey: .sequences)) ?? d.sequences
        songOffset = (try? c.decodeIfPresent(Int.self, forKey: .songOffset)) ?? d.songOffset
        timecodes = (try? c.decodeIfPresent(Timecodes.self, forKey: .timecodes)) ?? d.timecodes
        pages = (try? c.decodeIfPresent(Pages.self, forKey: .pages)) ?? d.pages
        page = (try? c.decodeIfPresent(Int.self, forKey: .page)) ?? d.page
        latencyFrames = (try? c.decodeIfPresent(Int.self, forKey: .latencyFrames)) ?? d.latencyFrames
        types = (try? c.decodeIfPresent([String: Target].self, forKey: .types)) ?? d.types
        single = (try? c.decodeIfPresent(Target.self, forKey: .single)) ?? d.single
        songs = (try? c.decodeIfPresent([String: SongSetting].self, forKey: .songs)) ?? d.songs
    }
}

/// disguise: each song's markers go on the track of the same name (or one named track), and each
/// marker type becomes notes, sections or CUE tags.
public struct D3ExportSettings: Codable, Equatable, Sendable {
    public enum Target: String, Codable, CaseIterable, Sendable {
        case trackPerSong, single
        public var title: String { self == .trackPerSong ? "Track per song (by name)" : "One track" }
    }

    public enum Placement: String, Codable, CaseIterable, Sendable {
        case note, section, sectionAndNote, cueTag, off
        public var title: String {
            switch self {
            case .note: return "Note"
            case .section: return "Section"
            case .sectionAndNote: return "Section + note"
            case .cueTag: return "CUE tag + note"
            case .off: return "Off"
            }
        }

        /// The placement every type had before it could be chosen per type.
        public init(_ style: D3Push.Style) {
            switch style {
            case .notes: self = .note
            case .sectionsAndNotes: self = .sectionAndNote
            case .cueTags: self = .cueTag
            }
        }
    }

    public struct SongSetting: Codable, Equatable, Sendable {
        public var include = true
        /// The disguise track's name, when it isn't the song's.
        public var track: String?
        public init(include: Bool = true, track: String? = nil) {
            self.include = include
            self.track = track
        }
    }

    public var target: Target = .trackPerSong
    /// Per marker type, by its id. Missing: the project's old single style.
    public var types: [String: Placement] = [:]
    public var songs: [String: SongSetting] = [:]

    public init() {}

    public func placement(_ kind: MarkerKind, fallback: D3Push.Style = .notes) -> Placement {
        types[kind.rawValue] ?? Placement(fallback)
    }

    public func song(_ id: UUID) -> SongSetting { songs[id.uuidString] ?? SongSetting() }

    /// The disguise track a song's markers go on.
    public func trackName(for song: ExportSong) -> String {
        let t = self.song(song.id).track?.trimmingCharacters(in: .whitespaces) ?? ""
        return t.isEmpty ? song.name : t
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = (try? c.decodeIfPresent(Target.self, forKey: .target)) ?? .trackPerSong
        types = (try? c.decodeIfPresent([String: Placement].self, forKey: .types)) ?? [:]
        songs = (try? c.decodeIfPresent([String: SongSetting].self, forKey: .songs)) ?? [:]
    }
}

// MARK: - Songs

/// A song on the set, as the exports see it: its place in the set and the show code it covers
/// (from its lead-in to its end).
public struct ExportSong: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Place in the set, from 0.
    public var index: Int
    /// Show seconds at the song's first frame (where a disguise track without TC tags starts).
    public var showStart: Double
    /// Show seconds covered: lead-in start ..< end.
    public var from: Double
    public var to: Double

    public init(id: UUID = UUID(), name: String, index: Int, showStart: Double, from: Double? = nil, to: Double) {
        self.id = id
        self.name = name
        self.index = index
        self.showStart = showStart
        self.from = from ?? showStart
        self.to = to
    }

    /// The set, in order.
    public static func set(_ layout: TimelineLayout) -> [ExportSong] {
        layout.items.enumerated().map { i, item in
            ExportSong(id: item.song.id, name: item.song.name, index: i, showStart: item.showStart,
                       from: item.showStart - layout.gap, to: item.showStart + item.duration)
        }
    }
}

public enum MarkerBuckets {
    public struct Bucket: Equatable, Sendable {
        /// nil when there's no set: every marker, in one bucket.
        public var song: ExportSong?
        public var markers: [Marker]
        public var index: Int { song?.index ?? 0 }
    }

    /// Markers by song, in set order; markers on no set song are counted in `outside`.
    /// With no set, every marker is in one bucket with no song.
    public static func split(_ markers: [Marker], songs: [ExportSong], rate: FrameRate) -> (buckets: [Bucket], outside: Int) {
        let sorted = markers.sorted { $0.frame < $1.frame }
        guard !songs.isEmpty else { return (sorted.isEmpty ? [] : [Bucket(song: nil, markers: sorted)], 0) }
        var buckets = songs.map { Bucket(song: $0, markers: []) }
        var outside = 0
        for m in sorted {
            let s = m.seconds(rate: rate)
            if let i = songs.firstIndex(where: { s >= $0.from - 1e-9 && s < $0.to }) {
                buckets[i].markers.append(m)
            } else {
                outside += 1
            }
        }
        return (buckets.filter { !$0.markers.isEmpty }, outside)
    }
}

// MARK: - grandMA3 plan

/// What an MA3 export makes: pages, sequences (with their cues and executors) and timecode shows.
/// Built from the settings; turned into console Lua by `MA3Deploy`.
public struct MA3Plan: Equatable, Sendable {
    public struct Cue: Equatable, Sendable {
        public var number: Int
        public var name: String
    }

    public struct Sequence: Equatable, Sendable {
        public var name: String
        /// Pool number: used when the executor is empty or the source is the pool.
        public var pool: Int
        /// Executor number and the pages it's assigned on (none: not assigned).
        public var exec: Int?
        public var pages: [Int]
        public var source: MA3ExportSettings.Source
        public var write: MA3ExportSettings.Write
        public var cues: [Cue]
        public var kind: MarkerKind?
        public var song: String?
    }

    public struct Event: Equatable, Sendable {
        public var raw: Int
        public var cue: Int
    }

    public struct Track: Equatable, Sendable {
        /// Index into `sequences`.
        public var sequence: Int
        public var events: [Event]
    }

    public struct TimecodeShow: Equatable, Sendable {
        public var number: Int
        public var name: String
        public var tracks: [Track]
    }

    public struct Page: Equatable, Sendable {
        public var number: Int
        public var name: String
    }

    public var pages: [Page] = []
    public var sequences: [Sequence] = []
    public var timecodes: [TimecodeShow] = []
    public var markerCount = 0
    public var warnings: [String] = []

    public init() {}

    /// Builds the plan.
    /// - Parameters:
    ///   - songs: the set, in order (empty: no set; per-song choices then act as one song).
    ///   - sequenceStart: the first pool number; `timecodeStart` the first timecode show.
    ///   - name: the set's name, for the one sequence, one timecode show and one page.
    public static func make(_ markers: [Marker], songs: [ExportSong], rate: FrameRate, types: MarkerTypes,
                            settings s: MA3ExportSettings, sequenceStart: Int, timecodeStart: Int, name: String) -> MA3Plan {
        var plan = MA3Plan()
        let wanted = markers.filter { s.target($0.kind).include }
        let (allBuckets, outside) = MarkerBuckets.split(wanted, songs: songs, rate: rate)
        let buckets = allBuckets.filter { $0.song.map { s.song($0.id).include } ?? true }
        if outside > 0 { plan.warnings.append("\(outside) marker\(outside == 1 ? " isn't" : "s aren't") on a song in the set: left out.") }

        func typeIndex(_ k: MarkerKind) -> Int { types.types.firstIndex { $0.id == k } ?? types.types.count }
        func page(for b: MarkerBuckets.Bucket) -> Int? {
            switch s.pages {
            case .none: return nil
            case .fixed: return s.page
            case .perSong:
                if let song = b.song, let p = s.song(song.id).page { return p }
                return s.page + b.index
            }
        }

        // Group markers into sequences, keyed so the order is stable.
        struct Key: Hashable { var song: Int; var type: Int; var kind: MarkerKind? }
        var groups: [Key: [Marker]] = [:]
        var songOf: [Key: MarkerBuckets.Bucket] = [:]
        var pagesOf: [Key: [Int]] = [:]
        for b in buckets {
            for m in b.markers {
                let key: Key
                switch s.sequences {
                case .single: key = Key(song: 0, type: 0, kind: nil)
                case .perType: key = Key(song: 0, type: typeIndex(m.kind), kind: m.kind)
                case .perSongAndType: key = Key(song: b.index, type: typeIndex(m.kind), kind: m.kind)
                }
                groups[key, default: []].append(m)
                if songOf[key] == nil { songOf[key] = b }
                if let p = page(for: b), !(pagesOf[key] ?? []).contains(p) { pagesOf[key, default: []].append(p) }
            }
        }
        if s.sequences == .perSongAndType, types.types.count > s.songOffset, buckets.count > 1 {
            plan.warnings.append("Sequence offset \(s.songOffset) is less than the \(types.types.count) marker types: songs' sequences overlap.")
        }

        var cueOf: [UUID: (seq: Int, cue: Int)] = [:]
        for key in groups.keys.sorted(by: { ($0.song, $0.type) < ($1.song, $1.type) }) {
            let ms = groups[key]!.sorted { $0.frame < $1.frame }
            let bucket = songOf[key]!
            let target = key.kind.map { s.target($0) } ?? s.single
            let pool: Int
            let seqName: String
            switch s.sequences {
            case .single:
                pool = sequenceStart
                seqName = name
            case .perType:
                pool = sequenceStart + key.type
                seqName = types.name(key.kind!)
            case .perSongAndType:
                pool = sequenceStart + key.song * s.songOffset + key.type
                seqName = "\(bucket.song?.name ?? name) · \(types.name(key.kind!))"
            }
            let pages = target.exec == nil ? [] : (pagesOf[key] ?? [])
            var source = target.source
            if source == .executor, pages.isEmpty {
                plan.warnings.append("\(seqName): needs a page and an executor to use the sequence on it; makes Sequence \(pool) instead.")
                source = .pool
            }
            let idx = plan.sequences.count
            var cues: [Cue] = []
            for (i, m) in ms.enumerated() {
                cues.append(Cue(number: i + 1, name: MA3Deploy.cueName(m, rate: rate, types: types)))
                cueOf[m.id] = (idx, i + 1)
            }
            plan.sequences.append(Sequence(name: seqName, pool: pool, exec: pages.isEmpty ? nil : target.exec, pages: pages,
                                           source: source, write: target.write, cues: cues, kind: key.kind,
                                           song: s.sequences == .perSongAndType ? bucket.song?.name : nil))
        }
        if let over = plan.sequences.first(where: { $0.pool > 9999 || $0.pool < 1 }) {
            plan.warnings.append("Sequence \(over.pool) is outside the pool (1–9999).")
        }

        // Pages to create when missing.
        var seen = Set<Int>()
        for b in buckets {
            guard let p = page(for: b), plan.sequences.contains(where: { $0.pages.contains(p) }), seen.insert(p).inserted else { continue }
            plan.pages.append(Page(number: p, name: s.pages == .perSong ? (b.song?.name ?? name) : name))
        }

        // Timecode shows: events at the marker times, less the latency.
        let early = Double(max(0, s.latencyFrames)) / rate.ltcRate.exact
        func show(_ number: Int, _ showName: String, _ ms: [Marker]) -> TimecodeShow {
            var tracks: [Int: [Event]] = [:]
            for m in ms.sorted(by: { $0.frame < $1.frame }) {
                guard let w = cueOf[m.id] else { continue }
                tracks[w.seq, default: []].append(Event(raw: MA3Deploy.rawTime(max(0, m.seconds(rate: rate) - early)), cue: w.cue))
            }
            return TimecodeShow(number: number, name: showName,
                                tracks: tracks.keys.sorted().map { Track(sequence: $0, events: tracks[$0]!) })
        }
        switch s.timecodes {
        case .single:
            let all = buckets.flatMap(\.markers)
            if !all.isEmpty { plan.timecodes = [show(timecodeStart, name, all)] }
        case .perSong:
            plan.timecodes = buckets.map { show(timecodeStart + $0.index, $0.song?.name ?? name, $0.markers) }
        }
        plan.markerCount = buckets.reduce(0) { $0 + $1.markers.count }
        return plan
    }
}

// MARK: - disguise rows

/// One marker for the disguise script: where it goes and as what.
public struct D3Row: Equatable, Sendable {
    public var seconds: Double
    public var kind: String
    public var label: String
    public var placement: D3ExportSettings.Placement
    /// Track name; nil = the track selected in Designer.
    public var track: String?
    /// Show seconds at the track's start, for tracks without TC tags.
    public var trackStart: Double

    public init(seconds: Double, kind: String, label: String, placement: D3ExportSettings.Placement, track: String?, trackStart: Double) {
        self.seconds = seconds
        self.kind = kind
        self.label = label
        self.placement = placement
        self.track = track
        self.trackStart = trackStart
    }

    /// Rows for the settings: per song onto the track named after it, or all onto one track.
    /// `singleTrack` / `singleStart`: the one track's name (nil: selected) and start.
    public static func rows(_ markers: [Marker], songs: [ExportSong], rate: FrameRate, types: MarkerTypes,
                            settings s: D3ExportSettings, fallback: D3Push.Style = .notes,
                            singleTrack: String?, singleStart: Double) -> (rows: [D3Row], outside: Int) {
        let wanted = markers.filter { s.placement($0.kind, fallback: fallback) != .off }
        func row(_ m: Marker, _ track: String?, _ start: Double) -> D3Row {
            D3Row(seconds: m.seconds(rate: rate), kind: types.name(m.kind), label: m.label,
                  placement: s.placement(m.kind, fallback: fallback), track: track, trackStart: start)
        }
        switch s.target {
        case .single:
            return (wanted.sorted { $0.frame < $1.frame }.map { row($0, singleTrack, singleStart) }, 0)
        case .trackPerSong:
            let (buckets, outside) = MarkerBuckets.split(wanted, songs: songs, rate: rate)
            var rows: [D3Row] = []
            for b in buckets {
                guard let song = b.song else {
                    rows += b.markers.map { row($0, singleTrack, singleStart) }
                    continue
                }
                guard s.song(song.id).include else { continue }
                rows += b.markers.map { row($0, s.trackName(for: song), song.showStart) }
            }
            return (rows, outside)
        }
    }
}
