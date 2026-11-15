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

/// Show code from the LTC input (e.g. CuePoints, a timecode DA) or from Understudy's own song timeline.
public enum ShowCodeSource: String, Codable, CaseIterable, Sendable {
    case input
    case timeline
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let deckCount = 4

    public var decks: [DeckConfig] = (1...AppSettings.deckCount).map { DeckConfig(id: $0 - 1, name: "ME \($0)", host: "") }
    /// Show timecode rate when not auto-detecting, and the last rate detected when auto.
    public var ltcRate: FrameRate = .fps29_97DF
    /// Work the rate out from incoming LTC.
    public var ltcRateAuto = true
    /// Show timecode input: used in Stop and Record (and in Play unless a playback input is set).
    public var audioDeviceUID: String?
    public var audioChannel: Int = 0
    /// Take LTC for Play to code from its own input (a local review source), so nothing is repatched.
    public var separatePlaybackInput = false
    public var playbackAudioDeviceUID: String?
    public var playbackAudioChannel: Int = 1
    public var chase = ChaseSettings()
    public var followLatestTake = true
    /// HyperDeck timecode labels count at the video rate (e.g. 0–59 at 59.94). Turn off if your decks count at LTC rate.
    public var deckTimecodeAtVideoRate = true
    public var recordMode: RecordMode = .continuous
    /// Seconds the show clock keeps counting after LTC disappears.
    public var freewheelSeconds: Double = 2.0
    /// Network interface (BSD name, e.g. "en7") that deck discovery looks on; nil = all.
    public var discoveryInterface: String?
    /// Folder that take backups are copied into (e.g. inside Dropbox); nil until chosen.
    public var backupFolder: String?
    /// Confidence monitor: pictures of the decks from a capture device (e.g. a quad multiviewer).
    public var confidenceEnabled = false
    /// AVCaptureDevice unique ID; nil = first available.
    public var confidenceDeviceID: String?
    public var confidenceLayout: ConfidenceLayout = .quad
    /// Quadrant (0 TL, 1 TR, 2 BL, 3 BR) showing each deck, by deck id.
    public var confidenceQuadrants: [Int] = [0, 1, 2, 3]
    /// With the single layout, which deck the image is.
    public var confidenceSingleDeck = 0
    public var pictureCheck = PictureCheckSettings()
    /// Timeline song audio: output device (nil = system default) and the first of its two channels (0 = 1–2).
    /// Where show code comes from in Stop and Record: the LTC input, or the song timeline.
    public var showCodeSource: ShowCodeSource = .input
    public var timelineOutputUID: String?
    public var timelineOutputChannel = 0
    /// LTC generated from the timeline: output device and channel (0-based); nil channel = off.
    public var ltcOutputUID: String?
    public var ltcOutputChannel: Int?
    /// When a song's audio carries its own timecode, play that to LTC out instead of generated code.
    public var ltcOutUseTrackTimecode = true
    /// Stop the Mac sleeping while Understudy is open (a dedicated show machine).
    public var keepAwake = true
    /// After a restart or crash, go back to the mode Understudy was in (Record or Play) instead of Stop.
    public var resumeLastMode = false

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
        separatePlaybackInput = (try? c.decodeIfPresent(Bool.self, forKey: .separatePlaybackInput)) ?? d.separatePlaybackInput
        playbackAudioDeviceUID = (try? c.decodeIfPresent(String.self, forKey: .playbackAudioDeviceUID)) ?? d.playbackAudioDeviceUID
        playbackAudioChannel = (try? c.decodeIfPresent(Int.self, forKey: .playbackAudioChannel)) ?? d.playbackAudioChannel
        chase = (try? c.decodeIfPresent(ChaseSettings.self, forKey: .chase)) ?? d.chase
        followLatestTake = (try? c.decodeIfPresent(Bool.self, forKey: .followLatestTake)) ?? d.followLatestTake
        deckTimecodeAtVideoRate = (try? c.decodeIfPresent(Bool.self, forKey: .deckTimecodeAtVideoRate)) ?? d.deckTimecodeAtVideoRate
        recordMode = (try? c.decodeIfPresent(RecordMode.self, forKey: .recordMode)) ?? d.recordMode
        freewheelSeconds = (try? c.decodeIfPresent(Double.self, forKey: .freewheelSeconds)) ?? d.freewheelSeconds
        discoveryInterface = (try? c.decodeIfPresent(String.self, forKey: .discoveryInterface)) ?? d.discoveryInterface
        backupFolder = (try? c.decodeIfPresent(String.self, forKey: .backupFolder)) ?? d.backupFolder
        confidenceEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .confidenceEnabled)) ?? d.confidenceEnabled
        confidenceDeviceID = (try? c.decodeIfPresent(String.self, forKey: .confidenceDeviceID)) ?? d.confidenceDeviceID
        confidenceLayout = (try? c.decodeIfPresent(ConfidenceLayout.self, forKey: .confidenceLayout)) ?? d.confidenceLayout
        confidenceQuadrants = (try? c.decodeIfPresent([Int].self, forKey: .confidenceQuadrants)) ?? d.confidenceQuadrants
        if confidenceQuadrants.count != Self.deckCount { confidenceQuadrants = d.confidenceQuadrants }
        confidenceSingleDeck = (try? c.decodeIfPresent(Int.self, forKey: .confidenceSingleDeck)) ?? d.confidenceSingleDeck
        pictureCheck = (try? c.decodeIfPresent(PictureCheckSettings.self, forKey: .pictureCheck)) ?? d.pictureCheck
        showCodeSource = (try? c.decodeIfPresent(ShowCodeSource.self, forKey: .showCodeSource)) ?? d.showCodeSource
        timelineOutputUID = (try? c.decodeIfPresent(String.self, forKey: .timelineOutputUID)) ?? d.timelineOutputUID
        timelineOutputChannel = (try? c.decodeIfPresent(Int.self, forKey: .timelineOutputChannel)) ?? d.timelineOutputChannel
        ltcOutputUID = (try? c.decodeIfPresent(String.self, forKey: .ltcOutputUID)) ?? d.ltcOutputUID
        ltcOutputChannel = (try? c.decodeIfPresent(Int.self, forKey: .ltcOutputChannel)) ?? d.ltcOutputChannel
        ltcOutUseTrackTimecode = (try? c.decodeIfPresent(Bool.self, forKey: .ltcOutUseTrackTimecode)) ?? d.ltcOutUseTrackTimecode
        keepAwake = (try? c.decodeIfPresent(Bool.self, forKey: .keepAwake)) ?? d.keepAwake
        resumeLastMode = (try? c.decodeIfPresent(Bool.self, forKey: .resumeLastMode)) ?? d.resumeLastMode
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
