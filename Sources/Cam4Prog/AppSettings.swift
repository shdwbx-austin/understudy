import Foundation
import Cam4ProgCore

struct DeckConfig: Codable, Equatable, Identifiable {
    var id: Int
    var name: String
    var host: String
    var enabled: Bool = true
    /// Frames to fire `play` early. Positive = deck is slow to start.
    var playOffsetFrames: Double = 0
}

struct AppSettings: Codable, Equatable {
    var decks: [DeckConfig] = (1...AppSettings.deckCount).map { DeckConfig(id: $0 - 1, name: "ME \($0)", host: "") }
    var ltcRate: FrameRate = .fps29_97DF
    var audioDeviceUID: String?
    var audioChannel: Int = 0
    var chase = ChaseSettings()
    var followLatestTake = true
    /// HyperDeck timecode labels count at the video rate (e.g. 0–59 at 59.94). Turn off if your decks count at LTC rate.
    var deckTimecodeAtVideoRate = true
    /// Arm decks with their own timecode-run record trigger (frame accurate) rather than an app-sent `record`.
    var nativeRecordTrigger = true

    private static let key = "cam4prog.settings.v1"

    static let deckCount = 4

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              var settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        settings.normalizeDecks()
        return settings
    }

    /// The app indexes decks by `id`, so ids must be exactly 0..<deckCount in order.
    /// Repairs stored settings that don't match rather than crashing on launch.
    mutating func normalizeDecks() {
        let defaults = AppSettings().decks
        decks = (0..<Self.deckCount).map { index in
            guard var deck = decks.first(where: { $0.id == index }) ?? (decks.indices.contains(index) ? decks[index] : nil)
            else { return defaults[index] }
            deck.id = index
            return deck
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
