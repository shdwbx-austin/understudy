import Foundation

/// The kinds of network traffic Understudy sends or receives, each of which can be pinned to one
/// network port (so a show Mac with a show network, Dante, internet and NDI ports sends each
/// protocol out of the right one).
public enum NetworkTraffic: String, CaseIterable, Codable, Sendable, Identifiable {
    /// HyperDeck control (TCP 9993), deck discovery (Bonjour and the subnet scan) and FTP clip copies.
    case decks
    /// OSC to grandMA3 (Send to grandMA3).
    case ma3
    /// disguise Designer's HTTP API (marker push, track list).
    case d3
    /// NDI out (the viewer's "Understudy ME n" sources) and NDI in (the recorder's finder and receiver).
    case ndi
    /// OSC control in (Companion, MA3, …): the UDP port Understudy listens on.
    case oscIn

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .decks: return "Deck control"
        case .ma3: return "grandMA3"
        case .d3: return "disguise"
        case .ndi: return "NDI"
        case .oscIn: return "OSC in"
        }
    }

    public var detail: String {
        switch self {
        case .decks: return "HyperDeck control (TCP 9993), finding decks (Bonjour and the subnet scan) and FTP copies."
        case .ma3: return "OSC sent to the grandMA3 when markers are sent."
        case .d3: return "HTTP to Designer when markers are pushed or tracks fetched."
        case .ndi: return "NDI out from the viewer and NDI in for the recorder. Takes effect next time Understudy opens."
        case .oscIn: return "Only OSC arriving on this port is accepted."
        }
    }
}

/// The chosen port (BSD name, e.g. "en8") for each kind of traffic but deck control, which uses
/// `AppSettings.discoveryInterface` (it already chose where decks are looked for). nil = automatic
/// (the system's routing table).
public struct NetworkInterfaceSettings: Codable, Equatable, Sendable {
    public var ma3: String?
    public var d3: String?
    public var ndi: String?
    public var oscIn: String?

    public init(ma3: String? = nil, d3: String? = nil, ndi: String? = nil, oscIn: String? = nil) {
        self.ma3 = ma3
        self.d3 = d3
        self.ndi = ndi
        self.oscIn = oscIn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ma3 = (try? c.decodeIfPresent(String.self, forKey: .ma3)) ?? nil
        d3 = (try? c.decodeIfPresent(String.self, forKey: .d3)) ?? nil
        ndi = (try? c.decodeIfPresent(String.self, forKey: .ndi)) ?? nil
        oscIn = (try? c.decodeIfPresent(String.self, forKey: .oscIn)) ?? nil
    }
}

extension AppSettings {
    /// The port chosen for a kind of traffic (nil = automatic).
    public func interface(for traffic: NetworkTraffic) -> String? {
        switch traffic {
        case .decks: return discoveryInterface
        case .ma3: return interfaces.ma3
        case .d3: return interfaces.d3
        case .ndi: return interfaces.ndi
        case .oscIn: return interfaces.oscIn
        }
    }

    public mutating func setInterface(_ bsd: String?, for traffic: NetworkTraffic) {
        let value = bsd.flatMap { $0.isEmpty ? nil : $0 }
        switch traffic {
        case .decks: discoveryInterface = value
        case .ma3: interfaces.ma3 = value
        case .d3: interfaces.d3 = value
        case .ndi: interfaces.ndi = value
        case .oscIn: interfaces.oscIn = value
        }
    }

    /// The addresses a kind of traffic is sent to, for checking they're on the chosen port's subnet.
    public func targets(for traffic: NetworkTraffic) -> [String] {
        switch traffic {
        case .decks: return decks.filter(\.enabled).compactMap(\.networkHost)
        case .ma3: return ma3Host.isEmpty ? [] : [ma3Host]
        case .d3: return d3Host.isEmpty ? [] : [d3Host]
        case .ndi, .oscIn: return []
        }
    }
}

// MARK: - IPv4

