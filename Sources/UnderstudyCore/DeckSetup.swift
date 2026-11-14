import Foundation

/// Deck settings a controller can read and change, from Blackmagic's HyperDeck Ethernet Protocol
/// (Dec 2024) and the HyperDeck Extreme HDR manual (Aug 2025).
///
/// Every `configuration:` value applies to the whole deck. Recording resolution and frame rate
/// always follow the input and playback output follows the clip; neither can be set remotely.
public struct DeckParameter: Identifiable, Hashable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case recording = "Recording"
        case input = "Input and reference"
        case managed = "Managed by Understudy"
    }

    /// Protocol name, as in `configuration: <key>: <value>` and the 211 reply.
    public let key: String
    public let label: String
    public let group: Group
    /// Documented values; empty means read-only here.
    public let values: [String]
    /// Changing it can make the deck reboot (`213 deck rebooting`).
    public let rebootsDeck: Bool
    public let help: String?

    public var id: String { key }
    public var isEditable: Bool { group != .managed && !values.isEmpty }

    /// A friendlier name for a protocol value.
    public func label(for value: String) -> String {
        Self.valueLabels[value] ?? value
    }

    public static let all: [DeckParameter] = [
        // Recording
        .init(key: "file format", label: "Codec", group: .recording, values: [
            "QuickTimeProResHQ", "QuickTimeProRes", "QuickTimeProResLT", "QuickTimeProResProxy",
            "QuickTimeDNxHR_HQX", "QuickTimeDNxHR_SQ", "QuickTimeDNxHR_LB",
            "QuickTimeDNxHD220x", "QuickTimeDNxHD145", "QuickTimeDNxHD45",
            "H.265High", "H.265Medium", "H.265Low", "H.265High_422",
            "H.264High", "H.264Medium", "H.264Low", "H.264High10_422",
        ], rebootsDeck: true, help: "Not every deck supports every codec; the deck says if it can't."),
        .init(key: "audio codec", label: "Audio codec", group: .recording, values: ["PCM", "AAC"], rebootsDeck: false, help: nil),
        .init(key: "audio input channels", label: "Audio channels", group: .recording, values: [], rebootsDeck: false, help: nil),
        .init(key: "record cache", label: "Record to cache", group: .recording, values: ["true", "false"], rebootsDeck: false,
              help: "Extreme with the cache SSD installed and formatted."),
        .init(key: "usb spill", label: "Spill over to USB", group: .recording, values: ["true", "false"], rebootsDeck: false, help: nil),
        .init(key: "append timestamp", label: "Time stamp in file names", group: .recording, values: ["true", "false"], rebootsDeck: false, help: nil),
        // Input and reference
        .init(key: "video input", label: "Video input", group: .input, values: ["SDI", "HDMI", "component", "composite"],
              rebootsDeck: true, help: "SDI covers single link up to quad-link 8K. 4xSDI (four separate channels) isn't supported by Understudy."),
        .init(key: "audio input", label: "Audio input", group: .input, values: ["embedded", "XLR", "RCA"], rebootsDeck: false, help: nil),
        .init(key: "reference source", label: "Reference", group: .input, values: ["auto", "input", "external"], rebootsDeck: false,
              help: "External: house reference into Ref In."),
        .init(key: "genlock input resync", label: "Genlock input resync", group: .input, values: ["true", "false"], rebootsDeck: false, help: nil),
        .init(key: "default standard", label: "Default standard", group: .input, values: [], rebootsDeck: false,
              help: "Only a guide when there's no input; recording always follows the input."),
        // Managed by Understudy: shown, never edited here
        .init(key: "timecode input", label: "Timecode input", group: .managed, values: [], rebootsDeck: false,
              help: "Internal while recording continuously; external for record-while-code-runs."),
        .init(key: "timecode preference", label: "Drop-frame", group: .managed, values: [], rebootsDeck: false,
              help: "Matched to show timecode."),
        .init(key: "timecode output", label: "Timecode output", group: .managed, values: [], rebootsDeck: false,
              help: "Clip timecode in Play to code."),
        .init(key: "record trigger", label: "Record trigger", group: .managed, values: [], rebootsDeck: false, help: nil),
        .init(key: "record prefix", label: "File name prefix", group: .managed, values: [], rebootsDeck: false,
              help: "The deck's name in Understudy."),
    ]

    public static func named(_ key: String) -> DeckParameter? { all.first { $0.key == key } }

    static let valueLabels: [String: String] = [
        "QuickTimeProResHQ": "ProRes 422 HQ", "QuickTimeProRes": "ProRes 422", "QuickTimeProResLT": "ProRes 422 LT",
        "QuickTimeProResProxy": "ProRes 422 Proxy",
        "QuickTimeDNxHR_HQX": "DNxHR HQX", "QuickTimeDNxHR_SQ": "DNxHR SQ", "QuickTimeDNxHR_LB": "DNxHR LB",
        "QuickTimeDNxHD220x": "DNxHD 220x", "QuickTimeDNxHD145": "DNxHD 145", "QuickTimeDNxHD45": "DNxHD 45",
        "H.265High": "H.265 High", "H.265Medium": "H.265 Medium", "H.265Low": "H.265 Low", "H.265High_422": "H.265 High 4:2:2",
        "H.264High": "H.264 High", "H.264Medium": "H.264 Medium", "H.264Low": "H.264 Low", "H.264High10_422": "H.264 High 10 4:2:2",
        "true": "On", "false": "Off", "auto": "Auto", "input": "Input", "external": "External",
        "embedded": "Embedded", "internal": "Internal", "preset": "Preset", "clip": "Clip",
        "dropframe": "Drop-frame", "nondropframe": "Non-drop", "default": "Default",
        "timecoderun": "Timecode run", "recordbit": "Record bit", "none": "None", "timeline": "Timeline",
        "4xSDI": "4xSDI (4 channels)",
    ]
}

