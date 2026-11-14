import Darwin
import Foundation
import Network
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

    // MARK: Bonjour

    func startBrowsing() {
        guard browsers.isEmpty else { return }
        for type in Self.serviceTypes {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                for result in results {
                    guard case let .service(name, _, _, _) = result.endpoint else { continue }
                    let discovery = self
                    Self.resolve(result.endpoint) { host in
                        guard let host else { return }
                        Task { @MainActor in await discovery?.check(host, name: name) }
                    }
                }
            }
            browser.start(queue: queue)
            browsers.append(browser)
        }
    }

    /// Opens a throwaway connection to a Bonjour service to learn its IPv4 address.
    private nonisolated static func resolve(_ endpoint: NWEndpoint, done: @escaping @Sendable (String?) -> Void) {
        let params = NWParameters.tcp
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

    // MARK: Subnet scan

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        let networks = Self.localNetworks()
        scannedNetworks = networks.map(\.label)
        let skipping = skip()
        let hosts = networks.flatMap(\.hosts).filter { !skipping.contains($0) }
        let unique = Array(NSOrderedSet(array: hosts)).compactMap { $0 as? String }.prefix(Self.maxHostsPerScan)
        Task { [weak self] in
            await withTaskGroup(of: (String, HyperDeckGreeting?).self) { group in
                var iterator = unique.makeIterator()
                for _ in 0..<Self.parallelProbes {
                    guard let host = iterator.next() else { break }
                    group.addTask { (host, await Self.probe(host)) }
                }
                while let (host, greeting) = await group.next() {
                    if let greeting { self?.add(host: host, name: nil, greeting: greeting) }
                    if let next = iterator.next() {
                        group.addTask { (next, await Self.probe(next)) }
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
        if skip().contains(host) {
            add(host: host, name: name, greeting: nil)
            return
        }
        if let greeting = await Self.probe(host) {
            add(host: host, name: name, greeting: greeting)
        }
    }

    private func add(host: String, name: String?, greeting: HyperDeckGreeting?) {
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
    nonisolated static func probe(_ host: String, timeout: TimeInterval = 0.7) async -> HyperDeckGreeting? {
        await withCheckedContinuation { continuation in
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = 1
            let connection = NWConnection(host: NWEndpoint.Host(host), port: 9993, using: NWParameters(tls: nil, tcp: tcp))
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

    struct LocalNetwork {
        var label: String
        var hosts: [String]
    }

    /// IPv4 subnets on the Mac's active interfaces (Ethernet, Wi-Fi, USB/Thunderbolt adaptors).
    /// Subnets larger than /22 are narrowed to the /24 around the Mac's own address.
    nonisolated static func localNetworks() -> [LocalNetwork] {
        var out: [LocalNetwork] = []
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
            let broadcast = network | ~netmask
            guard broadcast > network + 1 else { continue }
            let hosts = (network + 1 ..< broadcast).map(Self.dotted)
            out.append(LocalNetwork(label: "\(dotted(network))/\(netmask.nonzeroBitCount) · \(name)", hosts: hosts))
        }
        return out
    }

    private nonisolated static func dotted(_ v: UInt32) -> String {
        "\(v >> 24 & 0xFF).\(v >> 16 & 0xFF).\(v >> 8 & 0xFF).\(v & 0xFF)"
    }
}
