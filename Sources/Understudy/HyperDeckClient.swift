import Foundation
import Network
import UnderstudyCore

/// One TCP session to a HyperDeck on port 9993. Responses to commands arrive in order,
/// so completions are matched FIFO; 5xx messages are routed to `onAsync`.
/// All socket state lives on `queue`; callbacks are delivered on the main actor, in arrival order.
final class HyperDeckClient: @unchecked Sendable {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    typealias Completion = @MainActor @Sendable (_ response: HyperDeckResponse, _ sentAt: Double, _ receivedAt: Double) -> Void

    let host: String
    /// Set these before `connect()`; they are read on `queue`.
    var onState: (@MainActor @Sendable (State) -> Void)?
    var onAsync: (@MainActor @Sendable (HyperDeckResponse) -> Void)?

    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var parser = HyperDeckResponseParser()
    private var pending: [(sentAt: Double, completion: Completion?)] = []
    private var stopped = true

    init(host: String) {
        self.host = host
        queue = DispatchQueue(label: "understudy.hyperdeck.\(host)", qos: .userInteractive)
    }

    func connect() {
        queue.async { [self] in
            stopped = false
            open()
        }
    }

    func disconnect() {
        queue.async { [self] in
            stopped = true
            connection?.cancel()
            connection = nil
            failPending()
            emit(.disconnected)
        }
    }

    func send(_ command: String, completion: Completion? = nil) {
        queue.async { [self] in
            guard let connection else {
                if let completion {
                    let now = HostClock.now()
                    Self.onMain { completion(HyperDeckResponse(code: 120, text: "not connected"), now, now) }
                }
                return
            }
            pending.append((HostClock.now(), completion))
            connection.send(content: Data((command + "\r\n").utf8), completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Queue-confined

    private func open() {
        guard connection == nil, !host.isEmpty else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 3
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: 9993,
            using: NWParameters(tls: nil, tcp: tcp)
        )
        self.connection = connection
        parser = HyperDeckResponseParser()
        emit(.connecting)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.emit(.connected)
                self.receive(on: connection)
            case .failed(let error), .waiting(let error):
                self.drop(connection, reason: error.localizedDescription)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.handle([UInt8](data)) }
            if isComplete || error != nil {
                self.drop(connection, reason: error?.localizedDescription ?? "Closed by deck")
                return
            }
            self.receive(on: connection)
        }
    }

    private func handle(_ bytes: [UInt8]) {
        let now = HostClock.now()
        for response in parser.feed(bytes) {
            if response.isAsync {
                if let onAsync { Self.onMain { onAsync(response) } }
                continue
            }
            guard !pending.isEmpty else { continue }
            let item = pending.removeFirst()
            if let completion = item.completion {
                let sentAt = item.sentAt
                Self.onMain { completion(response, sentAt, now) }
            }
        }
    }

    private func drop(_ dropped: NWConnection, reason: String) {
        guard dropped === connection else { return }
        dropped.cancel()
        connection = nil
        failPending()
        emit(.failed(reason))
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.stopped, self.connection == nil else { return }
            self.open()
        }
    }

    private func failPending() {
        let items = pending
        pending = []
        let now = HostClock.now()
        for item in items {
            if let completion = item.completion {
                let sentAt = item.sentAt
                Self.onMain { completion(HyperDeckResponse(code: 120, text: "connection lost"), sentAt, now) }
            }
        }
    }

    private func emit(_ state: State) {
        if let onState { Self.onMain { onState(state) } }
    }

    /// The main queue is FIFO, so state changes, async messages and completions reach the
    /// main actor in the order the deck sent them. Separate `Task`s don't guarantee that.
    private static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
}
