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
    /// Whether the deck's own timecode counts drop-frame, as it reports (nil if it hasn't said).
    var deckDropFrame: Bool? {
        switch config["timecode preference"] {
        case "dropframe"?: return true
        case "nondropframe"?: return false
        default: return nil
        }
    }

    /// Recording time left across mounted media (the recorder: on its disk), in seconds.
    var mediaSecondsLeft: Int? {
        if isRecorder { return recorderStatus?.health.secondsLeft }
        return MediaTime.secondsLeft(slots)
    }

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

    // MARK: Understudy recorder state

    /// Set when this slot is the Understudy recorder rather than a HyperDeck.
    private(set) var recorder: InternalRecorder?
    @Published private(set) var recorderStatus: InternalRecorder.Status?
    private var recorderTakes: RecorderTakeStore?
    private var recorderSettings = RecorderSettings()
    /// Record-while-code-runs: the name prefix to record under once show code rolls.
    private var recorderArmedPrefix: String?
    private var recorderDropFrame = false
    /// Takes started but not yet in the list (ids and names are handed out once).
    private var recorderIssuedID = 0
    private var recorderIssuedNames: Set<String> = []
    /// Where the recorder's next take goes. Set by AppModel.
    var recorderFolder: (() -> URL)?
    /// Show code (or, without it, the time of day) at a host time. Set by AppModel.
    var recorderStartCode: ((Double) -> RecorderStartCode)?
    /// Whether the recorder stamps timecode at the video rate (deck timecode setting). Set by AppModel.
    var recorderTimecodeAtVideoRate: (() -> Bool)?

    var isRecorder: Bool { recorder != nil }

    init(id: Int) {
        self.id = id
        maps = TakeMapStore(deckID: id)
    }

    var isConnected: Bool { connection == .connected }
    var isLoggingTake: Bool { mapBuilder != nil }

    // MARK: Connection

    func connect(host: String) {
        detachRecorder()
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
        detachRecorder()
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
        guard !isRecorder else { return }
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
        guard isConnected, !isRecorder else { return }
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
        guard !isRecorder else { done("The Understudy recorder has no deck settings."); return }
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
    func identify() { if !isRecorder { sendQuietly(DeckSetupCommand.identify) } }

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
        guard !isRecorder else { done?(); return }
        request(HyperDeckCommand.transportInfo) { [weak self] response, _, _ in
            if response.isSuccess { self?.mergeTransport(response.fields) }
            done?()
        }
    }

    func refreshClips(_ done: (() -> Void)? = nil) {
        if let recorderTakes {
            clips = recorderTakes.clips
            onClipsRefreshed?()
            done?()
            return
        }
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
        if isRecorder {
            armRecorder(prefix: prefix, mode: mode, dropFrame: dropFrame)
            return
        }
        send(HyperDeckCommand.stop)
        send(HyperDeckCommand.recordPrefix(prefix))
        switch mode {
        case .continuous:
            send(HyperDeckCommand.recordTrigger(timecodeRun: false))
            send(HyperDeckCommand.timecodeInputInternal)
            // The deck's clock must count the same way as show code (Understudy reads both with the show rate's drop-frame setting).
            send(HyperDeckCommand.timecodePreference(dropFrame: dropFrame)) { [weak self] r in
                if r.isSuccess { self?.config["timecode preference"] = dropFrame ? "dropframe" : "nondropframe" }
            }
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
        if isRecorder {
            recorderArmedPrefix = nil
            recorder?.stopTake()
            refreshClips()
            return
        }
        send(HyperDeckCommand.stop)
        send(HyperDeckCommand.recordTrigger(timecodeRun: false))
        send(HyperDeckCommand.preview(true)) { [weak self] _ in self?.refreshClips() }
    }

    /// PLAY TC: disarm, switch the output to playback and report clip timecode.
    func enterPlayback(_ done: @escaping () -> Void) {
        resetChase()
        if isRecorder {
            // Nothing to play out: the View screen plays the recorder's files itself.
            recorderArmedPrefix = nil
            recorder?.stopTake()
            refreshClips(done)
            return
        }
        send(HyperDeckCommand.stop)
        send(HyperDeckCommand.recordTrigger(timecodeRun: false))
        send(HyperDeckCommand.timecodeOutputClip)
        send(HyperDeckCommand.preview(false))
        refreshClips(done)
    }

    func cue(clipID: Int, frame: Int) {
        guard !isRecorder else { return }
        send(HyperDeckCommand.stop)
        request(HyperDeckCommand.gotoClip(id: clipID, frame: frame)) { [weak self] response, _, _ in
            guard let self, response.isError else { return }
            // Older firmware: one parameter per goto.
            self.send(HyperDeckCommand.gotoClipStart(id: clipID))
            self.send(HyperDeckCommand.gotoFrameInClip(frame))
        }
    }

    /// Fast pickup: stop, goto and play back to back. The deck rolls from the new frame about
    /// 70–95 ms after these go out (goto ~30 ms, then its start delay).
    func cueAndPlay(clipID: Int, frame: Int) {
        guard !isRecorder else { return }
        send(HyperDeckCommand.stop)
        request(HyperDeckCommand.gotoClip(id: clipID, frame: frame)) { [weak self] response, _, _ in
            guard let self, response.isError else { return }
            // Older firmware: one parameter per goto; play again once it's there.
            self.send(HyperDeckCommand.gotoClipStart(id: clipID))
            self.send(HyperDeckCommand.gotoFrameInClip(frame))
            self.play()
        }
        play()
    }

    func play() { if !isRecorder { send(HyperDeckCommand.playSingleClip) } }

    func stopTransport() {
        if isRecorder {
            recorderArmedPrefix = nil
            recorder?.stopTake()
        } else {
            send(HyperDeckCommand.stop)
        }
    }

    func resetChase() {
        // A deck mid-chase must not run on unsupervised (input switch, rate change, new take).
        switch chase.phase {
        case .cueing, .armed, .starting, .playing: stopTransport()
        default: break
        }
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
    func logTakeReading(ltcSeconds: Double, deckSeconds: Double, deckDropFrame: Bool, now: Double) {
        guard var builder = mapBuilder else { return }
        builder.deckDropFrame = deckDropFrame
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
        if let recorder {
            // The newest recorded frame's code, valid half a frame after it was captured (deck
            // readings are taken as mid-frame).
            if let p = recorder.currentPosition() { result(p.timecode, p.host + 0.5 / p.rate.exact) }
            return
        }
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

    // MARK: Understudy recorder

    /// Makes this slot the Understudy recorder, recording from `settings.source` (opened now, so
    /// its picture and status show like a deck's input).
    func attachRecorder(_ settings: RecorderSettings, dropFrame: Bool) {
        client?.disconnect()
        client = nil
        let fresh = recorder == nil
        if fresh {
            transport = TransportInfo()
            config = [:]
            slots = []
            deviceInfo = nil
            everConnected = false
            let recorder = InternalRecorder(deckName: "deck-\(id + 1)")
            recorder.onStatus = { [weak self] status in
                DispatchQueue.main.async { [self] in MainActor.assumeIsolated { self?.applyRecorder(status) } }
            }
            recorder.onTakeFinished = { [weak self] result in
                DispatchQueue.main.async { [self] in MainActor.assumeIsolated { self?.recorderTakeFinished(result) } }
            }
            self.recorder = recorder
            recorderTakes = RecorderTakeStore(deckID: id)
        }
        model = "Understudy recorder"
        let sourceChanged = settings.source != recorderSettings.source || fresh
        recorderSettings = settings
        recorderDropFrame = dropFrame
        clips = recorderTakes?.clips ?? []
        guard let source = settings.source else {
            recorder?.close()
            connection = .disconnected
            return
        }
        if sourceChanged {
            if recorder?.isRecording == true { recorder?.stopTake() }
            connection = .connecting
            everConnected = false
        }
        recorder?.open(source, codec: settings.codec, dropFrame: dropFrame, folder: recorderFolder?())
    }

    private func detachRecorder() {
        guard let recorder else { return }
        recorder.close()
        self.recorder = nil
        recorderStatus = nil
        recorderTakes = nil
        recorderArmedPrefix = nil
        recorderSettings = RecorderSettings()
        model = nil
        transport = TransportInfo()
        clips = []
    }

    /// The recorder's file for a clip it made (for the viewer), if it's still there.
    func recorderTakePath(_ clipName: String) -> String? { recorderTakes?.path(of: clipName) }

    /// Status from the recorder, made to look like a deck's: connection, transport, input format.
    private func applyRecorder(_ s: InternalRecorder.Status) {
        guard recorder != nil else { return }
        recorderStatus = s
        var becameReady = false
        switch s.state {
        case .open:
            if connection != .connected {
                connection = .connected
                everConnected = true
                lastError = nil
                becameReady = true
            }
        case .opening:
            connection = .connecting
        case .failed(let message):
            lastError = message
            connection = .failed(message)
        case .closed:
            if connection != .disconnected { connection = .disconnected }
        }
        var fields = ["status": s.recording ? "record" : "preview",
                      "video format": s.lastVideoFormat ?? "none",
                      "input video format": s.videoFormat ?? "none"]
        if s.recording, let tc = s.timecode { fields["display timecode"] = tc.description }
        mergeTransport(fields)
        if !s.recording, transport.displayTimecode != nil { transport.displayTimecode = nil }
        if becameReady {
            refreshClips()
            onReady?()
        }
    }

    private func armRecorder(prefix: String, mode: RecordMode, dropFrame: Bool) {
        recorderDropFrame = dropFrame
        config["timecode preference"] = dropFrame ? "dropframe" : "nondropframe"
        recorder?.setDropFrame(dropFrame)
        recorder?.setFolder(recorderFolder?())
        switch mode {
        case .continuous:
            recorderArmedPrefix = nil
            startRecorderTake(prefix: prefix)
        case .timecodeRun:
            // Records while show code runs (see `recorderShowCode`), a new take each run, like a
            // deck's timecode-run trigger.
            recorderArmedPrefix = prefix
        }
    }

    /// Record-while-code-runs: called every tick in Record with whether show code is rolling.
    func recorderShowCode(rolling: Bool) {
        guard let recorder, let prefix = recorderArmedPrefix else { return }
        if rolling, !recorder.isRecording {
            startRecorderTake(prefix: prefix)
        } else if !rolling, recorder.isRecording {
            recorder.stopTake()
        }
    }

    private func startRecorderTake(prefix: String) {
        guard let recorder, let takes = recorderTakes, let folder = recorderFolder?() else { return }
        guard !recorder.isRecording else { return }
        let fm = FileManager.default
        let name = takes.list.nextName(prefix: prefix) { name in
            recorderIssuedNames.contains(name) || fm.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
        recorderIssuedNames.insert(name)
        recorderIssuedID = max(recorderIssuedID, takes.list.nextID - 1) + 1
        let host = HostClock.now()
        let start = recorderStartCode?(host) ?? .clock(Date())
        recorder.startTake(.init(url: folder.appendingPathComponent(name), takeID: recorderIssuedID, codec: recorderSettings.codec,
                                 start: start, startHost: host,
                                 timecodeAtVideoRate: recorderTimecodeAtVideoRate?() ?? true, dropFrame: recorderDropFrame))
    }

    private func recorderTakeFinished(_ result: Result<RecorderTake, RecorderError>) {
        guard let takes = recorderTakes else { return }
        switch result {
        case .success(let take):
            takes.add(take)
            recorderIssuedNames.remove(take.name)
            if take.droppedFrames > 0 {
                lastError = "\(take.name): \(take.droppedFrames) frame\(take.droppedFrames == 1 ? "" : "s") dropped."
            }
        case .failure(let e):
            lastError = e.message
        }
        // The new clip is listed now: let the take list and maps catch up.
        refreshClips()
        onRecordingFinished?()
    }

    // MARK: Helpers

    func clip(takeOffset: Int) -> DeckClip? {
        let index = clips.count - 1 - takeOffset
        return clips.indices.contains(index) ? clips[index] : nil
    }

    func videoRate(dropFrame: Bool) -> FrameRate? {
        // The recorder with no picture yet still knows the rate its takes were made at.
        guard let format = transport.videoFormat ?? transport.inputVideoFormat ?? recorderTakes?.list.takes.last?.videoFormat
        else { return nil }
        return FrameRate.fromVideoFormat(format, dropFrame: dropFrame)
    }
}
