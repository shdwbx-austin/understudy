import Foundation

/// File names for recordings, from a template such as `{deck}_{artist}_{date}_{time}`.
/// The deck adds its own take counter (`_0001`) after the name.
///
/// Tokens: `{deck}` deck name, `{n}` deck number, `{artist}`, `{show}` (setlist or project),
/// `{date}` 2026-11-15, `{day}` Sun, `{time}` 2015 (24 h, hours and minutes), `{seconds}` 201530,
/// `{year}` `{month}` `{dom}`. Anything else is kept as typed. Characters a deck can't take become
/// `_`, runs of `_` collapse, and an empty token takes its separator with it.
public struct RecordNaming: Codable, Equatable, Sendable {
    public var template: String
    public var artist: String

    public static let defaultTemplate = "{deck}_{artist}_{date}_{time}"
    public static let tokens = ["{deck}", "{n}", "{artist}", "{show}", "{date}", "{day}", "{time}", "{seconds}"]
    /// HyperDecks take long names, but keep room for the counter and extension.
    public static let maxLength = 60

    public init(template: String = RecordNaming.defaultTemplate, artist: String = "") {
        self.template = template
        self.artist = artist
    }

    public func name(deck: String, number: Int, show: String = "", at date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        func two(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
        let weekday = calendar.shortWeekdaySymbols[max(0, min(6, (c.weekday ?? 1) - 1))]
        let values: [String: String] = [
            "{deck}": deck, "{n}": String(number), "{artist}": artist, "{show}": show,
            "{date}": "\(c.year ?? 0)-\(two(c.month))-\(two(c.day))",
            "{day}": weekday,
            "{time}": two(c.hour) + two(c.minute),
            "{seconds}": two(c.hour) + two(c.minute) + two(c.second),
            "{year}": String(c.year ?? 0), "{month}": two(c.month), "{dom}": two(c.day),
        ]
        var out = template.isEmpty ? Self.defaultTemplate : template
        for (token, value) in values {
            out = out.replacingOccurrences(of: token, with: value, options: .caseInsensitive)
        }
        return Self.sanitized(out)
    }

    /// Letters, digits, `-` and `_` only; spaces and the rest become `_`; no doubled or edge separators.
    public static func sanitized(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            let keep = CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "-" || scalar == "_"
            let ch: Character = keep ? Character(scalar) : "_"
            if ch == "_", out.last == "_" || out.last == "-" { continue }
            if ch == "-", out.last == "-" { continue }
            if ch == "-", out.last == "_" { out.removeLast() }
            out.append(ch)
        }
        out = String(out.trimmingCharacters(in: CharacterSet(charactersIn: "_-")).prefix(maxLength))
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return out.isEmpty ? "understudy" : out
    }
}
