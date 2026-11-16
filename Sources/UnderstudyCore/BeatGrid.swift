import Foundation

/// A song's beat grid: its tempo and where a bar starts, on show code. Quarter-note beats.
public struct BeatGrid: Equatable, Sendable {
    public var bpm: Double
    public var beatsPerBar: Int
    /// Show seconds of a bar's first beat; every other beat is a whole number of beats away.
    public var origin: Double

    public init(bpm: Double, beatsPerBar: Int = 4, origin: Double) {
        self.bpm = bpm
        self.beatsPerBar = max(1, beatsPerBar)
        self.origin = origin
    }

    /// The song's grid, if it has a tempo.
    public init?(song: Song, rate: FrameRate) {
        guard let bpm = song.bpm, bpm > 0 else { return nil }
        self.init(bpm: bpm, beatsPerBar: song.beatsPerBar ?? 4,
                  origin: song.start.seconds(at: rate) + (song.downbeat ?? 0))
    }

    public var beatSeconds: Double { 60 / bpm }

    public struct Beat: Equatable, Sendable {
        /// Show seconds.
        public var seconds: Double
        /// Counting from the origin's bar as bar 1 (bars before it are 0, -1…).
        public var bar: Int
        /// 1-based beat in the bar.
        public var beat: Int
        public var isBarStart: Bool { beat == 1 }
    }

    /// Every beat from `from` to `to` (show seconds), at most `limit`.
    public func beats(from: Double, to: Double, limit: Int = 4000) -> [Beat] {
        guard to > from else { return [] }
        let first = Int(((from - origin) / beatSeconds).rounded(.up))
        let last = Int(((to - origin) / beatSeconds).rounded(.down))
        guard last >= first else { return [] }
        return (first...min(last, first + limit - 1)).map { n in
            let bar = Int((Double(n) / Double(beatsPerBar)).rounded(.down))
            let beat = n - bar * beatsPerBar
            return Beat(seconds: origin + Double(n) * beatSeconds, bar: bar + 1, beat: beat + 1)
        }
    }

    /// The beat nearest `seconds`.
    public func nearestBeat(to seconds: Double) -> Double {
        origin + ((seconds - origin) / beatSeconds).rounded() * beatSeconds
    }
}

/// Note values to array markers on, in quarter-note beats.
public enum NoteValue: String, CaseIterable, Codable, Sendable {
    case bar, half, quarter, eighth, sixteenth, eighthTriplet

    public var title: String {
        switch self {
        case .bar: return "Every bar"
        case .half: return "1/2 notes"
        case .quarter: return "1/4 notes"
        case .eighth: return "1/8 notes"
        case .sixteenth: return "1/16 notes"
        case .eighthTriplet: return "1/8 triplets"
        }
    }

    public var short: String {
        switch self {
        case .bar: return "bar"
        case .half: return "1/2"
        case .quarter: return "1/4"
        case .eighth: return "1/8"
        case .sixteenth: return "1/16"
        case .eighthTriplet: return "1/8T"
        }
    }

    /// Length in quarter-note beats.
    public func beats(perBar: Int) -> Double {
        switch self {
        case .bar: return Double(max(1, perBar))
        case .half: return 2
        case .quarter: return 1
        case .eighth: return 0.5
        case .sixteenth: return 0.25
        case .eighthTriplet: return 1.0 / 3
        }
    }
}

public enum MarkerArray {
    /// Show-code frames for hits every `step` beats after `anchorFrame` (not including it), up to
    /// `count` hits and before `endFrame`. Each hit is placed from the anchor's exact time, so
    /// rounding to frames never drifts.
    public static func frames(after anchorFrame: Int, bpm: Double, stepBeats: Double, rate: FrameRate,
                              count: Int? = nil, before endFrame: Int? = nil, limit: Int = 2000) -> [Int] {
        guard bpm > 0, stepBeats > 0 else { return [] }
        let fps = rate.ltcRate.exact
        let step = stepBeats * 60 / bpm
        let anchor = Double(anchorFrame) / fps
        var out: [Int] = []
        var n = 1
        while out.count < min(count ?? limit, limit) {
            let frame = Int(((anchor + Double(n) * step) * fps).rounded())
            if let endFrame, frame >= endFrame { break }
            if frame > (out.last ?? anchorFrame) { out.append(frame) }
            n += 1
            if count == nil, endFrame == nil { break }
        }
        return out
    }
}

public enum SongTempo {
    /// What someone types in a BPM box: "120", "120 bpm", "92,5", " 128.0 ". 20–400 only.
    public static func parse(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix("bpm") { t = String(t.dropLast(3)).trimmingCharacters(in: .whitespaces) }
        t = t.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(t), (20...400).contains(value) else { return nil }
        return value
    }

    /// Every `stride` bars, the smallest of 1, 2, 4… that puts lines at least `minimum` points
    /// apart (nil when even 64 bars is too tight).
    public static func barStride(barPoints: Double, minimum: Double) -> Int? {
        [1, 2, 4, 8, 16, 32, 64].first { Double($0) * barPoints >= minimum }
    }

    /// "TP - Heart - 120 BPM - SMPTE 03.wav" → 120; "92.5bpm" → 92.5. Plausible tempos only.
    public static func bpm(fromFileName name: String) -> Double? {
        let pattern = #"(?i)(?<![\d.])(\d{2,3}(?:\.\d+)?)\s*-?\s*bpm"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name), let value = Double(name[range]),
              (40...300).contains(value) else { return nil }
        return value
    }
}
