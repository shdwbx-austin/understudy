import Foundation
import Network
import UnderstudyCore

/// Listens for OSC on a UDP port and hands each message to `onMessage` on the main actor.
@MainActor
final class OSCServer {
    private var listener: NWListener?
    private(set) var port: Int?
    /// Last error, for Settings (nil when listening fine).
    private(set) var problem: String?
    var onMessage: ((OSCMessage, String) -> Void)?
    var onState: (() -> Void)?

    func listen(on port: Int) {
        guard port != self.port || listener == nil else { return }
        stop()
        self.port = port
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            problem = "OSC port \(port) isn't valid."
            return
        }
        do {
            let listener = try NWListener(using: .udp, on: nwPort)
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

    init?(host: String, port: Int) {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty,
              let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        connection = NWConnection(host: NWEndpoint.Host(host.trimmingCharacters(in: .whitespaces)), port: p, using: .udp)
        connection.start(queue: .global(qos: .userInitiated))
    }

    func send(_ message: OSCMessage) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: message.encoded(), completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
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

    /// Runs Python 2.7 in the Designer session; returns its return value (a JSON string here).
    static func execute(host: String, script: String) async throws -> Result {
        guard let url = base(host)?.appendingPathComponent("api/session/python/execute") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = D3Push.body(script: script)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "d3", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "Designer answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"])
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
    static func tracks(host: String) async throws -> [String] {
        guard let url = base(host)?.appendingPathComponent("api/session/transport/tracks") else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8))
        struct Reply: Decodable { struct Track: Decodable { var name: String }; var result: [Track]? }
        return try JSONDecoder().decode(Reply.self, from: data).result?.map(\.name) ?? []
    }
}
