import Foundation
import Network
import os
import UnderstudyCore

/// Listens for OSC on a UDP port and hands each message to `onMessage` on the main actor.
@MainActor
final class OSCServer {
    private var listener: NWListener?
    private(set) var port: Int?
    /// The port chosen in Settings (nil = every port), and where the listener actually is.
    private(set) var interface: String?
    private(set) var route: PortRoute = .automatic
    /// Last error, for Settings (nil when listening fine).
    private(set) var problem: String?
    var onMessage: ((OSCMessage, String) -> Void)?
    var onState: (() -> Void)?

    /// Listens on `port`, on one network port when `interface` is set and usable (else on all).
    func listen(on port: Int, interface: String? = nil) {
        let route = NetworkPorts.route(interface)
        guard port != self.port || interface != self.interface || route != self.route || listener == nil else { return }
        stop()
        self.port = port
        self.interface = interface
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            problem = "OSC port \(port) isn't valid."
            return
        }
        do {
            let params = NWParameters.udp
            self.route = params.pin(to: interface)
            let listener = try NWListener(using: params, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .failed(let error):
                        self.problem = "OSC port \(port): \(error.localizedDescription)"
                    case .ready:
                        self.problem = nil
                    default: break
                    }
                    self.onState?()
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            problem = "OSC port \(port): \(error.localizedDescription)"
            onState?()
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        interface = nil
        route = .automatic
        problem = nil
    }

    private func accept(_ connection: NWConnection) {
        let from: String
        if case .hostPort(let host, _) = connection.endpoint { from = "\(host)" } else { from = "?" }
        connection.start(queue: .main)
        receive(on: connection, from: from)
    }

    private func receive(on connection: NWConnection, from: String) {
        connection.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let data {
                    for message in OSCMessage.decode(data) { self.onMessage?(message, from) }
                }
                if error == nil { self.receive(on: connection, from: from) } else { connection.cancel() }
            }
        }
    }
}

/// Sends OSC to one host over UDP.
final class OSCSender: @unchecked Sendable {
    private let connection: NWConnection
    /// The network port the messages leave from (or the system's routing).
    let route: PortRoute

    /// `interface`: the network port (BSD name) to send from; nil = the system's routing.
    init?(host: String, port: Int, interface: String? = nil) {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty,
              let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        let params = NWParameters.udp
        route = params.pin(to: interface)
        connection = NWConnection(host: NWEndpoint.Host(host.trimmingCharacters(in: .whitespaces)), port: p, using: params)
        connection.stateUpdateHandler = { [problem] state in
            switch state {
            case .waiting(let error), .failed(let error): problem.withLock { $0 = error }
            case .ready: problem.withLock { $0 = nil }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private let queue = DispatchQueue(label: "understudy.osc.send", qos: .userInitiated)
    /// Why the connection can't send (no route from the chosen port, network down), if it can't.
    private let problem = OSAllocatedUnfairLock<NWError?>(initialState: nil)

    /// Fails at once when there's no way to the host (a UDP connection that can't send waits
    /// rather than failing), and after `timeout` if the send never goes out.
    func send(_ message: OSCMessage, timeout: TimeInterval = 2) async throws {
        if let error = problem.withLock({ $0 }) { throw error }
        let done = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            @Sendable func finish(_ error: Error?) {
                guard done.withLock({ let was = $0; $0 = true; return !was }) else { return }
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
            connection.send(content: message.encoded(), completion: .contentProcessed { finish($0) })
            queue.asyncAfter(deadline: .now() + timeout) { [problem] in
                finish(problem.withLock { $0 } ?? URLError(.timedOut))
            }
        }
    }

    deinit { connection.cancel() }
}

/// disguise Designer's session API (HTTP, port 80).
enum D3Client {
    struct Result: Decodable {
        struct Status: Decodable { var code: Int?; var message: String? }
        var status: Status?
        var returnValue: String?
        var pythonLog: String?
        var d3Log: String?
    }

    static func base(_ host: String) -> URL? {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return nil }
        return URL(string: h.hasPrefix("http") ? h : "http://\(h)")
    }

    /// One request to Designer: through URLSession, or over a connection pinned to the chosen
    /// network port (`interface`) when it's usable. Returns the status code and body.
    static func load(_ url: URL, method: String = "GET", contentType: String? = nil, body: Data? = nil,
                     timeout: TimeInterval, interface: String?) async throws -> (status: Int, data: Data) {
        if let bsd = NetworkPorts.route(interface).interface {
            var headers: [(String, String)] = [("Accept", "application/json")]
            if let contentType { headers.append(("Content-Type", contentType)) }
            let response = try await PinnedHTTP.send(url, method: method, headers: headers, body: body,
                                                     interface: bsd, timeout: timeout)
            return (response.status, response.body)
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    /// Runs Python 2.7 in the Designer session; returns its return value (a JSON string here).
    static func execute(host: String, script: String, interface: String? = nil) async throws -> Result {
        guard let url = base(host)?.appendingPathComponent("api/session/python/execute") else { throw URLError(.badURL) }
        let (status, data) = try await load(url, method: "POST", contentType: "application/json",
                                            body: D3Push.body(script: script), timeout: 15, interface: interface)
        guard status == 200 else {
            throw NSError(domain: "d3", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "Designer answered HTTP \(status)"])
        }
        return try JSONDecoder().decode(Result.self, from: data)
    }

    /// The script's return value as a dictionary (JSON, or a JSON string holding JSON).
    static func resultDictionary(_ value: String?) -> [String: Any]? {
        guard let value, let data = value.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return nil }
        if let dict = decoded as? [String: Any] { return dict }
        if let text = decoded as? String { return resultDictionary(text) }
        return nil
    }

    /// Track names in the open project.
    static func tracks(host: String, interface: String? = nil) async throws -> [String] {
        guard let url = base(host)?.appendingPathComponent("api/session/transport/tracks") else { throw URLError(.badURL) }
        let (_, data) = try await load(url, timeout: 8, interface: interface)
        struct Reply: Decodable { struct Track: Decodable { var name: String }; var result: [Track]? }
        return try JSONDecoder().decode(Reply.self, from: data).result?.map(\.name) ?? []
    }
}
