import Foundation
import UnderstudyCore

/// The Understudy recorder's clip list for one deck slot (what a HyperDeck keeps on its media):
/// <store>/recorder/deck-N.json. The files themselves live in the project, the backup folder or
/// ~/Movies/Understudy (see `AppModel.recorderFolder`).
@MainActor
final class RecorderTakeStore {
    private(set) var list: RecorderTakeList
    private let url: URL

    static var directory: URL { TimelineModel.storeDirectory.appendingPathComponent("recorder", isDirectory: true) }

    init(deckID: Int) {
        url = Self.directory.appendingPathComponent("deck-\(deckID + 1).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let loaded = try? decoder.decode(RecorderTakeList.self, from: data) {
            list = loaded
        } else {
            list = RecorderTakeList()
        }
    }

    /// Takes whose files are still on disk, as clips.
    var clips: [DeckClip] { list.clips { FileManager.default.fileExists(atPath: $0) } }

    func add(_ take: RecorderTake) {
        list.add(take)
        write()
    }

    func path(of clipName: String) -> String? {
        guard let p = list.take(named: clipName)?.path, FileManager.default.fileExists(atPath: p) else { return nil }
        return p
    }

    /// Deck `id` was removed from a list of `count`: later decks' lists move up a number
    /// (the files stay where they are).
    static func removeDeck(id: Int, count: Int) {
        let fm = FileManager.default
        func file(_ i: Int) -> URL { directory.appendingPathComponent("deck-\(i + 1).json") }
        try? fm.removeItem(at: file(id))
        for i in (id + 1)..<max(id + 1, count) where fm.fileExists(atPath: file(i).path) {
            try? fm.moveItem(at: file(i), to: file(i - 1))
        }
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(list).write(to: url, options: .atomic)
        } catch {
            NSLog("Understudy: couldn't save the recorder's takes: \(error.localizedDescription)")
        }
    }
}
