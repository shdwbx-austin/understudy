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
    /// The deck's configuration (`211`), kept current by `511` notifications.
    @Published private(set) var config: [String: String] = [:]
    @Published private(set) var deviceInfo: DeckDeviceInfo?
    @Published private(set) var slots: [DeckSlotInfo] = []
    /// Stop was pressed while this deck was offline: tell it to stop when it's back.
    var owesStop = false
    /// Has connected at least once to the current address, so a drop now is a fault.
    @Published private(set) var everConnected = false

    /// Was connected to this address and isn't any more.
    var isLost: Bool { everConnected && !isConnected }
    /// Recording time left across mounted media, in seconds.
    var mediaSecondsLeft: Int? { MediaTime.secondsLeft(slots) }

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
        slots = []
        config = [:]
        deviceInfo = nil
        pollInFlight = false
        everConnected = false   // a new address starts clean
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

    /// Deliberate disconnect (slot switched off or emptied): not a fault.
    func disconnect() {
        client?.disconnect()
        client = nil
        connection = .disconnected
        everConnected = false
    }

    private func handleState(_ state: HyperDeckClient.State) {
        connection = state
        guard state == .connected else { return }
        everConnected = true
        lastError = nil
        send(HyperDeckCommand.remoteOverride)
        send(HyperDeckCommand.notify)
        sendQuietly(DeckSetupCommand.notifySetup)
        refreshTransport { [weak self] in self?.onReady?() }
        refreshClips()
        refreshSetup()
    }

    private func handleAsync(_ response: HyperDeckResponse) {
        if response.code == 500, let m = response.fields["model"] { model = m }
        switch response.code {
        case 511:
            config.merge(response.fields) { _, new in new }
            return
        case 502:
            if let slot = DeckSlotInfo(fields: response.fields) { mergeSlot(slot) }
            return
        default:
            break
        }
        if response.fields["status"] != nil || response.fields["display timecode"] != nil {
            mergeTransport(response.fields)
        }
    }

    // MARK: Setup

    /// Reads configuration, device info and every media slot.
    func refreshSetup() {
        sendQuietly(DeckSetupCommand.readConfiguration) { [weak self] r in
            if r.code == 211 { self?.config = r.fields }
        }
        sendQuietly(DeckSetupCommand.deviceInfo) { [weak self] r in
            guard let self, r.code == 204 else { return }
            self.deviceInfo = DeckDeviceInfo(fields: r.fields)
            self.refreshSlots()
        }
    }

    /// Re-reads every media slot (recording time left changes as the deck records).
    func refreshSlots() {
        guard isConnected else { return }
        for id in 1...max(1, deviceInfo?.slotCount ?? 2) {
            sendQuietly(DeckSetupCommand.slotInfo(id)) { [weak self] r in
                if r.code == 202, let slot = DeckSlotInfo(fields: r.fields) { self?.mergeSlot(slot) }
            }
        }
    }

    private func mergeSlot(_ slot: DeckSlotInfo) {
        if let i = slots.firstIndex(where: { $0.slotID == slot.slotID }) { slots[i] = slot } else { slots.append(slot) }
        slots.sort { $0.slotID < $1.slotID }
    }

    /// Sets one configuration value. `done` gets nil on success, or what went wrong.
    func apply(_ key: String, _ value: String, done: @escaping (String?) -> Void) {
        guard client != nil else { done("Not connected."); return }
        request(DeckSetupCommand.set(key, value)) { [weak self] r, _, _ in
            guard let self else { return }
            if r.isSuccess {
                self.config[key] = value
                done(nil)
            } else if r.code == 213 {
                done(nil)   // rebooting to apply it; the client reconnects and re-reads
            } else {
                done(r.hint ?? "The deck didn't accept \(key): \(value) (\(r.code) \(r.text)).")
            }
        }
    }

    /// Flashes the deck's front-panel button so it can be found in the rack.
    func identify() { sendQuietly(DeckSetupCommand.identify) }

    /// Every command goes through here. A reply that arrives after this deck was re-pointed at
    /// another address (or disconnected) is delivered as "connection lost", so nothing from the
    /// old deck can update this one's state.
    private func request(_ command: String, _ done: @escaping HyperDeckClient.Completion) {
        guard let current = client else {
            let now = HostClock.now()
            done(HyperDeckResponse(code: HyperDeckClient.connectionLostCode, text: "not connected"), now, now)
            return
        }
        current.send(command) { [weak self, weak current] response, sentAt, receivedAt in
            let live = current != nil && self?.client === current
            done(live ? response : HyperDeckResponse(code: HyperDeckClient.connectionLostCode, text: "connection replaced"),
                 sentAt, receivedAt)
        }
    }

    /// For optional commands: a deck that doesn't know one shouldn't show an error.
    private func sendQuietly(_ command: String, then: ((HyperDeckResponse) -> Void)? = nil) {
        request(command) { response, _, _ in then?(response) }
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
        request(command) { [weak self] response, _, _ in
            // A dropped link is shown by the connection state, not as a command error.
            if response.isError, response.code != HyperDeckClient.connectionLostCode {
                self?.lastError = response.hint ?? "\(command) → \(response.code) \(response.text)"
            }
            then?(response)
        }
    }

    func refreshTransport(_ done: (() -> Void)? = nil) {
        request(HyperDeckCommand.transportInfo) { [weak self] response, _, _ in
            if response.isSuccess { self?.mergeTransport(response.fields) }
            done?()
        }
    }

    func refreshClips(_ done: (() -> Void)? = nil) {
        request(HyperDeckCommand.clipsGet) { [weak self] response, _, _ in
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
        request(HyperDeckCommand.gotoClip(id: clipID, frame: frame)) { [weak self] response, _, _ in
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
        guard !pollInFlight, client != nil else { return }
        pollInFlight = true
        request(HyperDeckCommand.transportInfo) { [weak self] response, sentAt, receivedAt in
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
