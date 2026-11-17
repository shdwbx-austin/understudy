import Foundation

/// The show itself: songs, the set, setlists and markers. Saved in the project file.
public struct ShowContent: Codable, Equatable, Sendable {
    public var songs: [Song] = []
    public var gap: Double = 2
    public var setlists: [Setlist]?
    public var currentSetlist: UUID?
    public var autoOrderFromTakes: Bool?
    public var markers: [Marker]?
    public var hiddenMarkerKinds: [MarkerKind]?
    /// The project's marker types (nil: the built-in seven).
    public var markerTypes: MarkerTypes?
    /// Seconds between songs with no code (nil: none).
    public var downtime: Double?
    /// Stop at the end of each song instead of rolling into the next.
    public var stopAfterSong: Bool?
    public var loop: LoopSetting?

    public init() {}

    public init(songs: [Song], gap: Double, setlists: [Setlist]?, currentSetlist: UUID?, autoOrderFromTakes: Bool?,
                markers: [Marker]?, hiddenMarkerKinds: [MarkerKind]?, markerTypes: MarkerTypes? = nil,
                downtime: Double? = nil, stopAfterSong: Bool? = nil, loop: LoopSetting? = nil) {
        self.markerTypes = markerTypes
        self.downtime = downtime
        self.stopAfterSong = stopAfterSong
        self.loop = loop
        self.songs = songs
        self.gap = gap
        self.setlists = setlists
        self.currentSetlist = currentSetlist
        self.autoOrderFromTakes = autoOrderFromTakes
        self.markers = markers
        self.hiddenMarkerKinds = hiddenMarkerKinds
    }
}

/// Where markers go, per show.
public struct ShowTargets: Codable, Equatable, Sendable {
    public var ma3Host = ""
    public var ma3Port = 8000
    public var ma3Prefix = "gma3"
    public var ma3Sequence = 1001
    public var ma3Timecode = 101
    public var d3Host = ""
    public var d3Track = ""
    public var d3Style: D3Push.Style = .notes
    public var d3TrackStart = "00:00:00:00"
    public init() {}
}

/// A project file (`<Name>.understudy`): everything about one show. Machine things (audio devices,
/// LTC input, OSC port, Dante, chase tuning) stay in the app's settings.
public struct ProjectFile: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public var format = ProjectFile.currentFormat
    public var name: String
    public var created: Date
    public var modified: Date
    public var show: ShowContent
    public var decks: [DeckConfig]
    public var recordNaming: RecordNaming
    public var targets: ShowTargets

    public init(name: String, created: Date = Date(), show: ShowContent = ShowContent(),
                decks: [DeckConfig] = AppSettings().decks, recordNaming: RecordNaming = RecordNaming(),
                targets: ShowTargets = ShowTargets()) {
        self.name = name
        self.created = created
        self.modified = created
        self.show = show
        self.decks = decks
        self.recordNaming = recordNaming
        self.targets = targets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? c.decode(Int.self, forKey: .format)) ?? 1
        name = try c.decode(String.self, forKey: .name)
        created = (try? c.decode(Date.self, forKey: .created)) ?? Date()
        modified = (try? c.decode(Date.self, forKey: .modified)) ?? created
        show = (try? c.decode(ShowContent.self, forKey: .show)) ?? ShowContent()
        decks = AppSettings.normalized((try? c.decode([DeckConfig].self, forKey: .decks)) ?? AppSettings().decks)
        recordNaming = (try? c.decode(RecordNaming.self, forKey: .recordNaming)) ?? RecordNaming()
        targets = (try? c.decode(ShowTargets.self, forKey: .targets)) ?? ShowTargets()
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// A project on disk, laid out like a disguise project:
///
///     <Name>/<Name>.understudy     the project
///     <Name>/history/              <Name>_history<N>__<date>.understudy snapshots
///     <Name>/objects/AudioFile/    song audio copied in
///     <Name>/objects/SongList/     imported song lists
///     <Name>/objects/Export/       marker exports
///     <Name>/objects/VideoFile/    recordings pulled in from the backup, one folder per deck
///     <Name>/objects/LUT/          .cube LUTs the decks' input transforms use
///     <Name>/internal/analysis/    waveform and timecode caches
public struct ProjectLayout: Equatable, Sendable {
    public static let fileExtension = "understudy"
    public static let historyKeep = 50

