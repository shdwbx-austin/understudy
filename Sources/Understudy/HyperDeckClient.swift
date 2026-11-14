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
    /// The deck said `120 connection failed` (too many clients) on this connection.
    private var refused = false
    /// Liveness: a reply overdue this long means the link is dead (pulled cable, deck froze),
    /// which TCP alone can take minutes to notice. Idle connections are pinged to keep it honest.
    private static let replyTimeout = 6.0
    private static let pingInterval = 2.0
    private var watchdog: DispatchSourceTimer?
    private var lastSent = 0.0
    /// The deck has spoken on this connection. A hung deck's network stack can still accept the
    /// TCP connection, so the socket opening alone doesn't count as connected: the deck's
    /// greeting does.
    private var greeted = false
    private var openedAt = 0.0

    /// Internal failures, never confused with the deck's own `120 connection failed`.
    static let connectionLostCode = 190

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
            stopWatchdog()
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
                    Self.onMain { completion(HyperDeckResponse(code: Self.connectionLostCode, text: "not connected"), now, now) }
                }
                return
            }
            write(command, on: connection, completion: completion)
        }
    }

    private func write(_ command: String, on connection: NWConnection, completion: Completion?) {
        lastSent = HostClock.now()
        pending.append((lastSent, completion))
        connection.send(content: Data((command + "\r\n").utf8), completion: .contentProcessed { _ in })
    }

    private func startWatchdog(_ connection: NWConnection) {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self, weak connection] in
            guard let self, let connection, connection === self.connection else { return }
            let now = HostClock.now()
            if !self.greeted {
                if now - self.openedAt > Self.replyTimeout { self.drop(connection, reason: "The deck isn't answering") }
            } else if let oldest = self.pending.first?.sentAt, now - oldest > Self.replyTimeout {
                self.drop(connection, reason: "No reply from the deck")
            } else if self.pending.isEmpty, now - self.lastSent > Self.pingInterval {
                self.write("ping", on: connection, completion: nil)
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
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
        refused = false
        emit(.connecting)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                // Still `.connecting` until the deck sends its greeting (see `handle`).
                self.greeted = false
                self.openedAt = HostClock.now()
                self.lastSent = self.openedAt
                self.startWatchdog(connection)
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
            if !greeted, response.code != 120 {
                greeted = true
                emit(.connected)
            }
            if response.code == 120 {
                // Refused at connect; the deck hangs up next. Not a reply to any command.
                refused = true
                continue
            }
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
        stopWatchdog()
        dropped.cancel()
        connection = nil
        failPending()
        let refusedNow = refused
        emit(.failed(refusedNow ? HyperDeckResponse(code: 120, text: "").hint ?? reason : reason))
        guard !stopped else { return }
        // A deck at its client limit won't free up in two seconds: back off.
        queue.asyncAfter(deadline: .now() + (refusedNow ? 10 : 2)) { [weak self] in
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
                Self.onMain { completion(HyperDeckResponse(code: Self.connectionLostCode, text: "connection lost"), sentAt, now) }
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