/// `204 device info:`
public struct DeckDeviceInfo: Equatable, Sendable {
    public var model: String?
    public var name: String?
    public var softwareVersion: String?
    public var protocolVersion: String?
    public var uniqueID: String?
    public var slotCount: Int?

    public init(fields: [String: String]) {
        model = fields["model"]
        name = fields["name"]
        softwareVersion = fields["software version"]
        protocolVersion = fields["protocol version"]
        uniqueID = fields["unique id"]
        slotCount = fields["slot count"].flatMap { Int($0) }
    }
}

/// `202 slot info:` / async `502 slot info:`
public struct DeckSlotInfo: Equatable, Sendable, Identifiable {
    public var slotID: Int
    public var name: String?
    public var status: String
    public var volumeName: String?
    /// Seconds of recording left at the current format.
    public var recordingTime: Int?
    public var remainingBytes: Int64?
    public var totalBytes: Int64?

    public var id: Int { slotID }
    public var isMounted: Bool { status == "mounted" }

    public init?(fields: [String: String]) {
        guard let id = fields["slot id"].flatMap({ Int($0) }) else { return nil }
        slotID = id
        name = fields["slot name"] ?? fields["device name"]
        status = fields["status"] ?? "unknown"
        volumeName = fields["volume name"].flatMap { $0.isEmpty ? nil : $0 }
        recordingTime = fields["recording time"].flatMap { Int($0) }
        remainingBytes = fields["remaining size"].flatMap { Int64($0) }
        totalBytes = fields["total size"].flatMap { Int64($0) }
    }

    /// Fraction of the disk used, if sizes are known.
    public var usedFraction: Double? {
        guard let total = totalBytes, total > 0, let remaining = remainingBytes else { return nil }
        return 1 - Double(remaining) / Double(total)
    }

    /// "1 h 23 min" style recording time left.
    public var recordingTimeText: String? {
        guard let s = recordingTime else { return nil }
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }
}

public enum DeckSetupCommand {
    public static let readConfiguration = "configuration"
    public static let deviceInfo = "device info"
    public static func slotInfo(_ id: Int) -> String { "slot info: slot id: \(id)" }
    public static let identify = "identify: enable: true"
    /// Separate from the transport notify, so a deck without these notifications still reports transport.
    public static let notifySetup = "notify: configuration: true slot: true"

    public static func set(_ key: String, _ value: String) -> String { "configuration: \(key): \(value)" }
}

/// Settings that differ between decks, by parameter key, with each deck's value.
/// Only editable parameters count (managed ones are set by Understudy anyway).
public func deckSettingMismatches(_ configs: [Int: [String: String]]) -> [String: [Int: String]] {
    var out: [String: [Int: String]] = [:]
    for parameter in DeckParameter.all where parameter.group != .managed {
        var values: [Int: String] = [:]
        for (deck, config) in configs {
            if let v = config[parameter.key] { values[deck] = v }
        }
        if Set(values.values).count > 1 { out[parameter.key] = values }
    }
    return out
}
