import Foundation
import UnderstudyCore

@MainActor
final class DeckController: ObservableObject, Identifiable {
    let id: Int
    let maps: TakeMapStore

    @Published private(set) var connection: HyperDeckClient.State = .disconnected
    @Published private(set) var model: String?
    @Published private(set) var transport = TransportInfo()
    @Published private(set) var clips: [DeckClip] = []
    @Published var lastError: String?
    @Published var chase = DeckChaseState()
    /// Smoothed deck-minus-LTC error in LTC frames (positive = deck ahead).
    @Published var smoothedError: Double?
    /// Seconds of show code logged against the recording in progress.
    @Published private(set) var loggedSeconds: Double?

    /// Called when a recording on this deck ends (status left `record`).
    var onRecordingFinished: (() -> Void)?
    /// Called after connecting, once the deck's transport state is known.
    var onReady: (() -> Void)?
    /// Called after every clip list refresh.
    var onClipsRefreshed: (() -> Void)?
    /// Log show code against recordings (continuous record mode).
    var buildsTakeMaps = false

    private var client: HyperDeckClient?
    private var pollInFlight = false
    /// Newest drift reading not yet consumed by the chase engine.
    private var freshError: Double?
    private var mapBuilder: TakeMapBuilder?
    private var lastMapSave = 0.0
    /// A real transport status has been seen since launch.
    private var sawStatus = false

    init(id: Int) {
        self.id = id
        maps = TakeMapStore(deckID: id)
    }

    var isConnected: Bool { connection == .connected }
    var isLoggingTake: Bool { mapBuilder != nil }

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
        refreshTransport { [weak self] in self?.onReady?() }
        refreshClips()
    }

    private func handleAsync(_ response: HyperDeckResponse) {
        if response.code == 500, let m = response.fields["model"] { model = m }
        if response.fields["status"] != nil || response.fields["display timecode"] != nil {
            mergeTransport(response.fields)
        }
    }

    /// Every transport update goes through here so record start/stop is never missed,
    /// including across reconnects and app restarts.
    private func mergeTransport(_ fields: [String: String]) {
        let wasRecording = transport.status == .record
        transport.merge(fields)
        guard transport.status != .unknown else { return }
        let isRecording = transport.status == .record
        let firstStatus = !sawStatus
        sawStatus = true
        if isRecording {
            // Keep a live builder through a reconnect; otherwise start (or resume) one.
            if mapBuilder == nil && (!wasRecording || firstStatus) { recordingStarted() }
        } else if wasRecording || mapBuilder != nil || (firstStatus && maps.contents.inProgress != nil) {
            // Stopped, possibly while we were disconnected or not running.
            recordingFinished()
        }
    }

    // MARK: Commands

    func send(_ command: String, then: ((HyperDeckResponse) -> Void)? = nil) {
        client?.send(command) { [weak self] response, _, _ in
            if response.isError {
                self?.lastError = response.hint ?? "\(command) → \(response.code) \(response.text)"
            }
            then?(response)
        }
    }

    func refreshTransport(_ done: (() -> Void)? = nil) {
        client?.send(HyperDeckCommand.transportInfo) { [weak self] response, _, _ in
            if response.isSuccess { self?.mergeTransport(response.fields) }
            done?()
        }
    }

    func refreshClips(_ done: (() -> Void)? = nil) {
        client?.send(HyperDeckCommand.clipsGet) { [weak self] response, _, _ in
            if response.isSuccess, let self {
                self.clips = DeckClip.parse(response)
                self.onClipsRefreshed?()
            }
            done?()
        }
    }

    /// REC. Continuous: start recording now, stamped from the deck's own clock, and keep going
    /// until STOP whatever LTC does. Timecode run: arm the deck's trigger so it records while
    /// show code runs. Either way the deck stays in preview, so the live input passes through.
    func arm(prefix: String, mode: RecordMode, dropFrame: Bool) {
        resetChase()
        send(HyperDeckCommand.stop)
        send(HyperDeckCommand.recordPrefix(prefix))
        switch mode {
        case .continuous:
            send(HyperDeckCommand.recordTrigger(timecodeRun: false))
            send(HyperDeckCommand.timecodeInputInternal)
            // The deck's clock must count the same way as show code (Understudy reads both with the show rate's drop-frame setting).
            send(HyperDeckCommand.timecodePreference(dropFrame: dropFrame))
            send(HyperDeckCommand.preview(true))
            send(HyperDeckCommand.record)
        case .timecodeRun:
            send(HyperDeckCommand.timecodeInputExternal)
            send(HyperDeckCommand.recordTrigger(timecodeRun: true))
            send(HyperDeckCommand.preview(true))
        }
    }

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

    // MARK: Take maps

    private func recordingStarted() {
        // A saved in-progress map means the app restarted mid-take: carry on with it.
        let resume = maps.contents.inProgress
        guard buildsTakeMaps || resume != nil else { return }
        if resume == nil { maps.startRecording(existingClips: clips) }
        mapBuilder = TakeMapBuilder(resuming: resume)
        loggedSeconds = nil
    }

    private func recordingFinished() {
        if mapBuilder != nil || maps.contents.inProgress != nil {
            maps.finishRecording(mapBuilder?.map)
        }
        mapBuilder = nil
        loggedSeconds = nil
        onRecordingFinished?()
    }

    /// One reading while recording: show code and the deck's own timecode at the same instant.
    func logTakeReading(ltcSeconds: Double, deckSeconds: Double, now: Double) {
        guard var builder = mapBuilder else { return }
        builder.add(ltc: ltcSeconds, deck: deckSeconds)
        mapBuilder = builder
        if now - lastMapSave >= 5 {
            lastMapSave = now
            let map = builder.map
            maps.saveInProgress(map)
            loggedSeconds = map.segments.reduce(0) { $0 + ($1.ltcEnd - $1.ltcStart) }
        }
    }

    // MARK: Polling

    /// Polls transport and hands back the deck timecode with the host time it was valid at.
    func poll(_ result: @escaping (Timecode, Double) -> Void) {
        guard !pollInFlight, let client else { return }
        pollInFlight = true
        client.send(HyperDeckCommand.transportInfo) { [weak self] response, sentAt, receivedAt in
            guard let self else { return }
            self.pollInFlight = false
            guard response.isSuccess else { return }
            self.mergeTransport(response.fields)
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
