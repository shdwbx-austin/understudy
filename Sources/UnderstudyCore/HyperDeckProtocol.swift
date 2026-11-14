import Foundation

/// One response from a HyperDeck (TCP 9993). Codes 1xx = failure, 2xx = success, 5xx = asynchronous.
public struct HyperDeckResponse: Equatable, Sendable {
    public var code: Int
    public var text: String
    public var fields: [String: String]
    public var lines: [String]

    public init(code: Int, text: String, fields: [String: String] = [:], lines: [String] = []) {
        self.code = code
        self.text = text
        self.fields = fields
        self.lines = lines
    }

    public var isAsync: Bool { (500...599).contains(code) }
    public var isError: Bool { (100...199).contains(code) }
    public var isSuccess: Bool { (200...299).contains(code) }
}

/// Incremental parser. Works on bytes because Swift treats "\r\n" as a single Character.
public struct HyperDeckResponseParser: Sendable {
    private var buffer: [UInt8] = []
    private var pending: HyperDeckResponse?

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [HyperDeckResponse] {
        buffer.append(contentsOf: bytes)
        var out: [HyperDeckResponse] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineBytes = Array(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if lineBytes.last == 0x0D { lineBytes.removeLast() }
            let line = String(decoding: lineBytes, as: UTF8.self)

            if var p = pending {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append(p)
                    pending = nil
                } else {
                    p.lines.append(line)
                    if let r = line.range(of: ": ") {
                        let key = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                        p.fields[key] = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    }
                    pending = p
                }
                continue
            }

            guard line.count >= 3, let code = Int(line.prefix(3)) else { continue }
            var text = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if text.hasSuffix(":") {
                text.removeLast()
                pending = HyperDeckResponse(code: code, text: text)
            } else {
                out.append(HyperDeckResponse(code: code, text: text))
            }
        }
        return out
    }
}

public enum HyperDeckCommand {
    public static let ping = "ping"
    public static let remoteOverride = "remote: override: true"
    public static let notify = "notify: transport: true display timecode: true"
    public static let transportInfo = "transport info"
    public static let clipsGet = "clips get: version: 2"
    public static let stop = "stop"
    public static let playSingleClip = "play: single clip: true"
    public static let timecodeInputExternal = "configuration: timecode input: external"
    /// Deck stamps recordings from its own clock, independent of LTC.
    public static let timecodeInputInternal = "configuration: timecode input: internal"
    public static let record = "record"
    public static let timecodeOutputClip = "configuration: timecode output: clip"

    public static func preview(_ enable: Bool) -> String { "preview: enable: \(enable)" }

    /// Whether the deck's own timecode counts drop-frame (fractional rates only).
    public static func timecodePreference(dropFrame: Bool) -> String {
        "configuration: timecode preference: \(dropFrame ? "dropframe" : "nondropframe")"
    }

    public static func recordTrigger(timecodeRun: Bool) -> String {
        "configuration: record trigger: \(timecodeRun ? "timecoderun" : "none")"
    }

    public static func recordPrefix(_ name: String) -> String {
        let safe = name.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" }
        return "configuration: record prefix: \(String(safe).isEmpty ? "understudy" : String(safe))"
    }

    /// Go to clip `id`, offset `frame` frames from its start.
    public static func gotoClip(id: Int, frame: Int) -> String { "goto: clip id: \(id) clip: \(max(0, frame))" }
    public static func gotoClipStart(id: Int) -> String { "goto: clip id: \(id)" }
    public static func gotoFrameInClip(_ frame: Int) -> String { "goto: clip: \(max(0, frame))" }
}

public enum TransportStatus: String, Sendable {
    case preview, stopped, play, forward, rewind, jog, shuttle, record, unknown
}

public struct TransportInfo: Equatable, Sendable {
    public var status: TransportStatus = .unknown
    public var clipID: Int?
    public var displayTimecode: Timecode?
    public var timecode: Timecode?
    public var videoFormat: String?
    public var inputVideoFormat: String?
    public var referenceLocked: Bool?

    public init() {}

    /// Merges a 208/508 transport block, or any async block carrying `display timecode`.
    public mutating func merge(_ fields: [String: String]) {
        if let s = fields["status"] { status = TransportStatus(rawValue: s) ?? .unknown }
        if let c = fields["clip id"] { clipID = Int(c) }
        if let d = fields["display timecode"] { displayTimecode = Timecode(d) }
        if let t = fields["timecode"] { timecode = Timecode(t) }
        if let v = fields["video format"], v != "none" { videoFormat = v }
        if let v = fields["input video format"], v != "none" { inputVideoFormat = v }
        if let r = fields["reference locked"] { referenceLocked = r == "true" }
    }
}

public struct DeckClip: Equatable, Sendable, Identifiable {
    public var id: Int
    public var start: Timecode
    public var duration: Timecode
    public var name: String

    public init(id: Int, start: Timecode, duration: Timecode, name: String) {
        self.id = id
        self.start = start
        self.duration = duration
        self.name = name
    }

    /// Parses `clips get` (v1: `id: name start duration`, v2/v3: `id: start duration in out name`).
    public static func parse(_ response: HyperDeckResponse) -> [DeckClip] {
        response.lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":"),
                  let id = Int(line[..<colon].trimmingCharacters(in: .whitespaces))
            else { return nil }
            let tokens = line[line.index(after: colon)...].split(separator: " ").map(String.init)
            var codes: [Timecode] = []
            var nameParts: [String] = []
            for t in tokens {
                if let tc = Timecode(t) { codes.append(tc) } else { nameParts.append(t) }
            }
            guard codes.count >= 2 else { return nil }
            return DeckClip(id: id, start: codes[0], duration: codes[1], name: nameParts.joined(separator: " "))
        }
    }
}