/// One IPv4 address on a port, with its netmask.
public struct IPv4Subnet: Hashable, Sendable {
    public var address: UInt32
    public var mask: UInt32

    public init(address: UInt32, mask: UInt32) {
        self.address = address
        self.mask = mask
    }

    public init?(_ address: String, mask: String) {
        guard let a = Self.parse(address), let m = Self.parse(mask) else { return nil }
        self.init(address: a, mask: m)
    }

    public var network: UInt32 { address & mask }
    public var prefixLength: Int { mask.nonzeroBitCount }
    /// e.g. "10.0.0.0/24".
    public var cidr: String { "\(Self.dotted(network))/\(prefixLength)" }
    public var dottedAddress: String { Self.dotted(address) }
    /// 169.254.x.x: self-assigned (a Dante port with no DHCP has only this).
    public var isLinkLocal: Bool { address >> 16 == 0xA9FE }
    public var isLoopback: Bool { address >> 24 == 127 }

    public func contains(_ ip: UInt32) -> Bool { ip & mask == network }

    public static func parse(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), let n = UInt32(part), n < 256 else { return nil }
            value = value << 8 | n
        }
        return value
    }

    public static func dotted(_ v: UInt32) -> String {
        "\(v >> 24 & 0xFF).\(v >> 16 & 0xFF).\(v >> 8 & 0xFF).\(v & 0xFF)"
    }

    /// The IPv4 address in a target as typed in Settings: "10.0.0.5", " 10.0.0.5 ", "10.0.0.5:8000",
    /// "http://10.0.0.5/". nil for host names, which can't be checked against a subnet.
    public static func address(inTarget target: String) -> UInt32? {
        var s = target.trimmingCharacters(in: .whitespaces)
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        return parse(s)
    }
}

// MARK: - Ports

/// A network port as it is now: whether it's up with a link, and its IPv4 addresses.
public struct NetworkPortState: Hashable, Sendable, Identifiable {
    /// BSD name, e.g. "en8".
    public var bsd: String
    /// What macOS calls it, e.g. "Thunderbolt Ethernet Slot 1".
    public var name: String
    /// Up and running (a cable in, Wi-Fi joined).
    public var hasLink: Bool
    public var addresses: [IPv4Subnet]

    public init(bsd: String, name: String, hasLink: Bool, addresses: [IPv4Subnet]) {
        self.bsd = bsd
        self.name = name
        self.hasLink = hasLink
        self.addresses = addresses
    }

    public var id: String { bsd }

    /// "Thunderbolt Ethernet (en8)".
    public var label: String { name.contains("(\(bsd))") ? name : "\(name) (\(bsd))" }

    /// The address traffic on this port comes from: a DHCP or manual one over a self-assigned one.
    public var bindAddress: IPv4Subnet? {
        addresses.first { !$0.isLinkLocal } ?? addresses.first
    }

    /// "10.0.0.5/24", "10.0.0.5/24, 169.254.3.4/16", "no link", "no IPv4 address".
    public var summary: String {
        if !hasLink { return "no link" }
        if addresses.isEmpty { return "no IPv4 address" }
        return addresses.map { "\($0.dottedAddress)/\($0.prefixLength)" }.joined(separator: ", ")
    }

    /// Whether `ip` is on one of this port's subnets.
    public func reaches(_ ip: UInt32) -> Bool { addresses.contains { $0.contains(ip) } }
}

/// Why a chosen port can't be used right now.
public enum PortProblem: Hashable, Sendable {
    /// No port by that name on this Mac (an adaptor unplugged, or settings from another Mac).
    case missing
    case noLink
    case noIPv4

    public var text: String {
        switch self {
        case .missing: return "isn't on this Mac"
        case .noLink: return "has no link"
        case .noIPv4: return "has no IPv4 address"
        }
    }
}

/// Where one kind of traffic actually goes.
public enum PortRoute: Hashable, Sendable {
    /// No port chosen: the system's routing table decides.
    case automatic
    /// Pinned to a port (Network.framework `requiredInterface`, curl `--interface`), sent from `address`.
    case pinned(bsd: String, address: String)
    /// A port is chosen but can't be used, so the system's routing decides until it can.
    case fallback(bsd: String, problem: PortProblem)