    public enum Asset: String, CaseIterable, Sendable {
        case audio = "AudioFile", songList = "SongList", export = "Export", video = "VideoFile", lut = "LUT"
    }

    public let folder: URL
    public var name: String { folder.lastPathComponent }
    public var file: URL { folder.appendingPathComponent("\(name).\(Self.fileExtension)") }
    public var history: URL { folder.appendingPathComponent("history", isDirectory: true) }
    public var analysis: URL { folder.appendingPathComponent("internal/analysis", isDirectory: true) }
    public func objects(_ asset: Asset) -> URL { folder.appendingPathComponent("objects/\(asset.rawValue)", isDirectory: true) }

    public init(folder: URL) { self.folder = folder.standardizedFileURL }

    /// The folder for a project called `name` under `root`: name made safe for a folder.
    public static func folder(named name: String, in root: URL) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return root.appendingPathComponent(safe.isEmpty ? "Untitled" : safe, isDirectory: true)
    }

    /// A project file chosen in Finder (the .understudy file, or its folder) → the project.
    public static func project(at url: URL) -> ProjectLayout? {
        if url.pathExtension == fileExtension { return ProjectLayout(folder: url.deletingLastPathComponent()) }
        let layout = ProjectLayout(folder: url)
        return FileManager.default.fileExists(atPath: layout.file.path) ? layout : nil
    }

    public func createFolders() throws {
        let fm = FileManager.default
        for dir in [history, analysis] + Asset.allCases.map(objects) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Paths inside the project are stored relative ("objects/AudioFile/x.wav") so the folder can
    /// move (another drive, another Mac); paths outside stay absolute.
    public func stored(_ absolute: String) -> String {
        let base = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        let p = URL(fileURLWithPath: absolute).standardizedFileURL.path
        return p.hasPrefix(base) ? String(p.dropFirst(base.count)) : p
    }

    public func resolved(_ stored: String) -> String {
        stored.hasPrefix("/") ? stored : folder.appendingPathComponent(stored).path
    }

    public func isInside(_ path: String) -> Bool { !stored(path).hasPrefix("/") }

    /// Where a copy of `source` goes: objects/<asset>/<name>, numbered if a different file has it.
    public func destination(for source: URL, asset: Asset, sameFile: (URL) -> Bool) -> URL {
        let dir = objects(asset)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = dir.appendingPathComponent(source.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path), !sameFile(candidate) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// "Show_history12__15_nov_2026_20h15m30s000ms.understudy", like disguise's history files.
    public func historyFile(number: Int, at date: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd_MMM_yyyy_HH'h'mm'm'ss's'SSS'ms'"
        return history.appendingPathComponent("\(name)_history\(number)__\(f.string(from: date).lowercased()).\(Self.fileExtension)")
    }

    /// The highest history number so far.
    public func lastHistoryNumber() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: history.path)) ?? []
        return files.compactMap { f -> Int? in
            guard let r = f.range(of: "_history"), let end = f.range(of: "__", range: r.upperBound..<f.endIndex) else { return nil }
            return Int(f[r.upperBound..<end.lowerBound])
        }.max() ?? 0
    }
}

extension ProjectFile {
    /// The file's paths (song audio, deck LUTs) made absolute (`toStored` false) or stored the
    /// way `layout` keeps them (relative inside the project).
    public mutating func mapPaths(_ layout: ProjectLayout, toStored: Bool) {
        let f: (String) -> String = toStored ? layout.stored : layout.resolved
        for i in show.songs.indices {
            if let p = show.songs[i].audioPath { show.songs[i].audioPath = f(p) }
        }
        for i in decks.indices {
            if case .lut(let p) = decks[i].inputTransform { decks[i].inputTransform = .lut(path: f(p)) }
        }
    }
}

extension AppSettings {
    /// Deck ids 0..<n in order, at least one and at most `maxDecks`.
    public static func normalized(_ decks: [DeckConfig]) -> [DeckConfig] {
        let list = decks.isEmpty ? AppSettings().decks : Array(decks.prefix(maxDecks))
        return list.enumerated().map { i, d in var d = d; d.id = i; return d }
    }
}
