import Foundation

// MARK: - Finding song audio in a folder

/// Matches audio files to songs by name, for "find audio in folder".
///
/// File names often carry extras (`01 `, `TP - … - 120 BPM - SMPTE 03`), so a file matches a song
/// when the song's words appear in it in order. A file goes to the most specific song it names
/// ("Matchbox (no intro)" over "Matchbox"); a song takes its closest file (the exact name, else the
/// one with the fewest extra words). Variant words — acoustic, instrumental, no intro, stems, click
/// and the like — have to be in the song's name too, so "Heart" never picks up "Heart (Acoustic)".
public enum AudioMatcher {
    public static let extensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "caf", "mp3", "m4a", "aac", "flac"]

    private static let variants: [String] = [
        "acoustic", "instrumental", "inst", "karaoke", "click", "guide", "stem", "stems",
        "no intro", "edit", "remix", "reprise", "live", "demo", "rehearsal", "alt", "alternate",
    ]

    /// Lower-case words, `&` as "and", apostrophes dropped ("We're" → "were", as file names usually
    /// spell it), everything else a separator: " lady lie acoustic ".
    static func normalize(_ s: String) -> String {
        let words = s.lowercased().replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return " " + words.joined(separator: " ") + " "
    }

    /// Song name → file path, for every song that found a file.
    public static func match(songs: [String], files: [String]) -> [String: String] {
        let normSongs = songs.map { (name: $0, norm: normalize($0)) }.filter { $0.norm.count > 2 }
        var candidates: [String: [(path: String, extra: Int)]] = [:]
        for path in files {
            let url = URL(fileURLWithPath: path)
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            let file = normalize(url.deletingPathExtension().lastPathComponent)
            // The most specific song this file names.
            let fits = normSongs.filter { song in
                file.contains(song.norm) && variants.allSatisfy { v in
                    !file.contains(" \(v) ") || song.norm.contains(" \(v) ")
                }
            }
            guard let best = fits.max(by: { $0.norm.count < $1.norm.count }) else { continue }
            candidates[best.name, default: []].append((path, file.count - best.norm.count))
        }
        return candidates.compactMapValues { $0.min { $0.extra < $1.extra }?.path }
    }
}

// MARK: - Timecode inside song audio

/// What a scan found: the channel carrying LTC, and the show time (seconds at the show rate) of
/// the file's first sample, from that LTC.
public struct LTCScanResult: Codable, Equatable, Sendable {
    public var channel: Int
    public var fileStartSeconds: Double
    public var frames: Int

    public init(channel: Int, fileStartSeconds: Double, frames: Int) {
        self.channel = channel
        self.fileStartSeconds = fileStartSeconds
        self.frames = frames
    }

    /// The file's start relative to a song starting at `songStart` (seconds), if the two agree
    /// to within `trust` seconds; a bigger gap means the file's code isn't this song's show code.
    public func offset(fromSongStart songStart: Double, trust: Double = 60) -> Double? {
        let offset = fileStartSeconds - songStart
        return abs(offset) <= trust ? offset : nil
    }
}

/// Looks for LTC in each channel of an audio file (fed the first few seconds), so a channel of
/// timecode can be muted, played to LTC out, and used to line the audio up.
public final class LTCChannelScanner {
    private let decoders: [LTCDecoder]
    private var starts: [[Double]]
    private let sampleRate: Double
    private let rate: FrameRate

    public init(channels: Int, sampleRate: Double, rate: FrameRate) {
        decoders = (0..<max(1, channels)).map { _ in LTCDecoder(sampleRate: sampleRate) }
        starts = Array(repeating: [], count: max(1, channels))
        self.sampleRate = sampleRate
        self.rate = rate.ltcRate
    }

    /// Feeds one channel's next samples (channels are fed in step, from the file's first sample).
    public func feed(channel: Int, _ samples: UnsafePointer<Float>, count: Int) {
        guard decoders.indices.contains(channel) else { return }
        let fps = rate.exact
        let sampleRate = self.sampleRate
        let rate = self.rate
        decoders[channel].process(samples, count: count) { frame in
            // The frame ends at its boundary sample; it started one frame earlier.
            let frameStart = Double(frame.timecode.frameIndex(at: rate)) / fps
            let start = frameStart + 1 / fps - Double(frame.boundarySample) / sampleRate
            starts[channel].append(start)
        }
    }

    /// The channel with the most decoded frames (at least `minFrames`), and the median start.
    public func result(minFrames: Int = 10) -> LTCScanResult? {
        guard let best = starts.indices.max(by: { starts[$0].count < starts[$1].count }),
              starts[best].count >= minFrames else { return nil }
        let sorted = starts[best].sorted()
        return LTCScanResult(channel: best, fileStartSeconds: sorted[sorted.count / 2], frames: sorted.count)
    }
}
