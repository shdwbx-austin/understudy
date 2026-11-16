import Foundation
import UnderstudyCore

/// Keeps one deck's take maps on disk:
/// ~/Library/Application Support/Understudy/takemaps/deck-N.json
///
/// A map is built while the deck records (`inProgress`, saved every few seconds so a crash loses
/// little), becomes `pending` when recording stops, and is filed under its clip(s) once the deck's
/// clip list shows the new take.
@MainActor
final class TakeMapStore {
    struct Pending: Codable {
        var map: TakeMap
        /// Clips already on the deck when this recording started; the take can't be one of these.
        var existingClipKeys: Set<String>
    }

    struct Contents: Codable {
        var maps: [String: TakeMap] = [:]
        var pending: [Pending] = []
        var inProgress: TakeMap?
        var inProgressExistingClipKeys: Set<String> = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            maps = (try? c.decodeIfPresent([String: TakeMap].self, forKey: .maps)) ?? [:]
            pending = (try? c.decodeIfPresent([Pending].self, forKey: .pending)) ?? []
            inProgress = try? c.decodeIfPresent(TakeMap.self, forKey: .inProgress)
            inProgressExistingClipKeys = (try? c.decodeIfPresent(Set<String>.self, forKey: .inProgressExistingClipKeys)) ?? []
        }
    }

    private static let maxMaps = 2000
    private static let pendingLifetime: TimeInterval = 7 * 24 * 3600

    private(set) var contents: Contents
    private let url: URL?

    /// Deck `id` was removed from a list of `count`: its maps go, and later decks' files move up a
    /// number so each physical deck keeps its maps.
    static func removeDeck(id: Int, count: Int) {
        let dir = TimelineModel.storeDirectory.appendingPathComponent("takemaps", isDirectory: true)
        let fm = FileManager.default
        func file(_ i: Int) -> URL { dir.appendingPathComponent("deck-\(i + 1).json") }
        try? fm.removeItem(at: file(id))
        for i in (id + 1)..<max(id + 1, count) where fm.fileExists(atPath: file(i).path) {
            try? fm.moveItem(at: file(i), to: file(i - 1))
        }
    }

    init(deckID: Int) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let dir: URL? = TimelineModel.storeDirectory.appendingPathComponent("takemaps", isDirectory: true)
        url = dir?.appendingPathComponent("deck-\(deckID + 1).json")
        // Maps saved before the rename from cam4prog.
        if let url, let old = support?.appendingPathComponent("cam4prog/takemaps/deck-\(deckID + 1).json"),
           !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: old, to: url)
        }
        if let url, let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode(Contents.self, from: data) {
            contents = loaded
        } else {
            contents = Contents()
        }
    }

    static func key(for clip: DeckClip) -> String { "\(clip.name)|\(clip.start)|\(clip.duration)" }

    func map(for clip: DeckClip) -> TakeMap? { contents.maps[Self.key(for: clip)] }

    /// A new recording started; remember which clips it can't be.
    func startRecording(existingClips: [DeckClip]) {
        contents.inProgress = TakeMap()
        contents.inProgressExistingClipKeys = Set(existingClips.map(Self.key(for:)))
        write()
    }

    func saveInProgress(_ map: TakeMap) {
        contents.inProgress = map
        write()
    }

    /// Recording stopped: queue the map until its clip shows up. An empty map is kept on purpose,
    /// so a take recorded with no show code at all reads as such instead of falling back to clip timecode.
    func finishRecording(_ map: TakeMap?) {
        if let map = map ?? contents.inProgress {
            contents.pending.append(Pending(map: map, existingClipKeys: contents.inProgressExistingClipKeys))
        }
        contents.inProgress = nil
        contents.inProgressExistingClipKeys = []
        write()
    }

    /// Files each pending map under the clips its recording produced: clips that weren't on the
    /// deck when recording started, have no map yet, and (for a map with code) overlap it in deck time.
    /// `deckSpan` gives a clip's deck time [start, end) in seconds.
    func attachPending(to clips: [DeckClip], deckSpan: (DeckClip) -> (Double, Double)) {
        guard !contents.pending.isEmpty else { return }
        var stillPending: [Pending] = []
        // Oldest recording first, so a false start doesn't take the real run's clip.
        for item in contents.pending.sorted(by: { $0.map.createdAt < $1.map.createdAt }) {
            let candidates = clips.filter { clip in
                let key = Self.key(for: clip)
                return !item.existingClipKeys.contains(key) && contents.maps[key] == nil
            }
            let matches: [DeckClip]
            if let range = item.map.deckRange {
                matches = candidates.filter { clip in
                    let (start, end) = deckSpan(clip)
                    return range.upperBound > start && range.lowerBound < end
                }
            } else {
                // No code logged: the oldest clip that's new since it started.
                matches = candidates.first.map { [$0] } ?? []
            }
            if matches.isEmpty {
                if Date().timeIntervalSince(item.map.createdAt) < Self.pendingLifetime { stillPending.append(item) }
                continue
            }
            for clip in matches { contents.maps[Self.key(for: clip)] = item.map }
        }
        contents.pending = stillPending
        trim()
        write()
    }

    private func trim() {
        guard contents.maps.count > Self.maxMaps else { return }
        let oldest = contents.maps.sorted { $0.value.createdAt < $1.value.createdAt }
            .prefix(contents.maps.count - Self.maxMaps)
        for (key, _) in oldest { contents.maps.removeValue(forKey: key) }
    }

    private func write() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(contents).write(to: url, options: .atomic)
        } catch {
            NSLog("Understudy: couldn't save take maps: \(error.localizedDescription)")
        }
    }
}
