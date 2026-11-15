import Foundation

// MARK: - Songs

/// One song of the show: where it sits in show timecode, and the audio that plays for it.
public struct Song: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Show timecode the song starts at (as in the CSV).
    public var start: Timecode
    /// Show timecode the song ends at (exclusive). nil = runs for `duration`, else to the next song.
    public var end: Timecode?
    /// Length in seconds, from a Duration column (used when there's no end).
    public var duration: Double?
    /// Audio file played for this song, lined up with `start`.
    public var audioPath: String?
    /// Length of the audio file in seconds, read when it's attached.
    public var audioDuration: Double?
    /// On tonight's set (plays on the timeline) or only in the library.
    public var inSet: Bool

    public init(id: UUID = UUID(), name: String, start: Timecode, end: Timecode? = nil, duration: Double? = nil,
                audioPath: String? = nil, audioDuration: Double? = nil, inSet: Bool = true) {
        self.inSet = inSet
        self.id = id
        self.name = name
        self.start = start
        self.end = end
        self.duration = duration
        self.audioPath = audioPath
        self.audioDuration = audioDuration
    }
}

extension Song {
    private enum CodingKeys: String, CodingKey {
        case id, name, start, end, duration, audioPath, audioDuration, inSet
    }

    /// Timelines saved before the set list existed load with every song in the set.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        start = try c.decode(Timecode.self, forKey: .start)
        end = try c.decodeIfPresent(Timecode.self, forKey: .end)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        audioPath = try c.decodeIfPresent(String.self, forKey: .audioPath)
        audioDuration = try c.decodeIfPresent(Double.self, forKey: .audioDuration)
        inSet = try c.decodeIfPresent(Bool.self, forKey: .inSet) ?? true
    }
}

/// The library of songs and tonight's set within it.
///
/// Stored as one array: the set first, in playing order, then the rest of the library in timecode
/// order. `arranged` restores that shape after any change.
public enum SongLibrary {
    public static func arranged(_ songs: [Song], rate: FrameRate) -> [Song] {
        songs.filter(\.inSet) + songs.filter { !$0.inSet }.sorted { $0.start.frameIndex(at: rate) < $1.start.frameIndex(at: rate) }
    }

    /// A list in alphabetical order is a library, not a running order.
    public static func isAlphabetical(_ songs: [Song]) -> Bool {
        songs.count > 2 && zip(songs, songs.dropFirst()).allSatisfy {
            $0.name.localizedCaseInsensitiveCompare($1.name) != .orderedDescending
        }
    }

    /// Folds a fresh import into what was there. Songs keep their audio and, if they were on the
    /// set, their place in it (matched by name). New songs join the set when the file is a running
    /// order, or the library when it's an alphabetical list.
    public static func merge(_ imported: [Song], into previous: [Song], rate: FrameRate) -> [Song] {
        let library = isAlphabetical(imported)
        let old = Dictionary(previous.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let importedNames = Set(imported.map(\.name))
        let setOrder = Dictionary(previous.filter(\.inSet).enumerated().map { ($1.name, $0) }, uniquingKeysWith: { a, _ in a })
        // A set to keep only if the new file still has some of its songs (a different show starts fresh).
        let hadSet = setOrder.keys.contains { importedNames.contains($0) }
        var songs = imported.map { song -> Song in
            var s = song
            if let before = old[s.name] {
                s.audioPath = before.audioPath
                s.audioDuration = before.audioDuration
            }
            s.inSet = hadSet ? setOrder[s.name] != nil : !library
            return s
        }
        if hadSet {
            // Kept set songs in their old order; then new running-order songs in file order.
            let kept = songs.filter { setOrder[$0.name] != nil }.sorted { setOrder[$0.name]! < setOrder[$1.name]! }
            songs = kept + songs.filter { setOrder[$0.name] == nil }
        }
        return arranged(songs, rate: rate)
    }
}

public enum SongListError: Error, Equatable, CustomStringConvertible {
    case empty
    case badRow(line: Int, reason: String)

