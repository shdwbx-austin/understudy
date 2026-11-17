import Darwin
import Foundation
import Network
import SystemConfiguration
import UnderstudyCore

/// A HyperDeck found on the network.
struct FoundDeck: Identifiable, Hashable, Sendable {
    /// IPv4 address.
    var host: String
    /// Bonjour name, when the deck advertises one.
    var name: String?
    var model: String?
    var protocolVersion: String?
    /// Answered as a HyperDeck but refused another client.
    var busy = false

    var id: String { host }
    var title: String { name ?? model ?? "HyperDeck" }
}

/// Finds HyperDecks two ways:
/// - Bonjour, for decks that advertise themselves;
/// - a scan of the Mac's local subnets on TCP 9993, keeping only hosts that greet like a HyperDeck.
///
/// Hosts already connected to a deck slot are never probed, so a deck in use never gets a second client.
/// This Mac's own addresses are never listed: anything answering on them (an emulator, a test
/// server) runs on this Mac and would otherwise appear once per network interface.
@MainActor
final class DeckDiscovery: ObservableObject {
    @Published private(set) var found: [FoundDeck] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScanned: Date?
    /// e.g. "172.16.16.0/24" — what the last scan covered.
    @Published private(set) var scannedNetworks: [String] = []

    static let serviceTypes = ["_hyperdeck_ctrl._tcp", "_blackmagic._tcp"]
    private static let maxHostsPerScan = 1024
    private static let parallelProbes = 64

    private var browsers: [NWBrowser] = []
    private let queue = DispatchQueue(label: "understudy.discovery")
    /// Hosts never to probe (connected deck slots).
    var skip: () -> Set<String> = { [] }
    /// Interface to look on (BSD name), nil for all.
    var interface: () -> String? = { nil }

    /// Only hosts on the chosen interface's network are kept.
    private func onChosenNetwork(_ host: String) -> Bool {
        guard let name = interface() else { return true }
        guard let ip = Self.parse(host) else { return false }
        return Self.localNetworks().contains { $0.interface == name && $0.contains(ip) }
    }

    // MARK: Bonjour

