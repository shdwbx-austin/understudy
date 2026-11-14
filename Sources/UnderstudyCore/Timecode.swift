import Foundation

/// Video / timecode frame rates. Drop-frame variants count labels the SMPTE way.
public enum FrameRate: String, CaseIterable, Codable, Sendable, Identifiable {
    case fps23_976 = "23.976"
    case fps24 = "24"
    case fps25 = "25"
    case fps29_97DF = "29.97 DF"
    case fps29_97 = "29.97 NDF"
    case fps30 = "30"
    case fps50 = "50"
    case fps59_94DF = "59.94 DF"
    case fps59_94 = "59.94 NDF"
    case fps60 = "60"

    public var id: String { rawValue }

    /// Integer label base (frames per labelled second).
    public var nominal: Int {
        switch self {
        case .fps23_976, .fps24: return 24
        case .fps25: return 25
        case .fps29_97DF, .fps29_97, .fps30: return 30
        case .fps50: return 50
        case .fps59_94DF, .fps59_94, .fps60: return 60
        }
    }

    /// Real frames per second.
    public var exact: Double {
        switch self {
        case .fps23_976: return 24000.0 / 1001.0
        case .fps29_97DF, .fps29_97: return 30000.0 / 1001.0
        case .fps59_94DF, .fps59_94: return 60000.0 / 1001.0
        default: return Double(nominal)
        }
    }

    public var isDropFrame: Bool { self == .fps29_97DF || self == .fps59_94DF }
    public var isFractional: Bool { exact != Double(nominal) }

    /// Labels dropped at the start of each minute not divisible by ten.
    var dropPerMinute: Int { isDropFrame ? (nominal == 30 ? 2 : 4) : 0 }

    /// LTC carries at most 30 labels per second; high-frame-rate video runs LTC at half rate.
    public var ltcRate: FrameRate {
        switch self {
        case .fps50: return .fps25
        case .fps59_94DF: return .fps29_97DF
        case .fps59_94: return .fps29_97
        case .fps60: return .fps30
        default: return self
        }
    }

    public var framesPerDay: Int {
        guard isDropFrame else { return nominal * 86_400 }
        return (nominal * 600 - dropPerMinute * 9) * 144
    }

    /// Parses HyperDeck video format strings such as "1080p2997", "2160p59.94", "4Kp5994", "1080i50", "PAL".
    public static func fromVideoFormat(_ format: String, dropFrame: Bool) -> FrameRate? {
        let f = format.lowercased().replacingOccurrences(of: ".", with: "")
        if f.hasPrefix("ntsc") { return dropFrame ? .fps29_97DF : .fps29_97 }
        if f.hasPrefix("pal") { return .fps25 }
        var digits = ""
        var marker: Character?
        for ch in f.reversed() {
            if ch.isNumber { digits.insert(ch, at: digits.startIndex); continue }
            marker = ch
            break
        }
        guard let marker, marker == "p" || marker == "i", !digits.isEmpty else { return nil }
        var rate: FrameRate?
        switch digits {
        case "23976", "2398": rate = .fps23_976
        case "24": rate = .fps24
        case "25": rate = .fps25
        case "2997": rate = dropFrame ? .fps29_97DF : .fps29_97
        case "30": rate = .fps30
        case "50": rate = .fps50
        case "5994": rate = dropFrame ? .fps59_94DF : .fps59_94
        case "60": rate = .fps60
        default: rate = nil
        }
        // Interlaced formats are named by field rate.
        if marker == "i", let r = rate { return r.ltcRate }
        return rate
    }
}

public struct Timecode: Hashable, Codable, Sendable, CustomStringConvertible {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int

    public init(hours: Int, minutes: Int, seconds: Int, frames: Int) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
    }

    /// Accepts `HH:MM:SS:FF`, `HH:MM:SS;FF` or `HH:MM:SS.FF`.
    public init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." })
        guard parts.count == 4,
              let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]), let f = Int(parts[3]),
              h >= 0, h < 100, m >= 0, m < 60, s >= 0, s < 60, f >= 0, f < 100
        else { return nil }
        self.init(hours: h, minutes: m, seconds: s, frames: f)
    }

    /// Protocol form, always colon separated (the HyperDeck protocol expects `HH:MM:SS:FF`).
    public var description: String {
        String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }

    public func display(dropFrame: Bool) -> String {
        String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, dropFrame ? ";" : ":", frames)
    }

    /// Frame count since 00:00:00:00, honouring drop-frame label skipping.
    public func frameIndex(at rate: FrameRate) -> Int {
        let totalMinutes = hours * 60 + minutes
        var index = (hours * 3600 + minutes * 60 + seconds) * rate.nominal + frames
        if rate.isDropFrame {
            index -= rate.dropPerMinute * (totalMinutes - totalMinutes / 10)
        }
        return index
    }

    /// Frame count of a duration (durations are plain counts, never drop-frame).
    public func durationFrames(nominal: Int) -> Int {
        (hours * 3600 + minutes * 60 + seconds) * nominal + frames
    }

    /// Label time in seconds, comparable across rates of the same pulldown family.
    public func seconds(at rate: FrameRate) -> Double {
        Double(frameIndex(at: rate)) / rate.exact
    }

    public init(frameIndex: Int, rate: FrameRate) {
        let day = rate.framesPerDay
        var n = ((frameIndex % day) + day) % day
        let nominal = rate.nominal
        if rate.isDropFrame {
            let drop = rate.dropPerMinute
            let perTen = nominal * 600 - drop * 9
            let perMinute = nominal * 60 - drop
            let tens = n / perTen
            let remainder = n % perTen
            n += drop * 9 * tens
            if remainder > drop {
                n += drop * ((remainder - drop) / perMinute)
            }
        }
        self.init(
            hours: n / (nominal * 3600),
            minutes: (n / (nominal * 60)) % 60,
            seconds: (n / nominal) % 60,
            frames: n % nominal
        )
    }
}