    /// A chosen port is honoured only while it's up with an IPv4 address; until then traffic
    /// follows the system's routing (and the status line says so) rather than stopping the show.
    public static func resolve(_ chosen: String?, ports: [NetworkPortState]) -> PortRoute {
        guard let chosen, !chosen.isEmpty else { return .automatic }
        guard let port = ports.first(where: { $0.bsd == chosen }) else { return .fallback(bsd: chosen, problem: .missing) }
        guard port.hasLink else { return .fallback(bsd: chosen, problem: .noLink) }
        guard let address = port.bindAddress else { return .fallback(bsd: chosen, problem: .noIPv4) }
        return .pinned(bsd: chosen, address: address.dottedAddress)
    }

    /// The port to pin sockets to, when pinned.
    public var interface: String? {
        if case .pinned(let bsd, _) = self { return bsd }
        return nil
    }

    public var isProblem: Bool {
        if case .fallback = self { return true }
        return false
    }

    /// For status lines: "en8 · 10.0.0.5", "system routing", "en8 has no link: using system routing".
    public var summary: String {
        switch self {
        case .automatic: return "system routing"
        case .pinned(let bsd, let address): return "\(bsd) · \(address)"
        case .fallback(let bsd, let problem): return "\(bsd) \(problem.text): using system routing"
        }
    }
}

/// Something worth telling the user about a chosen port.
public enum PortWarning: Hashable, Sendable {
    case problem(bsd: String, PortProblem)
    /// A target address isn't on any of the port's subnets, so it's reached only if that port has a router to it.
    case offSubnet(target: String, bsd: String, subnets: [String])

    public var text: String {
        switch self {
        case .problem(let bsd, let problem):
            return "\(bsd) \(problem.text), so this traffic uses the system's routing until it does."
        case .offSubnet(let target, let bsd, let subnets):
            let on = subnets.isEmpty ? "" : " (\(subnets.joined(separator: ", ")))"
            return "\(target) isn't on \(bsd)'s subnet\(on). It's reached only if that network has a router to it."
        }
    }

    /// Warnings for a choice: the port's own state, then each IPv4 target that's off its subnets.
    public static func check(_ chosen: String?, ports: [NetworkPortState], targets: [String]) -> [PortWarning] {
        guard let chosen, !chosen.isEmpty else { return [] }
        switch PortRoute.resolve(chosen, ports: ports) {
        case .fallback(_, let problem):
            return [.problem(bsd: chosen, problem)]
        case .automatic:
            return []
        case .pinned:
            guard let port = ports.first(where: { $0.bsd == chosen }) else { return [] }
            var out: [PortWarning] = []
            var seen: Set<String> = []
            for target in targets {
                let t = target.trimmingCharacters(in: .whitespaces)
                guard let ip = IPv4Subnet.address(inTarget: t), !port.reaches(ip), seen.insert(t).inserted else { continue }
                out.append(.offSubnet(target: t, bsd: chosen, subnets: port.addresses.map(\.cidr)))
            }
            return out
        }
    }
}

// MARK: - NDI

/// NDI picks its network adapters from `ndi-config.v1.json` (`"ndi": {"adapters": {"allowed": [IPs]}}`),
/// read when the library starts, from `NDI_CONFIG_DIR` if set, else `~/.ndi`. Understudy writes its
/// own copy of the user's config with the adapter list added and points `NDI_CONFIG_DIR` at it for
/// its own process, so NDI Access Manager's settings and other NDI apps are left alone.
public enum NDIAdapterConfig {
    public static let fileName = "ndi-config.v1.json"