    public var description: String {
        switch self {
        case .empty: return "The file has no songs in it."
        case let .badRow(line, reason): return "Line \(line): \(reason)"
        }
    }
}

/// What an import produced: the songs it could place, and the names of rows with no start timecode.
public struct SongListImport: Equatable, Sendable {
    public var songs: [Song]
    public var skipped: [String]
}

/// Reads a song list: one song per row, `name, start timecode[, end timecode]`.
///
/// A header row is optional; when present its column names decide the order: a name column
/// (Song/Name/Title/Track), a start (Start, In, LTC, Timecode, TC — e.g. "LTC Start Point"), and an
/// end (End/Out) or a Duration/Length. Quoted fields, commas inside quotes, semicolon- or
/// tab-separated files and `H:MM:SS` (no frames) all work. Ruled lines (`———`) are ignored, and rows
/// whose start is blank or n/a are skipped and listed. Rows are kept in file order.
public enum SongListCSV {
    public static func parse(_ text: String) throws -> [Song] { try read(text).songs }

    public static func read(_ text: String) throws -> SongListImport {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let separator = detectSeparator(lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "")
        var rows: [(line: Int, fields: [String])] = []
        for (i, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.append((i + 1, fields(of: line, separator: separator)))
        }
        guard let first = rows.first else { throw SongListError.empty }

        var nameColumn = 0, startColumn = 1
        var endColumn: Int? = 2
        var durationColumn: Int?
        var body = rows[...]
        if !first.fields.contains(where: { timecode($0) != nil }) {
            // Header row: find the columns by the words in their names.
            let names = first.fields.map { header in
                Set(header.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            }
            func column(_ keys: Set<String>, except: Int? = nil) -> Int? {
                names.indices.first { $0 != except && !names[$0].isDisjoint(with: keys) }
            }
            nameColumn = column(["name", "song", "title", "track"]) ?? 0
            startColumn = column(["start", "in", "ltc", "timecode", "tc", "smpte", "position"], except: nameColumn) ?? 1
            endColumn = column(["end", "out", "stop"], except: startColumn)
            durationColumn = column(["duration", "length", "dur", "runtime"])
            body = rows.dropFirst()
        }

        var songs: [Song] = []
        var skipped: [String] = []
        for row in body {
            let f = row.fields
            // A ruled line under the header, or an empty row.
            if f.allSatisfy({ $0.allSatisfy { "-—–_=".contains($0) } }) { continue }
            let name = f.indices.contains(nameColumn) ? f[nameColumn].trimmingCharacters(in: .whitespaces) : ""
            let rawStart = f.indices.contains(startColumn) ? f[startColumn].trimmingCharacters(in: .whitespaces) : ""
            if Self.blank(rawStart) {
                skipped.append(name.isEmpty ? "Line \(row.line)" : name)
                continue
            }
            guard let start = timecode(rawStart) else {
                let got = f.indices.contains(startColumn) ? "\"\(f[startColumn])\"" : "nothing"
                throw SongListError.badRow(line: row.line, reason: "start timecode should be HH:MM:SS:FF, got \(got).")
            }
            var end: Timecode?
            if let endColumn, f.indices.contains(endColumn) {
                let raw = f[endColumn].trimmingCharacters(in: .whitespaces)
                if !raw.isEmpty {
                    guard let tc = timecode(raw) else {
                        throw SongListError.badRow(line: row.line, reason: "end timecode should be HH:MM:SS:FF, got \"\(raw)\".")
                    }
                    end = tc
                }
            }
            var duration: Double?
            if let durationColumn, f.indices.contains(durationColumn) { duration = seconds(f[durationColumn]) }
            songs.append(Song(name: name.isEmpty ? "Song \(songs.count + 1)" : name, start: start, end: end, duration: duration))
        }
        guard !songs.isEmpty else { throw SongListError.empty }
        return SongListImport(songs: songs, skipped: skipped)
    }

    /// No start timecode given.
    private static func blank(_ s: String) -> Bool {
        let v = s.lowercased()
        return v.isEmpty || ["n/a", "na", "-", "—", "–", "none", "tbd", "tba", "x"].contains(v)
    }

    /// `m:ss`, `h:mm:ss` or plain seconds.
    public static func seconds(_ raw: String) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard (1...3).contains(parts.count), let last = Double(parts[parts.count - 1]), last >= 0 else { return nil }
        let rest = parts.dropLast().compactMap { Int($0) }
        guard rest.count == parts.count - 1, rest.allSatisfy({ $0 >= 0 }) else { return nil }
        let value = rest.reduce(0) { $0 * 60 + Double($1) } * 60 + last
        return value > 0 ? value : nil
    }

