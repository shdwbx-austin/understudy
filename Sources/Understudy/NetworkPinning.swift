import Darwin
import Foundation
import Network
import UnderstudyCore

/// This Mac's network ports as they are now, and pinning connections to one of them.
enum NetworkPorts {
    /// Every interface with its link state and IPv4 addresses, named as macOS names them.
    /// Includes ports with no address (so a chosen port that lost its address is reported as such).
    static func states() -> [NetworkPortState] {
        let names = DeckDiscovery.portNames()
        var order: [String] = []
        var link: [String: Bool] = [:]
        var addresses: [String: [IPv4Subnet]] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let name = String(cString: ifa.ifa_name)
            if link[name] == nil { order.append(name) }
            let flags = Int32(ifa.ifa_flags)
            link[name] = (link[name] ?? false) || (flags & IFF_UP != 0 && flags & IFF_RUNNING != 0)
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), let mask = ifa.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            addresses[name, default: []].append(IPv4Subnet(address: ip, mask: m))
        }
        return order.map { name in
            NetworkPortState(bsd: name, name: names[name] ?? name, hasLink: link[name] ?? false, addresses: addresses[name] ?? [])
        }
    }

    /// Where traffic for a chosen port (nil = automatic) goes right now.
    static func route(_ chosen: String?) -> PortRoute {
        PortRoute.resolve(chosen, ports: states())
    }

    /// Network.framework's handle for a port by BSD name. There's no public initialiser by name,
    /// but a scoped address ("0.0.0.0%en8") carries the interface. nil when there's no such port.
    static func nwInterface(_ bsd: String) -> NWInterface? {
        IPv4Address("0.0.0.0%\(bsd)")?.interface
    }
}

extension NWParameters {
    /// Pins these parameters to the chosen port when it's usable (`requiredInterface`, which binds
    /// IPv4 and IPv6 sockets to it like IP_BOUND_IF / IPV6_BOUND_IF). Returns the route in effect.
    @discardableResult
    func pin(to chosen: String?) -> PortRoute {
        var route = NetworkPorts.route(chosen)
        if let bsd = route.interface {
            if let iface = NetworkPorts.nwInterface(bsd) {
                requiredInterface = iface
            } else {
                route = .fallback(bsd: bsd, problem: .missing)
            }
        }
        return route
    }
}

/// HTTP over a connection pinned to one port, for disguise's API when a port is chosen
/// (URLSession has no public way to choose the interface).
enum PinnedHTTP {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// One request; the server closes the connection after answering (`Connection: close`).
    static func send(_ url: URL, method: String = "GET", headers: [(String, String)] = [], body: Data? = nil,
                     interface bsd: String, timeout: TimeInterval) async throws -> HTTP1.Response {
        guard let host = url.host, !host.isEmpty else { throw URLError(.badURL) }
        let tls = url.scheme?.lowercased() == "https"
        let port = url.port ?? (tls ? 443 : 80)
        let params = NWParameters(tls: tls ? NWProtocolTLS.Options() : nil, tcp: NWProtocolTCP.Options())
        let route = params.pin(to: bsd)
        guard route.interface != nil else { throw Failure(message: route.summary) }
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query { path += "?" + query }
        let request = HTTP1.request(method: method, host: url.port.map { "\(host):\($0)" } ?? host, path: path,
                                    headers: headers, body: body)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 80, using: params)
        let queue = DispatchQueue(label: "understudy.http")
        let state = HTTPState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<HTTP1.Response, Error>) in
                @Sendable func finish(_ result: Result<HTTP1.Response, Error>) {
                    guard !state.done else { return }
                    state.done = true
                    connection.cancel()
                    c.resume(with: result)
                }
                @Sendable func receive() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                        if let data { state.buffer.append(data) }
                        switch HTTP1.parse(state.buffer, closed: complete || error != nil) {
                        case .complete(let response): finish(.success(response))
                        case .invalid: finish(.failure(error ?? Failure(message: "Not an HTTP answer from \(host)")))
                        case .incomplete: receive()
                        }
                    }
                }
                connection.stateUpdateHandler = { s in
                    switch s {
                    case .ready:
                        connection.send(content: request, completion: .contentProcessed { error in
                            if let error { finish(.failure(error)) }
                        })
                        receive()
                    case .waiting(let error), .failed(let error):
                        finish(.failure(Failure(message: "\(error.localizedDescription) (via \(route.summary))")))
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(URLError(.timedOut))) }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Touched only on the connection's serial queue.
    private final class HTTPState: @unchecked Sendable {
        var done = false
        var buffer = Data()
    }
}