    /// `existing` (the user's config, or nil) with `ndi.adapters.allowed` set to `addresses`.
    /// Everything else in it is kept. An unreadable config is replaced by one with only the adapters.
    public static func merged(_ existing: Data?, allowed addresses: [String]) -> Data {
        var root = existing.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var ndi = root["ndi"] as? [String: Any] ?? [:]
        var adapters = ndi["adapters"] as? [String: Any] ?? [:]
        adapters["allowed"] = addresses
        ndi["adapters"] = adapters
        root["ndi"] = ndi
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// The adapter list in a config (for checking what NDI was started with).
    public static func allowed(in data: Data) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ndi = root["ndi"] as? [String: Any],
              let adapters = ndi["adapters"] as? [String: Any] else { return nil }
        return adapters["allowed"] as? [String]
    }
}

// MARK: - curl

public enum CurlInterface {
    /// curl arguments that pin a transfer (control and data connections) to a port by name.
    /// `if!` makes curl treat it as an interface name, never a host name or address.
    public static func arguments(_ bsd: String?) -> [String] {
        guard let bsd, !bsd.isEmpty else { return [] }
        return ["--interface", "if!\(bsd)"]
    }
}

// MARK: - HTTP/1.1

/// Just enough HTTP/1.1 to talk to Designer's API over a connection pinned to one port
/// (URLSession can't be told which interface to use).
public enum HTTP1 {
    public struct Response: Equatable, Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data
    }

    public enum Parse: Equatable, Sendable {
        case incomplete
        case complete(Response)
        case invalid
    }

    public static func request(method: String, host: String, path: String,
                               headers: [(String, String)] = [], body: Data? = nil) -> Data {
        var head = "\(method) \(path.isEmpty ? "/" : path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        if let body { head += "Content-Length: \(body.count)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }

    /// Parses what has arrived so far. `closed`: the server has closed the connection (which ends
    /// a body with neither a length nor chunks).
    public static func parse(_ data: Data, closed: Bool) -> Parse {
        let bytes = [UInt8](data)
        guard let headEnd = find([13, 10, 13, 10], in: bytes, from: 0) else { return closed ? .invalid : .incomplete }
        let head = String(decoding: bytes[0..<headEnd], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let status = Int(statusLine[1]) else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let bodyStart = headEnd + 4
        let rest = Array(bytes[bodyStart...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch dechunk(rest) {
            case .some(.some(let body)): return .complete(Response(status: status, headers: headers, body: Data(body)))
            case .some(.none): return .invalid
            case .none: return closed ? .invalid : .incomplete
            }
        }
        if let length = headers["content-length"].flatMap({ Int($0) }) {
            if rest.count >= length { return .complete(Response(status: status, headers: headers, body: Data(rest.prefix(length)))) }
            return closed ? .invalid : .incomplete
        }
        if status == 204 || status == 304 || (100..<200).contains(status) {
            return .complete(Response(status: status, headers: headers, body: Data()))
        }
        return closed ? .complete(Response(status: status, headers: headers, body: Data(rest))) : .incomplete
    }

    /// nil: more data needed; .some(nil): malformed; .some(body): complete.
    private static func dechunk(_ bytes: [UInt8]) -> [UInt8]?? {
        var body: [UInt8] = []
        var i = 0
        while true {
            guard let lineEnd = find([13, 10], in: bytes, from: i) else { return nil }
            let sizeText = String(decoding: bytes[i..<lineEnd], as: UTF8.self)
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { return .some(nil) }
            i = lineEnd + 2
            if size == 0 {
                // Trailers (if any) end with an empty line.
                var j = i
                while true {
                    guard let end = find([13, 10], in: bytes, from: j) else { return nil }
                    if end == j { return .some(body) }
                    j = end + 2
                }
            }
            guard bytes.count >= i + size + 2 else { return nil }
            body += bytes[i..<(i + size)]
            guard bytes[i + size] == 13, bytes[i + size + 1] == 10 else { return .some(nil) }
            i += size + 2
        }
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= needle.count, start <= bytes.count - needle.count else { return nil }
        var i = start
        while i <= bytes.count - needle.count {
            if bytes[i] == needle[0], Array(bytes[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }
}