    /// `HH:MM:SS:FF` (any of : ; . before frames) or `HH:MM:SS`.
    static func timecode(_ raw: String) -> Timecode? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let tc = Timecode(s) { return tc }
        let parts = s.split(separator: ":")
        guard parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]), let sec = Int(parts[2]),
              h >= 0, h < 100, m >= 0, m < 60, sec >= 0, sec < 60 else { return nil }
        return Timecode(hours: h, minutes: m, seconds: sec, frames: 0)
    }

    private static func detectSeparator(_ line: String) -> Character {
        let candidates: [Character] = [",", ";", "\t"]
        var best: Character = ","
        var bestCount = 0
        for c in candidates {
            var count = 0, quoted = false
            for ch in line {
                if ch == "\"" { quoted.toggle() } else if ch == c, !quoted { count += 1 }
            }
            if count > bestCount { best = c; bestCount = count }
        }
        return best
    }

    private static func fields(of line: String, separator: Character) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        var chars = Array(line)[...]
        while let ch = chars.popFirst() {
            if quoted {
                if ch == "\"" {
                    if chars.first == "\"" { current.append("\""); chars = chars.dropFirst() } else { quoted = false }
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" {
                quoted = true
            } else if ch == separator {
                out.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Layout

/// Songs laid end to end in playlist order, each with a lead-in gap before it, and the mapping
/// between timeline time and show timecode.
///
/// During a gap the timeline keeps counting show code up to the next song's start, so the decks
/// are cued to that song and rolling by its first frame, whatever came before it.
public struct TimelineLayout: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var song: Song
        /// Where the song itself (after its lead-in) starts on the timeline, seconds.
        public var timelineStart: Double
        public var duration: Double
        /// Show timecode at the song's start, in seconds at the show rate.
        public var showStart: Double

        public var timelineEnd: Double { timelineStart + duration }
    }

    public let items: [Item]
    public let gap: Double
    public let rate: FrameRate

    /// Used for a last song with no end and no audio.
    public static let openEndedDuration = 300.0

    /// `ordered` is the playlist order; durations come from each song's end or duration, else the
    /// next song in show order among `library` (all known songs; defaults to `ordered`), else its
    /// audio, else five minutes.
    public init(ordered: [Song], rate: FrameRate, gap: Double = 2, library: [Song]? = nil) {
        self.gap = max(0, gap)
        self.rate = rate
        let byShow = (library ?? ordered).sorted { $0.start.seconds(at: rate) < $1.start.seconds(at: rate) }
        var t = 0.0
        var items: [Item] = []
        for song in ordered {
            let start = song.start.seconds(at: rate)
            var duration: Double
            if let end = song.end, end.seconds(at: rate) > start {
                duration = end.seconds(at: rate) - start
            } else if let length = song.duration, length > 0 {
                duration = length
            } else if let next = byShow.first(where: { $0.start.seconds(at: rate) > start }) {
                duration = next.start.seconds(at: rate) - start
                if let audio = song.audioDuration { duration = min(duration, max(audio, 0.04)) }
            } else if let audio = song.audioDuration, audio > 0 {
                duration = audio
            } else {
                duration = Self.openEndedDuration
            }
            t += self.gap
            items.append(Item(song: song, timelineStart: t, duration: duration, showStart: start))
            t += duration
        }
        self.items = items
    }

    public var totalDuration: Double { items.last?.timelineEnd ?? 0 }

    /// The song playing (or about to, during its lead-in) at timeline time `t`.
    public func index(at t: Double) -> Int? {
        guard !items.isEmpty, t >= 0, t < totalDuration else { return nil }
        return items.firstIndex { t < $0.timelineEnd }
    }

    /// Show timecode at timeline time `t`, seconds. Counts on through the lead-in gaps.
    public func showSeconds(at t: Double) -> Double? {
        guard let i = index(at: t) else { return nil }
        let item = items[i]
        return item.showStart + (t - item.timelineStart)
    }

    /// Timeline time of `offset` seconds into song `index`.
    public func timelineTime(song index: Int, offset: Double = 0) -> Double? {
        guard items.indices.contains(index) else { return nil }
        return items[index].timelineStart + offset
    }

    /// Start of the song after the one at `t`, or nil at the last.
    public func nextSongStart(after t: Double) -> Double? {
        items.first { $0.timelineStart > t + 0.001 }?.timelineStart
    }

    /// Start of the song at `t`, or of the one before if `t` is within its first second.
    public func previousSongStart(before t: Double) -> Double? {
        let starts = items.map(\.timelineStart)
        return starts.last { $0 < t - 1 } ?? starts.first
    }
}

// MARK: - Transport

/// The timeline's own clock. Pure: give it host times; it never reads a clock itself.
///
/// While the timeline is master it stands in for incoming LTC: `snapshot` hands the chase engine
/// the same kind of reading the LTC clock does, with `jumped` set on a seek or a reordered song.
public struct TimelineTransport: Equatable, Sendable {
    public private(set) var isPlaying = false
    /// Timeline position at `anchorTime` (host seconds); while playing it advances in real time.
    public private(set) var anchorPosition = 0.0
    public private(set) var anchorTime = 0.0
    private var lastFrames: Double?
    private var lastTime: Double?

    public init() {}

    public func position(at now: Double) -> Double {
        isPlaying ? anchorPosition + (now - anchorTime) : anchorPosition
    }

    public mutating func play(at now: Double) {
        guard !isPlaying else { return }
        anchorTime = now
        isPlaying = true
    }

    public mutating func pause(at now: Double) {
        guard isPlaying else { return }
        anchorPosition = position(at: now)
        isPlaying = false
    }

    public mutating func seek(to t: Double, at now: Double) {
        anchorPosition = max(0, t)
        anchorTime = now
    }

    /// What the chase engine sees at `now`. Rolling only while playing inside the playlist.
    public mutating func snapshot(at now: Double, layout: TimelineLayout) -> LTCSnapshot {
        let fps = layout.rate.exact
        let t = position(at: now)
        guard isPlaying, let show = layout.showSeconds(at: t) else {
            lastFrames = nil
            lastTime = nil
            return LTCSnapshot(rolling: false, position: nil, jumped: false, fps: fps)
        }
        let frames = show * fps
        var jumped = false
        if let lastFrames, let lastTime {
            let expected = lastFrames + (now - lastTime) * fps
            jumped = abs(frames - expected) > 2
        }
        lastFrames = frames
        lastTime = now
        return LTCSnapshot(rolling: true, position: frames, jumped: jumped, fps: fps)
    }
}

// MARK: - LTC output

/// Streams LTC audio sample by sample, following a frame position that can jump at any time.
/// Not thread-safe: keep one per audio render thread.
public struct LTCGenerator: Sendable {
    public let rate: FrameRate
    public let sampleRate: Double
    public var amplitude: Float

    private var level: Float = 1
    private var frameIndex = Int.min
    private var bits = [UInt8](repeating: 0, count: 80)
    private var lastBit = -1
    private var lastHalf = -1

    public init(rate: FrameRate, sampleRate: Double, amplitude: Float = 0.5) {
        self.rate = rate.ltcRate
        self.sampleRate = sampleRate
        self.amplitude = amplitude
    }

    /// Fills `count` samples. `framePosition` is the LTC frame position (fractional frame index)
    /// at the first sample; nil writes silence (timeline stopped).
    public mutating func render(into out: UnsafeMutablePointer<Float>, count: Int, framePosition: Double?) {
        guard let start = framePosition else {
            for i in 0..<count { out[i] = 0 }
            frameIndex = Int.min
            lastBit = -1
            lastHalf = -1
            return
        }
        let step = rate.exact / sampleRate
        for i in 0..<count {
            let p = start + Double(i) * step
            let f = Int(p.rounded(.down))
            if f != frameIndex {
                frameIndex = f
                LTCEncoder.write(Timecode(frameIndex: f, rate: rate), rate: rate, into: &bits)
                lastBit = -1
                lastHalf = -1
            }
            let within = (p - Double(f)) * 80
            let bit = min(79, Int(within))
            let half = within - Double(bit) >= 0.5 ? 1 : 0
            if bit != lastBit {
                level = -level              // every bit starts with a transition
                lastBit = bit
                lastHalf = half
            } else if half != lastHalf {
                if bits[bit] == 1 { level = -level }   // a 1 also transitions mid-bit
                lastHalf = half
            }
            out[i] = level * amplitude
        }
    }
}
