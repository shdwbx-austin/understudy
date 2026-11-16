import Foundation

/// Sending the timeline to a Dante network through Dante Virtual Soundcard (DVS).
///
/// DVS appears to macOS as an ordinary audio device whose channels are Dante transmit channels.
/// With Dante out on, song audio goes to DVS channels 1–2 (left, right) and timecode to channel 3,
/// all on the one device, so the three stay sample-locked. Receivers subscribe to them in Dante
/// Controller. DVS picks the network port itself; Understudy only watches that the preferred port
/// has a link.
public enum DanteOut {
    /// First of the two music channels (0-based): left on DVS 1, right on DVS 2.
    public static let musicChannel = 0
    /// Timecode on DVS 3 (0-based 2).
    public static let timecodeChannel = 2
    public static let channelsNeeded = 3

    public struct Device: Equatable, Sendable {
        public var uid: String
        public var name: String
        public var channels: Int
        /// Core Audio model UID; DVS's driver reports `AUDINATE-DVS-MODEL-ID`.
        public var model: String
        public init(uid: String, name: String, channels: Int, model: String = "") {
            self.uid = uid
            self.name = name
            self.channels = channels
            self.model = model
        }
    }

    /// DVS's model UID, from its Core Audio driver (DvsAudioPlugIn).
    public static let modelID = "AUDINATE-DVS-MODEL-ID"

    /// Dante Virtual Soundcard among the Mac's output devices: by its driver's model ID, else a
    /// device named for it, else any other Dante device. (DVS sets the device's name at run time.)
    public static func soundcard(in devices: [Device]) -> Device? {
        func name(_ d: Device) -> String { d.name.lowercased() }
        return devices.first { $0.model.uppercased().contains(modelID) }
            ?? devices.first { name($0).contains("dante virtual soundcard") }
            ?? devices.first { name($0) == "dvs" || name($0).hasPrefix("dvs ") }
            ?? devices.first { name($0).contains("dante") }
    }

    public enum Status: Equatable, Sendable {
        case off
        /// Sending: DVS found with enough channels, and the preferred port (if any) has a link.
        case sending(device: String, port: String?)
        /// DVS isn't running or isn't installed.
        case noSoundcard
        /// DVS is set to fewer than three transmit channels.
        case tooFewChannels(device: String, channels: Int)
        /// Sending, but the preferred network port has no link.
        case portDown(device: String, port: String)

        /// Audio is going to DVS (even if the chosen port looks down).
        public var isRouted: Bool {
            switch self {
            case .sending, .portDown: return true
            default: return false
            }
        }

        public var isProblem: Bool {
            switch self {
            case .off, .sending: return false
            default: return true
            }
        }

        public var message: String {
            switch self {
            case .off:
                return "Dante out is off."
            case .sending(let device, let port):
                return "Sending to \(device): left and right on 1–2, timecode on 3" + (port.map { " · \($0)" } ?? "") + "."
            case .noSoundcard:
                return "Dante Virtual Soundcard isn't running. Start it (and press Start in DVS); song audio and LTC use the outputs set below until then."
            case .tooFewChannels(let device, let channels):
                return "\(device) has \(channels) channel\(channels == 1 ? "" : "s"); Dante out needs 3. Set DVS to 4 or more channels, then restart it."
            case .portDown(let device, let port):
                return "Sending to \(device), but \(port) has no link. Check the Dante network cable, and that DVS uses this port."
            }
        }
    }

    /// The state of Dante out. `port` is the preferred port's display name (nil = any), and
    /// `portLinked` whether it has a link.
    public static func status(enabled: Bool, soundcard: Device?, port: String?, portLinked: Bool) -> Status {
        guard enabled else { return .off }
        guard let soundcard else { return .noSoundcard }
        guard soundcard.channels >= channelsNeeded else {
            return .tooFewChannels(device: soundcard.name, channels: soundcard.channels)
        }
        if let port, !portLinked { return .portDown(device: soundcard.name, port: port) }
        return .sending(device: soundcard.name, port: port)
    }
}

/// Dev Record: where the songs' own timecode goes when LTC out is off.
public enum DevTimecodeOut {
    /// The song-audio device's channel after the music pair (0-based: 2 for music on 0–1), when
    /// recording from the timeline with LTC out off and the device has that channel; else nil.
    public static func channel(recordingFromTimeline: Bool, ltcOutSet: Bool, musicChannel: Int, deviceChannels: Int) -> Int? {
        guard recordingFromTimeline, !ltcOutSet else { return nil }
        let channel = musicChannel + 2
        return deviceChannels > channel ? channel : nil
    }
}
