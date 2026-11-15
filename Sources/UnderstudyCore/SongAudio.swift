import Foundation

// MARK: - Waveform peaks

/// Builds a waveform overview: the loudest sample in each of `buckets` equal slices of a file,
/// fed a chunk at a time so a long song never has to be in memory at once.
public struct PeakAccumulator: Sendable {
    public private(set) var peaks: [Float]
    private let framesPerBucket: Double
    private var frame = 0

    /// `totalFrames` is the file's length; `buckets` is capped at the frame count.
    public init(totalFrames: Int, buckets: Int) {
        let count = max(1, min(buckets, totalFrames))
        peaks = [Float](repeating: 0, count: count)
        framesPerBucket = Double(max(totalFrames, 1)) / Double(count)
    }

    /// `magnitudes` are per-frame levels (e.g. the loudest channel's absolute sample), in order.
    public mutating func add(_ magnitudes: UnsafeBufferPointer<Float>) {
        let last = peaks.count - 1
        for value in magnitudes {
            let bucket = min(last, Int(Double(frame) / framesPerBucket))
            if value > peaks[bucket] { peaks[bucket] = value }
            frame += 1
        }
    }

    /// Peaks scaled so the loudest is 1 (quiet songs still read), clamped to 0…1.
    public var normalized: [Float] {
        let top = peaks.max() ?? 0
        guard top > 0 else { return peaks }
        return peaks.map { min(1, $0 / top) }
    }
}

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
