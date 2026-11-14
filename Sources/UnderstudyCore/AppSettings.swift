import Foundation

public enum RecordMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Decks record from REC until STOP, stamped with their own clock; Understudy logs show code
    /// against the recording. Survives LTC dropouts and jumps.
    case continuous
    /// Decks record only while show LTC runs, using their own timecode-run trigger, and stamp
    /// clips with show code. A dropout stops the recording.
    case timecodeRun

    public var id: String { rawValue }
}

public struct DeckConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var host: String
    public var enabled = true
    /// Frames to fire `play` early. Positive = deck is slow to start.
    public var playOffsetFrames: Double = 0

    public init(id: Int, name: String, host: String, enabled: Bool = true, playOffsetFrames: Double = 0) {
        self.id = id
        self.name = name
        self.host = host
        self.enabled = enabled
        self.playOffsetFrames = playOffsetFrames
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "ME \(id + 1)"
        host = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? ""
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        playOffsetFrames = (try? c.decodeIfPresent(Double.self, forKey: .playOffsetFrames)) ?? 0
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let deckCount = 4

    public var decks: [DeckConfig] = (1...AppSettings.deckCount).map { DeckConfig(id: $0 - 1, name: "ME \($0)", host: "") }
    /// Show timecode rate when not auto-detecting, and the last rate detected when auto.
    public var ltcRate: FrameRate = .fps29_97DF
    /// Work the rate out from incoming LTC.
    public var ltcRateAuto = true
    public var audioDeviceUID: String?
    public var audioChannel: Int = 0
    public var chase = ChaseSettings()
    public var followLatestTake = true
    /// HyperDeck timecode labels count at the video rate (e.g. 0–59 at 59.94). Turn off if your decks count at LTC rate.
    public var deckTimecodeAtVideoRate = true
    public var recordMode: RecordMode = .continuous
    /// Seconds the show clock keeps counting after LTC disappears.
    public var freewheelSeconds: Double = 2.0

    public init() {}

    /// Every field is optional so settings saved by an older version still load
    /// (and keep the deck IPs) after new fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        decks = (try? c.decodeIfPresent([DeckConfig].self, forKey: .decks)) ?? d.decks
        ltcRate = (try? c.decodeIfPresent(FrameRate.self, forKey: .ltcRate)) ?? d.ltcRate
        ltcRateAuto = (try? c.decodeIfPresent(Bool.self, forKey: .ltcRateAuto)) ?? d.ltcRateAuto
        audioDeviceUID = (try? c.decodeIfPresent(String.self, forKey: .audioDeviceUID)) ?? d.audioDeviceUID
        audioChannel = (try? c.decodeIfPresent(Int.self, forKey: .audioChannel)) ?? d.audioChannel
        chase = (try? c.decodeIfPresent(ChaseSettings.self, forKey: .chase)) ?? d.chase
        followLatestTake = (try? c.decodeIfPresent(Bool.self, forKey: .followLatestTake)) ?? d.followLatestTake
        deckTimecodeAtVideoRate = (try? c.decodeIfPresent(Bool.self, forKey: .deckTimecodeAtVideoRate)) ?? d.deckTimecodeAtVideoRate
        recordMode = (try? c.decodeIfPresent(RecordMode.self, forKey: .recordMode)) ?? d.recordMode
        freewheelSeconds = (try? c.decodeIfPresent(Double.self, forKey: .freewheelSeconds)) ?? d.freewheelSeconds
        normalizeDecks()
    }

    private static let key = "cam4prog.settings.v1"

    public static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }

    /// The app indexes decks by `id`, so ids must be exactly 0..<deckCount in order.
    /// Repairs stored settings that don't match rather than crashing on launch.
    public mutating func normalizeDecks() {
        let defaults = AppSettings().decks
        decks = (0..<Self.deckCount).map { index in
            guard var deck = decks.first(where: { $0.id == index }) ?? (decks.indices.contains(index) ? decks[index] : nil)
            else { return defaults[index] }
            deck.id = index
            return deck
        }
    }
}
