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
    /// A HyperDeck at `host`, or Understudy recording on this Mac (`recorder`).
    public var kind: DeckKind = .hyperdeck
    /// Source and codec when `kind` is `.recorder`.
    public var recorder = RecorderSettings()

    public init(id: Int, name: String, host: String, enabled: Bool = true, playOffsetFrames: Double = 0,
                kind: DeckKind = .hyperdeck, recorder: RecorderSettings = RecorderSettings()) {
        self.id = id
        self.name = name
        self.host = host
        self.enabled = enabled
        self.playOffsetFrames = playOffsetFrames
        self.kind = kind
        self.recorder = recorder
    }

    public var isRecorder: Bool { kind == .recorder }

    /// Something to connect to: an address for a HyperDeck, a source for the recorder.
    public var isAssigned: Bool {
        switch kind {
        case .hyperdeck: return !host.trimmingCharacters(in: .whitespaces).isEmpty
        case .recorder: return recorder.source != nil
        }
    }

    /// The address a HyperDeck slot uses (nil for the recorder, which has none).
    public var networkHost: String? {
        guard kind == .hyperdeck else { return nil }
        let h = host.trimmingCharacters(in: .whitespaces)
        return h.isEmpty ? nil : h
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "ME \(id + 1)"
        host = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? ""
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        playOffsetFrames = (try? c.decodeIfPresent(Double.self, forKey: .playOffsetFrames)) ?? 0
        kind = (try? c.decodeIfPresent(DeckKind.self, forKey: .kind)) ?? .hyperdeck
        recorder = (try? c.decodeIfPresent(RecorderSettings.self, forKey: .recorder)) ?? RecorderSettings()
    }
}

/// Show code from the LTC input (e.g. CuePoints, a timecode DA) or from Understudy's own song timeline.
/// Another place the timeline's song audio plays at the same time as its main output (headphones,
/// a second interface, a record feed): a device (nil = system default) and the first of its two channels.
public struct SongOutput: Codable, Equatable, Hashable, Sendable {
    public var deviceUID: String?
    public var channel: Int

    public init(deviceUID: String?, channel: Int = 0) {
        self.deviceUID = deviceUID
        self.channel = channel
    }
}

public enum ShowCodeSource: String, Codable, CaseIterable, Sendable {
    case input
    case timeline
}

public struct AppSettings: Codable, Equatable, Sendable {
    /// Decks a new show starts with, and the most one Understudy controls.
    public static let defaultDeckCount = 4
    public static let maxDecks = 16

