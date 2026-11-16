import Foundation

// MARK: - OSC 1.0 messages

public enum OSCArgument: Equatable, Sendable {
    case int(Int32)
    case float(Float)
    case string(String)
    case bool(Bool)

    /// As text, for commands that take a name or number either way.
    public var text: String {
        switch self {
        case .int(let i): return String(i)
        case .float(let f): return f == f.rounded() ? String(Int(f)) : String(f)
        case .string(let s): return s
        case .bool(let b): return b ? "1" : "0"
        }
    }

    public var number: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .float(let f): return Double(f)
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        }
    }
}

public struct OSCMessage: Equatable, Sendable {
    public var address: String
    public var arguments: [OSCArgument]

    public init(_ address: String, _ arguments: [OSCArgument] = []) {
        self.address = address
        self.arguments = arguments
    }

    public func encoded() -> Data {
        var data = Data()
        func pad(_ d: inout Data) { while d.count % 4 != 0 { d.append(0) } }
        func string(_ s: String) { data.append(contentsOf: Array(s.utf8)); data.append(0); pad(&data) }
        string(address)
        var tags = ","
        for a in arguments {
            switch a {
            case .int: tags += "i"
            case .float: tags += "f"
            case .string: tags += "s"
            case .bool(let b): tags += b ? "T" : "F"
            }
        }
        string(tags)
        for a in arguments {
            switch a {
            case .int(let i): withUnsafeBytes(of: i.bigEndian) { data.append(contentsOf: $0) }
            case .float(let f): withUnsafeBytes(of: f.bitPattern.bigEndian) { data.append(contentsOf: $0) }
            case .string(let s): string(s)
            case .bool: break
            }
        }
        return data
    }

    /// Decodes one message, or every message in a bundle (Companion and some consoles send bundles).
    public static func decode(_ data: Data) -> [OSCMessage] {
        let bytes = [UInt8](data)
        if bytes.starts(with: Array("#bundle".utf8) + [0]) {
            var out: [OSCMessage] = []
            var i = 16                       // "#bundle\0" + 8-byte time tag
            while i + 4 <= bytes.count {
                let size = Int(UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3]))
                i += 4
                guard size > 0, i + size <= bytes.count else { break }
                out += decode(Data(bytes[i..<i + size]))
                i += size
            }
            return out
        }
        return message(bytes).map { [$0] } ?? []
    }

    private static func message(_ b: [UInt8]) -> OSCMessage? {
        var i = 0
        func string() -> String? {
            guard let end = b[i...].firstIndex(of: 0) else { return nil }
            let s = String(decoding: b[i..<end], as: UTF8.self)
            i = (end + 4) & ~3
            return s
        }
        func u32() -> UInt32? {
            guard i + 4 <= b.count else { return nil }
            defer { i += 4 }
            return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
        }
        guard !b.isEmpty, b[0] == UInt8(ascii: "/"), let address = string() else { return nil }
        guard i < b.count, let tags = string(), tags.hasPrefix(",") else { return OSCMessage(address) }
        var args: [OSCArgument] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i": guard let v = u32() else { return nil }; args.append(.int(Int32(bitPattern: v)))
            case "f": guard let v = u32() else { return nil }; args.append(.float(Float(bitPattern: v)))
            case "s", "S": guard let s = string() else { return nil }; args.append(.string(s))
            case "T": args.append(.bool(true))
            case "F": args.append(.bool(false))
            case "N", "I": break
            case "h", "t", "d":     // 64-bit: skip (or read a double)
                guard let hi = u32(), let lo = u32() else { return nil }
                if tag == "d" { args.append(.float(Float(Double(bitPattern: UInt64(hi) << 32 | UInt64(lo))))) }
                else if tag == "h" { args.append(.int(Int32(truncatingIfNeeded: Int64(bitPattern: UInt64(hi) << 32 | UInt64(lo))))) }
            case "b":
                guard let n = u32() else { return nil }
                i = (i + Int(n) + 3) & ~3
            default: return nil
            }
        }
        return OSCMessage(address, args)
    }
}

// MARK: - Remote control

/// What a Stream Deck (via Companion), an MA3 or anything else that sends OSC can ask for.
public enum RemoteCommand: Equatable, Sendable {
    case play, pause, togglePlay, stop
    case nextSong, previousSong, gotoSong(Int)
    /// Add a marker at the playhead; nil kind = the last one used.
    case addMarker(MarkerKind?, label: String)
    case nextMarker, previousMarker
    case mode(String)
}

/// Maps OSC addresses to commands. Addresses are `/understudy/...` (the prefix is optional, so
/// `/play` works too). A button that sends 1 on press and 0 on release acts on press only.
///
///     /understudy/play  /pause  /toggle  /stop
///     /understudy/song/next  /song/prev  /song <n>
///     /understudy/marker                      add (last type used)
///     /understudy/marker <type> [label]       type = 1–7 or a name (choreo … automation, lx)
///     /understudy/marker/<type> [label]
///     /understudy/marker/next  /marker/prev
///     /understudy/mode <stop|record|play|timeline>
public enum RemoteControl {
    public static let prefix = "understudy"

    public static func command(for m: OSCMessage, types: MarkerTypes = .defaults) -> RemoteCommand? {
        var parts = m.address.lowercased().split(separator: "/").map(String.init)
        if parts.first == prefix { parts.removeFirst() }
        guard let head = parts.first else { return nil }
        let args = m.arguments
        // Buttons send 1 on press and 0 on release (or nothing): act on press only. A lone number
        // is always a button value; types and labels come as strings or in the address.
        let pressValue = args.count == 1 ? args[0].number : nil
        if let v = pressValue, v == 0 { return nil }
        func string(_ i: Int) -> String? {
            guard args.indices.contains(i), case .string(let s) = args[i] else { return nil }
            return s
        }
        switch (head, parts.count) {
        case ("play", 1): return .play
        case ("pause", 1): return .pause
        case ("toggle", 1), ("playpause", 1): return .togglePlay
        case ("stop", 1): return .stop
        case ("next", 1): return .nextSong
        case ("prev", 1), ("previous", 1): return .previousSong
        case ("song", _):
            if parts.count > 1 { return parts[1] == "next" ? .nextSong : (parts[1].hasPrefix("prev") ? .previousSong : nil) }
            guard let n = args.first?.number, n >= 1 else { return nil }
            return .gotoSong(Int(n))   // /song 3 is a song number, not a button value
        case ("marker", _):
            if parts.count > 1 {
                switch parts[1] {
                case "next": return .nextMarker
                case "prev", "previous": return .previousMarker
                default:
                    guard let kind = types.kind(forArgument: parts[1]) else { return nil }
                    return .addMarker(kind, label: string(0) ?? "")
                }
            }
            // /marker [type] [label]: a string that names a type sets it; any other string is the label.
            if let first = string(0) {
                if let kind = types.kind(forArgument: first) { return .addMarker(kind, label: string(1) ?? "") }
                return .addMarker(nil, label: first)
            }
            return .addMarker(nil, label: "")
        case ("mode", _):
            let name = parts.count > 1 ? parts[1] : (args.first?.text ?? "")
            return ["stop", "record", "play", "timeline"].contains(name.lowercased()) ? .mode(name.lowercased()) : nil
        default:
            return nil
        }
    }
}