    func stopBrowsing() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
    }

    /// The interface Bonjour browsing was started on (it's restarted when that changes).
    private var browsingOn: String?

    func startBrowsing() {
        guard browsers.isEmpty else { return }
        let chosen = interface()
        browsingOn = chosen
        for type in Self.serviceTypes {
            // Pinned to the deck port when one is chosen, so Bonjour asks only on that network.
            let params = NWParameters.tcp
            params.pin(to: chosen)
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: params)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                for result in results {
                    guard case let .service(name, _, _, _) = result.endpoint else { continue }
                    let discovery = self
                    Self.resolve(result.endpoint, interface: chosen) { host in
                        guard let host else { return }
                        Task { @MainActor in await discovery?.check(host, name: name) }
                    }
                }
            }
            browser.start(queue: queue)
            browsers.append(browser)
        }
    }

    /// After the deck port changes: browse again on the new one, if browsing.
    func restartBrowsingIfNeeded() {
        guard !browsers.isEmpty, browsingOn != interface() else { return }
        stopBrowsing()
        startBrowsing()
    }

    /// Opens a throwaway connection to a Bonjour service to learn its IPv4 address.
    private nonisolated static func resolve(_ endpoint: NWEndpoint, interface: String?, done: @escaping @Sendable (String?) -> Void) {
        let params = NWParameters.tcp
        params.pin(to: interface)
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: params)
        let q = DispatchQueue(label: "understudy.resolve")
        let state = ProbeState()
        @Sendable func finish(_ host: String?) {
            guard !state.done else { return }
            state.done = true
            connection.cancel()
            done(host)
        }
        connection.stateUpdateHandler = { s in
            switch s {
            case .ready:
                if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint,
                   case let .ipv4(address) = host {
                    finish("\(address)".components(separatedBy: "%").first)
                } else {
                    finish(nil)
                }
            case .failed, .waiting, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: q)
        q.asyncAfter(deadline: .now() + 3) { finish(nil) }
    }

    /// Forgets what was found (e.g. after switching interface). Bonjour finds re-arrive.
    func clear() {
        found.removeAll()
        lastScanned = nil
    }

    // MARK: Subnet scan

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        let chosen = interface()
        let networks = Self.localNetworks().filter { chosen == nil || $0.interface == chosen }
        scannedNetworks = networks.map(\.label)
        let skipping = skip().union(Self.ownAddresses())
        let hosts = networks.flatMap(\.hosts).filter { !skipping.contains($0) }
        let unique = Array(NSOrderedSet(array: hosts)).compactMap { $0 as? String }.prefix(Self.maxHostsPerScan)
        Task { [weak self] in
            await withTaskGroup(of: (String, HyperDeckGreeting?).self) { group in
                var iterator = unique.makeIterator()
                for _ in 0..<Self.parallelProbes {
                    guard let host = iterator.next() else { break }
                    group.addTask { (host, await Self.probe(host, interface: chosen)) }
                }
                while let (host, greeting) = await group.next() {
                    if let greeting { self?.add(host: host, name: nil, greeting: greeting) }
                    if let next = iterator.next() {
                        group.addTask { (next, await Self.probe(next, interface: chosen)) }
                    }
                }
            }
            self?.finishScan()
        }
    }

    private func finishScan() {
        isScanning = false
        lastScanned = Date()
    }

    private func check(_ host: String, name: String) async {
        guard onChosenNetwork(host) else { return }
        if skip().contains(host) {
            add(host: host, name: name, greeting: nil)
            return
        }
        if let greeting = await Self.probe(host, interface: interface()) {
            add(host: host, name: name, greeting: greeting)
        }
    }

    private func add(host: String, name: String?, greeting: HyperDeckGreeting?) {
        guard !Self.ownAddresses().contains(host) else { return }
        if let i = found.firstIndex(where: { $0.host == host }) {
            if let name { found[i].name = name }
            if let model = greeting?.model { found[i].model = model }
            if let version = greeting?.protocolVersion { found[i].protocolVersion = version }
            if let greeting { found[i].busy = greeting.busy }
        } else {
            found.append(FoundDeck(
                host: host, name: name, model: greeting?.model,
                protocolVersion: greeting?.protocolVersion, busy: greeting?.busy ?? false
            ))
            found.sort { Self.sortKey($0.host).lexicographicallyPrecedes(Self.sortKey($1.host)) }
        }
    }

    private static func sortKey(_ host: String) -> [Int] {
        host.split(separator: ".").map { Int($0) ?? 0 }
    }

    // MARK: Probing

    /// Shared by a connection's callbacks, which all run on its one serial queue.
    private final class ProbeState: @unchecked Sendable {
        var done = false
        var parser = HyperDeckResponseParser()
    }

    /// Connects to `host`:9993 and reads the greeting. Closed ports fail at once; silent hosts time out.
    /// `interface`: the deck port (BSD name) to probe from; nil = the system's routing.
    nonisolated static func probe(_ host: String, interface: String? = nil, timeout: TimeInterval = 0.7) async -> HyperDeckGreeting? {
        await withCheckedContinuation { continuation in
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = 1
            let params = NWParameters(tls: nil, tcp: tcp)
            params.pin(to: interface)
            let connection = NWConnection(host: NWEndpoint.Host(host), port: 9993, using: params)
            let q = DispatchQueue(label: "understudy.probe")
            let state = ProbeState()

            @Sendable func finish(_ greeting: HyperDeckGreeting?) {
                guard !state.done else { return }
                state.done = true
                connection.cancel()
                continuation.resume(returning: greeting)
            }
            @Sendable func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { data, _, complete, error in
                    if let data {
                        if let first = state.parser.feed([UInt8](data)).first {
                            finish(HyperDeckGreeting.recognise(first))
                            return
                        }
                    }
                    if complete || error != nil { finish(nil) } else { receive() }
                }
            }
            connection.stateUpdateHandler = { s in
                switch s {
                case .ready: receive()
                case .failed, .waiting, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    // MARK: Local networks

    struct LocalNetwork: Identifiable, Hashable {
        /// BSD name, e.g. "en0".
        var interface: String
        /// What macOS calls the port, e.g. "Wi-Fi", "USB 10/100/1000 LAN".
        var displayName: String
        var address: String
        var network: UInt32
        var mask: UInt32

        var id: String { interface }
        var cidr: String { "\(DeckDiscovery.dotted(network))/\(mask.nonzeroBitCount)" }
        var label: String { "\(cidr) · \(displayName)" }
        func contains(_ ip: UInt32) -> Bool { ip & mask == network }

        var hosts: [String] {
            let broadcast = network | ~mask
            guard broadcast > network + 1 else { return [] }
            return (network + 1 ..< broadcast).map(DeckDiscovery.dotted)
        }
    }

    /// A network port the Mac has, for choosing which one Dante is on.
    struct NetworkPort: Identifiable, Hashable {
        let bsd: String
        let name: String
        var id: String { bsd }
        var label: String { name.contains("(\(bsd))") ? name : "\(name) (\(bsd))" }
    }

    /// Every network port macOS knows (Ethernet, Thunderbolt and USB adaptors, Wi-Fi), whether or
    /// not it's plugged in, by name.
    nonisolated static func networkPorts() -> [NetworkPort] {
        portNames().map { NetworkPort(bsd: $0.key, name: $0.value) }
            .sorted { ($0.name, $0.bsd) < ($1.name, $1.bsd) }
    }

    /// Whether a port is up with a link and an IPv4 address (Dante needs one, even a 169.254 one).
    nonisolated static func hasLink(_ bsd: String) -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            if String(cString: ifa.ifa_name) == bsd, flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
               let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                return true
            }
        }
        return false
    }

    /// macOS's names for network ports, by BSD name.
    nonisolated static func portNames() -> [String: String] {
        var names: [String: String] = [:]
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return names }
        for iface in all {
            if let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
               let name = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? {
                names[bsd] = name
            }
        }
        return names
    }

    nonisolated static func parse(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
        return parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3]
    }

    /// IPv4 subnets on the Mac's active interfaces (Ethernet, Wi-Fi, USB/Thunderbolt adaptors).
    /// Subnets larger than /22 are narrowed to the /24 around the Mac's own address.
    nonisolated static func localNetworks() -> [LocalNetwork] {
        var out: [LocalNetwork] = []
        let names = portNames()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.ifa_netmask
            else { continue }
            let name = String(cString: ifa.ifa_name)
            guard !name.hasPrefix("utun"), !name.hasPrefix("awdl"), !name.hasPrefix("llw") else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            var netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if ip >> 16 == 0xA9FE { continue }   // 169.254 link-local
            if netmask.nonzeroBitCount < 22 { netmask = 0xFFFF_FF00 }
            let network = ip & netmask
            guard (network | ~netmask) > network + 1, !out.contains(where: { $0.interface == name }) else { continue }
            out.append(LocalNetwork(
                interface: name, displayName: names[name] ?? name, address: dotted(ip),
                network: network, mask: netmask
            ))
        }
        return out
    }

    /// Every IPv4 address on this Mac, loopback and link-local included.
    nonisolated static func ownAddresses() -> Set<String> {
        var out: Set<String> = ["127.0.0.1"]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            out.insert(dotted(ip))
        }
        return out
    }

    nonisolated static func dotted(_ v: UInt32) -> String {
        "\(v >> 24 & 0xFF).\(v >> 16 & 0xFF).\(v >> 8 & 0xFF).\(v & 0xFF)"
    }
}