    public var decks: [DeckConfig] = (1...AppSettings.defaultDeckCount).map { DeckConfig(id: $0 - 1, name: "ME \($0)", host: "") }
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
    /// Network port (BSD name, e.g. "en7") for deck control: discovery looks only there, and
    /// HyperDeck control and FTP copies go out of it; nil = all ports / the system's routing.
    public var discoveryInterface: String?
    /// Network port for each other kind of traffic (grandMA3, disguise, NDI, OSC in); nil = automatic.
    public var interfaces = NetworkInterfaceSettings()
    /// Folder that take backups are copied into (e.g. inside Dropbox); nil until chosen.
    public var backupFolder: String?
    /// NotchLC transcodes go here (a subfolder per deck); nil = a NotchLC folder beside the media.
    public var notchLCFolder: String?
    /// A Media Encoder preset (.epr) for NotchLC; nil = the NotchLC format's defaults.
    public var notchLCPreset: String?
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
    /// More outputs for the song audio, playing alongside the main one (with Dante out too).
    public var extraSongOutputs: [SongOutput] = []
    /// LTC generated from the timeline: output device and channel (0-based); nil channel = off.
    /// The device is the song audio's while `ltcOutputFollowsSong` (the default), else
    /// `ltcOutputUID` (nil = system default).
    public var ltcOutputUID: String?
    public var ltcOutputChannel: Int?
    public var ltcOutputFollowsSong = true
    /// When a song's audio carries its own timecode, play that to LTC out instead of generated code.
    public var ltcOutUseTrackTimecode = true
    /// The device LTC out plays on (nil = system default).
    public var ltcOutputDeviceUID: String? { ltcOutputFollowsSong ? timelineOutputUID : ltcOutputUID }
    /// Send song audio (DVS 1–2) and timecode (DVS 3) to Dante through Dante Virtual Soundcard.
    public var danteOut = false
    /// Network port (BSD name, e.g. "en8") Dante should be on, watched for a link; nil = any.
    public var danteInterface: String?
    /// AES67 out (test): left, right and timecode as a multicast stream, announced by SAP.
    public var aes67Enabled = false
    /// Network port (BSD name) the stream goes out of; nil = none chosen yet.
    public var aes67Interface: String?
    /// Multicast group; empty = 239.69.x.y from this Mac's address on that port.
    public var aes67Multicast = ""
    public var aes67Name = "Understudy"
    /// How recordings are named on the decks.
    public var recordNaming = RecordNaming()
    /// How Understudy plays recordings back (Playback LUTs): viewer and NDI out only.
    public var playback = PlaybackLUTSettings()
    /// OSC control in (Stream Deck via Companion, grandMA3, …): play, pause, markers.
    public var oscEnabled = true
    public var oscPort = 9000
    /// grandMA3 that markers are deployed to over OSC (its OSC line needs Receive Command on).
    public var ma3Host = ""
    public var ma3Port = 8000
    /// The OSC prefix set on the MA3's OSC line ("gma3" → /gma3/cmd); empty = none.
    public var ma3Prefix = "gma3"
    /// Sequence and timecode show the deploy replaces.
    public var ma3Sequence = 1001
    public var ma3Timecode = 101
    /// disguise director (or the machine running Designer) for pushing markers to a track.
    public var d3Host = ""
    /// Track to write to by name; empty = the track Designer has selected.
    public var d3Track = ""
    public var d3Style: D3Push.Style = .notes
    /// For tracks without TC tags: the show timecode at the track's start.
    public var d3TrackStart = "00:00:00:00"
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
        interfaces = (try? c.decodeIfPresent(NetworkInterfaceSettings.self, forKey: .interfaces)) ?? d.interfaces
        backupFolder = (try? c.decodeIfPresent(String.self, forKey: .backupFolder)) ?? d.backupFolder
        notchLCFolder = (try? c.decodeIfPresent(String.self, forKey: .notchLCFolder)) ?? d.notchLCFolder
        notchLCPreset = (try? c.decodeIfPresent(String.self, forKey: .notchLCPreset)) ?? d.notchLCPreset
        confidenceEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .confidenceEnabled)) ?? d.confidenceEnabled
        confidenceDeviceID = (try? c.decodeIfPresent(String.self, forKey: .confidenceDeviceID)) ?? d.confidenceDeviceID
        confidenceLayout = (try? c.decodeIfPresent(ConfidenceLayout.self, forKey: .confidenceLayout)) ?? d.confidenceLayout
        confidenceQuadrants = (try? c.decodeIfPresent([Int].self, forKey: .confidenceQuadrants)) ?? d.confidenceQuadrants
        // (Sized to the deck list in normalizeDecks.)
        confidenceSingleDeck = (try? c.decodeIfPresent(Int.self, forKey: .confidenceSingleDeck)) ?? d.confidenceSingleDeck
        pictureCheck = (try? c.decodeIfPresent(PictureCheckSettings.self, forKey: .pictureCheck)) ?? d.pictureCheck
        showCodeSource = (try? c.decodeIfPresent(ShowCodeSource.self, forKey: .showCodeSource)) ?? d.showCodeSource
        timelineOutputUID = (try? c.decodeIfPresent(String.self, forKey: .timelineOutputUID)) ?? d.timelineOutputUID
        timelineOutputChannel = (try? c.decodeIfPresent(Int.self, forKey: .timelineOutputChannel)) ?? d.timelineOutputChannel
        extraSongOutputs = (try? c.decodeIfPresent([SongOutput].self, forKey: .extraSongOutputs)) ?? d.extraSongOutputs
        ltcOutputUID = (try? c.decodeIfPresent(String.self, forKey: .ltcOutputUID)) ?? d.ltcOutputUID
        ltcOutputChannel = (try? c.decodeIfPresent(Int.self, forKey: .ltcOutputChannel)) ?? d.ltcOutputChannel
        // Before 0.13 there was no "same as song audio": a device picked for LTC stays picked,
        // and no device (which meant the system default) now follows the song audio.
        ltcOutputFollowsSong = (try? c.decodeIfPresent(Bool.self, forKey: .ltcOutputFollowsSong)) ?? (ltcOutputUID == nil)
        ltcOutUseTrackTimecode = (try? c.decodeIfPresent(Bool.self, forKey: .ltcOutUseTrackTimecode)) ?? d.ltcOutUseTrackTimecode
        danteOut = (try? c.decodeIfPresent(Bool.self, forKey: .danteOut)) ?? d.danteOut
        danteInterface = (try? c.decodeIfPresent(String.self, forKey: .danteInterface)) ?? d.danteInterface
        recordNaming = (try? c.decodeIfPresent(RecordNaming.self, forKey: .recordNaming)) ?? d.recordNaming
        playback = PlaybackLUTSettings.decode(from: c, playback: .playback, decks: .decks)
        aes67Enabled = (try? c.decodeIfPresent(Bool.self, forKey: .aes67Enabled)) ?? d.aes67Enabled
        aes67Interface = (try? c.decodeIfPresent(String.self, forKey: .aes67Interface)) ?? d.aes67Interface
        aes67Multicast = (try? c.decodeIfPresent(String.self, forKey: .aes67Multicast)) ?? d.aes67Multicast
        aes67Name = (try? c.decodeIfPresent(String.self, forKey: .aes67Name)) ?? d.aes67Name
        oscEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .oscEnabled)) ?? d.oscEnabled
        oscPort = (try? c.decodeIfPresent(Int.self, forKey: .oscPort)) ?? d.oscPort
        ma3Host = (try? c.decodeIfPresent(String.self, forKey: .ma3Host)) ?? d.ma3Host
        ma3Port = (try? c.decodeIfPresent(Int.self, forKey: .ma3Port)) ?? d.ma3Port
        ma3Prefix = (try? c.decodeIfPresent(String.self, forKey: .ma3Prefix)) ?? d.ma3Prefix
        ma3Sequence = (try? c.decodeIfPresent(Int.self, forKey: .ma3Sequence)) ?? d.ma3Sequence
        ma3Timecode = (try? c.decodeIfPresent(Int.self, forKey: .ma3Timecode)) ?? d.ma3Timecode
        d3Host = (try? c.decodeIfPresent(String.self, forKey: .d3Host)) ?? d.d3Host
        d3Track = (try? c.decodeIfPresent(String.self, forKey: .d3Track)) ?? d.d3Track
        d3Style = (try? c.decodeIfPresent(D3Push.Style.self, forKey: .d3Style)) ?? d.d3Style
        d3TrackStart = (try? c.decodeIfPresent(String.self, forKey: .d3TrackStart)) ?? d.d3TrackStart
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

    /// The app indexes decks by `id`, so ids must be exactly 0..<count in order (1–16 decks).
    /// Repairs stored settings that don't match rather than crashing on launch. The confidence
    /// monitor's quadrant list follows the deck list (-1: not on the multiviewer).
    public mutating func normalizeDecks() {
        decks = Self.normalized(decks.sorted { $0.id < $1.id })
        if confidenceQuadrants.count > decks.count {
            confidenceQuadrants = Array(confidenceQuadrants.prefix(decks.count))
        }
        while confidenceQuadrants.count < decks.count {
            let i = confidenceQuadrants.count
            confidenceQuadrants.append(i < 4 && !confidenceQuadrants.contains(i) ? i : -1)
        }
        if confidenceSingleDeck >= decks.count { confidenceSingleDeck = 0 }
    }
}
