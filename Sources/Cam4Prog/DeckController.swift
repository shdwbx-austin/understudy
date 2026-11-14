import Foundation
import Cam4ProgCore

@MainActor
final class DeckController: ObservableObject, Identifiable {
    let id: Int

    @Published private(set) var connection: HyperDeckClient.State = .disconnected
    @Published private(set) var model: String?
    @Published private(set) var transport = TransportInfo()
    @Published private(set) var clips: [DeckClip] = []
    @Published var lastError: String?
    @Published var chase = DeckChaseState()
    /// Smoothed deck-minus-LTC error in LTC frames (positive = deck ahead).
    @Published var smoothedError: Double?

    /// Called when a recording on this deck ends (status left `record`).
    var onRecordingFinished: (() -> Void)?

    private var client: HyperDeckClient?
    private var pollInFlight = false
    /// Newest drift reading not yet consumed by the chase engine.
    private var freshError: Double?

    init(id: Int) { self.id = id }

    var isConnected: Bool { connection == .connected }

    // MARK: Connection

    func connect(host: String) {
        client?.disconnect()
        client = nil
        model = nil
        transport = TransportInfo()
        clips = []
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            connection = .disconnected
            return
        }
        let client = HyperDeckClient(host: trimmed)
        // Ignore anything still arriving from a previous client (e.g. its `.disconnected`
        // landing after the new one has connected).
        client.onState = { [weak self, weak client] state in
            guard let self, let client, self.client === client else { return }
            self.handleState(state)
        }
        client.onAsync = { [weak self, weak client] response in
            guard let self, let client, self.client === client else { return }
            self.handleAsync(response)
        }
        self.client = client
        client.connect()
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        connection = .disconnected
    }

    private func handleState(_ state: HyperDeckClient.State) {
        connection = state
        guard state == .connected else { return }
        lastError = nil
        send(HyperDeckCommand.remoteOverride)
        send(HyperDeckCommand.notify)
        refreshTransport()
        refreshClips()
    }

    private func handleAsync(_ response: HyperDeckResponse) {
        if response.code == 500, let m = response.fields["model"] { model = m }
        let wasRecording = transport.status == .record
        if response.fields["status"] != nil || response.fields["display timecode"] != nil {
            transport.merge(response.fields)
        }
        if wasRecording && transport.status != .record {
            onRecordingFinished?()
        }
    }

    // MARK: Commands

    func send(_ command: String, then: ((HyperDeckResponse) -> Void)? = nil) {
        client?.send(command) { [weak self] response, _, _ in
            if response.isError { self?.lastError = "\(command) → \(response.code) \(response.text)" }
            then?(response)
        }
    }

    func refreshTransport() {
        client?.send(HyperDeckCommand.transportInfo) { [weak self] response, _, _ in
            if response.isSuccess { self?.transport.merge(response.fields) }
        }
    }

    func refreshClips(_ done: (() -> Void)? = nil) {
        client?.send(HyperDeckCommand.clipsGet) { [weak self] response, _, _ in
            if response.isSuccess { self?.clips = DeckClip.parse(response) }
            done?()
        }
    }

    /// REC ARM: park in preview (live input passes through) and record whenever show code runs.
    func arm(prefix: String, nativeTrigger: Bool) {
        resetChase()
        send(HyperDeckCommand.stop)
        send(HyperDeckCommand.timecodeInputExternal)
        send(HyperDeckCommand.recordPrefix(prefix))
        send(HyperDeckCommand.recordTrigger(timecodeRun: nativeTrigger))
        send(HyperDeckCommand.preview(true))
    }

    func record() { send("record") }

    /// STOP: halt transport, disarm, leave the deck in preview so the live feed passes through.
    func stopAll() {
        resetChase()
        send(HyperDeckCommand.stop)
        send(HyperDeckCommand.recordTrigger(timecodeRun: false))
        send(HyperDeckCommand.preview(true)) { [weak self] _ in self?.refreshClips() }
    }

    /// PLAY TC: disarm, switch the output to playback and report clip timecode.
    func enterPlayback(_ done: @escaping () -> Void) {
        resetChase()
        send(HyperDeckCommand.stop)
        send(HyperDeckCommand.recordTrigger(timecodeRun: false))
        send(HyperDeckCommand.timecodeOutputClip)
        send(HyperDeckCommand.preview(false))
        refreshClips(done)
    }

    func cue(clipID: Int, frame: Int) {
        send(HyperDeckCommand.stop)
        client?.send(HyperDeckCommand.gotoClip(id: clipID, frame: frame)) { [weak self] response, _, _ in
            guard let self, response.isError else { return }
            // Older firmware: one parameter per goto.
            self.send(HyperDeckCommand.gotoClipStart(id: clipID))
            self.send(HyperDeckCommand.gotoFrameInClip(frame))
        }
    }

    func play() { send(HyperDeckCommand.playSingleClip) }
    func stopTransport() { send(HyperDeckCommand.stop) }

    func resetChase() {
        chase = DeckChaseState()
        freshError = nil
        smoothedError = nil
    }

    // MARK: Drift monitoring

    /// Polls transport and hands back the deck timecode with the host time it was valid at.
    func poll(_ result: @escaping (Timecode, Double) -> Void) {
        guard !pollInFlight, let client else { return }
        pollInFlight = true
        client.send(HyperDeckCommand.transportInfo) { [weak self] response, sentAt, receivedAt in
            guard let self else { return }
            self.pollInFlight = false
            guard response.isSuccess else { return }
            self.transport.merge(response.fields)
            if let tc = self.transport.displayTimecode {
                result(tc, (sentAt + receivedAt) / 2)
            }
        }
    }

    func noteDrift(_ error: Double) {
        freshError = error
        smoothedError = smoothedError.map { $0 * 0.7 + error * 0.3 } ?? error
    }

    func takeFreshError() -> Double? {
        defer { freshError = nil }
        return freshError
    }

    // MARK: Helpers

    func clip(takeOffset: Int) -> DeckClip? {
        let index = clips.count - 1 - takeOffset
        return clips.indices.contains(index) ? clips[index] : nil
    }

    func videoRate(dropFrame: Bool) -> FrameRate? {
        guard let format = transport.videoFormat ?? transport.inputVideoFormat else { return nil }
        return FrameRate.fromVideoFormat(format, dropFrame: dropFrame)
    }
}
