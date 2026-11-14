import AVFoundation
import Foundation
import UnderstudyCore

struct Take: Identifiable, Hashable {
    /// 0 = latest take.
    let offset: Int
    let clipID: Int
    let start: Timecode
    let duration: Timecode
    let name: String
    /// nil: no map, played from clip timecode. Otherwise whether any show code was logged.
    let logged: Bool?
    var id: Int { offset }
}

@MainActor
final class AppModel: ObservableObject {
    enum Mode: String, CaseIterable {
        case stop, record, playback
    }

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            settingsChanged(from: oldValue)
        }
    }
    @Published private(set) var mode: Mode = .stop
    @Published private(set) var ltcText = "--:--:--:--"
    @Published private(set) var ltcRolling = false
    @Published private(set) var ltcFreewheeling = false
    /// Code is rolling, its rate is known (and matches the set rate when fixed), and it isn't freewheeling.
    @Published private(set) var ltcLocked = false
    @Published private(set) var ltcInfo = "NO LTC"
    @Published private(set) var ltcWarning: String?
    @Published private(set) var audioDevices: [AudioInputDevice] = []
    @Published private(set) var audioError: String?
    /// Peak level per channel of the open input, dBFS (−60…0), with meter-style fall-off.
    @Published private(set) var inputLevels: [Float] = []
    /// The open input's channels, as the device names them ("" where it doesn't).
    @Published private(set) var inputChannelNames: [String] = []
    @Published private(set) var takes: [Take] = []
    @Published var selectedTake = 0 {
        didSet { if selectedTake != oldValue { decks.forEach { $0.resetChase() } } }
    }

    let decks: [DeckController]
    let discovery = DeckDiscovery()
    let showMachine = ShowMachine()
    let backup = TakeBackup()
    /// Set when the app came back in Record or Play after a restart; shown as a banner until dismissed.
    @Published var resumedMode: Mode?
    private static let lastModeKey = "understudy.lastMode"

    private var clock: LTCClock
    private var rateDetector = LTCRateDetector()
    private let audio = AudioLTCInput()
    private var loop: Task<Void, Never>?
    private var lastPoll = 0.0
    private var lastInfoUpdate = 0.0
    private var takeRefreshScheduled = false
    private var lastAudioRestart = -Double.infinity
    /// The device and channel the audio input is reading now.
    private var openInput: (uid: String?, channel: Int)?

    init() {
        let loaded = AppSettings.load()
        settings = loaded
        clock = LTCClock(rate: loaded.ltcRate, freewheel: loaded.freewheelSeconds)
        decks = loaded.decks.map { DeckController(id: $0.id) }
        for deck in decks {
            deck.buildsTakeMaps = loaded.recordMode == .continuous
            deck.onRecordingFinished = { [weak self] in self?.scheduleTakeRefresh() }
            deck.onClipsRefreshed = { [weak self, weak deck] in
                guard let self, let deck else { return }
                self.fileTakeMaps(deck)
            }
            deck.onReady = { [weak self, weak deck] in
                guard let self, let deck else { return }
                self.deckReady(deck)
            }
        }
        for config in loaded.decks where config.enabled {
            decks[config.id].connect(host: config.host)
        }
        refreshAudioDevices()
        startAudio()
        discovery.skip = { [weak self] in
            guard let self else { return [] }
            return Set(self.decks.filter(\.isConnected).map { self.settings.decks[$0.id].host.trimmingCharacters(in: .whitespaces) })
        }
        discovery.interface = { [weak self] in self?.settings.discoveryInterface }
        discovery.startBrowsing()
        if loaded.decks.allSatisfy({ $0.host.trimmingCharacters(in: .whitespaces).isEmpty }) {
            discovery.scan()
        }
        showMachine.keepAwake(loaded.keepAwake)
        // Back into Record or Play after a restart, if asked. Decks are brought into the mode as
        // they connect (deckReady); a deck that kept recording through the restart is left alone.
        if loaded.resumeLastMode,
           let raw = UserDefaults.standard.string(forKey: Self.lastModeKey),
           let last = Mode(rawValue: raw), last != .stop {
            resumedMode = last
            setMode(last)
        }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    /// Show timecode rate in use: detected from incoming LTC when auto, otherwise as set.
    /// Before the first detection, auto uses the last rate it detected.
    var ltcRate: FrameRate {
        settings.ltcRateAuto ? (rateDetector.detected ?? settings.ltcRate) : settings.ltcRate
    }

    /// Off until auto-detect has measured the incoming code; logging and chasing wait for it,
    /// so a wrong guess never reaches a take map or a deck.
    private var rateKnown: Bool { !settings.ltcRateAuto || rateDetector.detected != nil }

    /// Header label for the rate, e.g. "AUTO 25" or "SET 29.97 DF".
    var rateLabel: String {
        guard settings.ltcRateAuto else { return "SET \(settings.ltcRate.rawValue)" }
        return rateDetector.detected.map { "AUTO \($0.rawValue)" } ?? "AUTO · DETECTING"
    }

    var activeDecks: [DeckController] {
        decks.filter { settings.decks[$0.id].enabled && $0.isConnected }
    }

    // MARK: Modes

    func setMode(_ newMode: Mode) {
        // Never copy files off the decks while they record.
        if newMode == .record, backup.isRunning { backup.cancel() }
        mode = newMode
        syncInput()
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.lastModeKey)
        if newMode != resumedMode { resumedMode = nil }
        let active = activeDecks
        switch newMode {
        case .stop:
            active.forEach { $0.stopAll() }
            scheduleTakeRefresh()
        case .record:
            active.forEach { arm($0) }
        case .playback:
            guard !active.isEmpty else {
                rebuildTakes()
                return
            }
            var remaining = active.count
            for deck in active {
                deck.enterPlayback { [weak self] in
                    remaining -= 1
                    if remaining == 0 { self?.rebuildTakes() }
                }
            }
        }
    }

    private func arm(_ deck: DeckController) {
        deck.arm(prefix: settings.decks[deck.id].name, mode: settings.recordMode, dropFrame: ltcRate.isDropFrame)
    }

    /// A deck (re)connected: bring it into the current mode. A deck that's already recording is
    /// left alone, so a network blip mid-take doesn't restart the recording.
    private func deckReady(_ deck: DeckController) {
        guard settings.decks[deck.id].enabled else { return }
        switch mode {
        case .stop:
            break
        case .record:
            if deck.transport.status != .record { arm(deck) }
        case .playback:
            deck.enterPlayback { [weak self] in self?.rebuildTakes() }
        }
    }

    // MARK: Decks

    func applyHost(_ id: Int) {
        let config = settings.decks[id]
        if config.enabled {
            decks[id].connect(host: config.host)
        } else {
            decks[id].disconnect()
        }
    }

    // MARK: Backup

    /// Copies the selected take's clip from every connected deck into the backup folder.
    func backUpSelectedTake() {
        guard mode != .record, let folder = settings.backupFolder else { return }
        let items = activeDecks.compactMap { deck -> TakeBackup.Item? in
            guard let clip = deck.clip(takeOffset: selectedTake) else { return nil }
            let config = settings.decks[deck.id]
            return TakeBackup.Item(
                deckName: config.name,
                host: config.host.trimmingCharacters(in: .whitespaces),
                fileName: clip.name
            )
        }
        backup.start(items, into: URL(fileURLWithPath: folder, isDirectory: true))
    }

    func chooseBackupFolder() {
        if let path = TakeBackup.chooseFolder(startingAt: settings.backupFolder) {
            settings.backupFolder = path
        }
    }

    /// The slot a host is assigned to, if any.
    func slot(for host: String) -> Int? {
        settings.decks.firstIndex { $0.host.trimmingCharacters(in: .whitespaces) == host }
    }

    /// Puts a found deck in a slot and connects it. A deck already in another slot moves.
    func assign(_ found: FoundDeck, to id: Int) {
        if let previous = slot(for: found.host), previous != id {
            settings.decks[previous].host = ""
            applyHost(previous)
        }
        settings.decks[id].host = found.host
        settings.decks[id].enabled = true
        applyHost(id)
    }

    /// Assigns found decks that aren't in a slot yet to the empty slots, in address order.
    func fillEmptySlots() {
        for found in discovery.found where slot(for: found.host) == nil {
            guard let empty = settings.decks.firstIndex(where: { $0.host.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
            assign(found, to: empty)
        }
    }

    /// Folds the measured drift into the deck's play offset.
    func calibrate(_ id: Int) {
        guard let error = decks[id].smoothedError else { return }
        let adjusted = settings.decks[id].playOffsetFrames - error
        settings.decks[id].playOffsetFrames = (adjusted * 2).rounded() / 2
        decks[id].resetChase()
    }

    func refreshTakes() {
        let active = activeDecks
        guard !active.isEmpty else {
            rebuildTakes()
            return
        }
        var remaining = active.count
        for deck in active {
            deck.refreshClips { [weak self] in
                remaining -= 1
                if remaining == 0 { self?.rebuildTakes() }
            }
        }
    }

    private func scheduleTakeRefresh() {
        guard !takeRefreshScheduled else { return }
        takeRefreshScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self?.takeRefreshScheduled = false
            self?.refreshTakes()
        }
    }

    private func rebuildTakes() {
        guard let reference = activeDecks.first(where: { !$0.clips.isEmpty }) else {
            takes = []
            return
        }
        takes = reference.clips.reversed().enumerated().map { offset, clip in
            Take(offset: offset, clipID: clip.id, start: clip.start, duration: clip.duration,
                 name: clip.name, logged: reference.maps.map(for: clip).map { !$0.isEmpty })
        }
        if settings.followLatestTake || selectedTake >= takes.count {
            selectedTake = 0
        }
    }

    // MARK: Timecode

    /// Rate the deck's timecode labels count at, or nil before the deck reports a video format.
    private func deckTimecodeRate(_ deck: DeckController) -> FrameRate? {
        guard let video = deck.videoRate(dropFrame: ltcRate.isDropFrame) else { return nil }
        return settings.deckTimecodeAtVideoRate ? video : video.ltcRate
    }

    /// Deck time a clip spans, [start, end) in seconds.
    private func deckSpan(_ clip: DeckClip, rate: FrameRate) -> (Double, Double) {
        let start = clip.start.seconds(at: rate)
        return (start, start + Double(clip.duration.durationFrames(nominal: rate.nominal)) / rate.exact)
    }

    /// Deck seconds for a displayed timecode. +0.5 centres it within the frame on screen.
    private func deckSeconds(_ tc: Timecode, rate: FrameRate) -> Double {
        (Double(tc.frameIndex(at: rate)) + 0.5) / rate.exact
    }

    /// Files finished recordings' maps under their clips once the deck lists them.
    private func fileTakeMaps(_ deck: DeckController) {
        guard let rate = deckTimecodeRate(deck) else { return }
        deck.maps.attachPending(to: deck.clips) { [unowned self] clip in self.deckSpan(clip, rate: rate) }
    }

    // MARK: Audio

    func refreshAudioDevices() {
        audioDevices = AudioDeviceCatalog.inputDevices()
    }

    func startAudio() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            openAudio()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor [weak self] in
                    if granted {
                        self?.openAudio()
                    } else {
                        self?.audioError = "Audio input access was declined."
                    }
                }
            }
        default:
            audioError = "Audio input is blocked. Allow Understudy in System Settings › Privacy & Security › Microphone."
        }
    }

    // MARK: LTC inputs

    enum InputRole { case show, playback }

    /// Play to code reads the playback input when one is set; everything else reads show timecode.
    var inputRole: InputRole {
        mode == .playback && settings.separatePlaybackInput ? .playback : .show
    }

    private func wantedInput() -> (uid: String?, channel: Int) {
        inputRole == .playback
            ? (settings.playbackAudioDeviceUID, settings.playbackAudioChannel)
            : (settings.audioDeviceUID, settings.audioChannel)
    }

    var activeInputName: String {
        let uid = wantedInput().uid
        return audioDevices.first { $0.uid == uid }?.name ?? "System default input"
    }

    var activeChannel: Int { wantedInput().channel }

    /// Channel names for a device: live from the open input, otherwise from Core Audio.
    func channelNames(forDeviceUID uid: String?) -> [String] {
        if let open = openInput, open.uid == uid, !inputChannelNames.isEmpty { return inputChannelNames }
        let device = audioDevices.first { $0.uid == uid }
        guard let id = device?.id ?? AudioDeviceCatalog.defaultInputDeviceID() else { return [] }
        let count = device?.channels ?? audioDevices.first { $0.id == id }?.channels ?? 0
        return count > 0 ? AudioDeviceCatalog.inputChannelNames(id, count: count) : []
    }

    /// Whether `uid` is the device being metered now.
    func isOpen(_ uid: String?) -> Bool { openInput?.uid == uid }

    /// Points the audio input at the right device and channel for the current mode. Same device:
    /// a live channel switch. Different device: the input is reopened. Either way it's a new
    /// signal, so the clock and rate detection start fresh.
    private func syncInput() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let wanted = wantedInput()
        guard let open = openInput else { openAudio(); return }
        if wanted.uid != open.uid {
            openAudio()
        } else if wanted.channel != open.channel {
            audio.setChannel(wanted.channel)
            openInput = wanted
            restartTimecode()
        }
    }

    private func restartTimecode() {
        rateDetector = LTCRateDetector()
        clock = LTCClock(rate: ltcRate, freewheel: settings.freewheelSeconds)
        decks.forEach { $0.resetChase() }
    }

    private func openAudio() {
        let wanted = wantedInput()
        let device = audioDevices.first { $0.uid == wanted.uid }
        do {
            restartTimecode()
            try audio.start(
                deviceID: device?.id,
                channel: wanted.channel,
                onFrame: { [weak self] event in
                    // The main queue keeps frames in order; separate Tasks don't guarantee that.
                    DispatchQueue.main.async { [self] in MainActor.assumeIsolated { self?.ingest(event) } }
                },
                onLevels: { [weak self] peaks in
                    DispatchQueue.main.async { [self] in MainActor.assumeIsolated { self?.ingestLevels(peaks) } }
                }
            )
            audioError = nil
        } catch {
            audioError = error.localizedDescription
        }
        let count = audio.channelCount
        let deviceID = device?.id ?? AudioDeviceCatalog.defaultInputDeviceID()
        inputChannelNames = deviceID.map { AudioDeviceCatalog.inputChannelNames($0, count: count) }
            ?? Array(repeating: "", count: count)
        inputLevels = Array(repeating: -60, count: count)
        openInput = audio.isRunning ? wanted : nil
        // The chosen channel doesn't exist on this device: fall back to its first channel.
        if count > 0, wanted.channel >= count {
            if inputRole == .playback { settings.playbackAudioChannel = 0 } else { settings.audioChannel = 0 }
        }
    }

    /// Reopens the input if it stops delivering audio (e.g. the interface glitched or was replugged).
    private func watchAudio(now: Double) {
        guard audio.isRunning, audio.secondsSinceLastBuffer > 1.5, now - lastAudioRestart > 5 else { return }
        lastAudioRestart = now
        NSLog("Understudy: audio input stalled; reopening")
        openAudio()
        if audioError == nil {
            audioError = "Audio input stalled and was reopened."
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if self?.audioError == "Audio input stalled and was reopened." { self?.audioError = nil }
            }
        }
    }

    private func ingestLevels(_ peaks: [Float]) {
        let fall: Float = 1.2   // dB per update (~24 dB/s)
        var levels = inputLevels.count == peaks.count ? inputLevels : Array(repeating: -60, count: peaks.count)
        for (i, peak) in peaks.enumerated() {
            let db = min(0, max(-60, 20 * log10(max(peak, 1e-6))))
            levels[i] = max(db, levels[i] - fall)
        }
        if levels != inputLevels { inputLevels = levels }
    }

    private func ingest(_ event: AudioLTCInput.Event) {
        rateDetector.ingest(dropFrameFlag: event.dropFrame, time: event.sampleTime)
        if settings.ltcRateAuto, let detected = rateDetector.detected, detected != settings.ltcRate {
            settings.ltcRate = detected   // remembered for next launch; settingsChanged re-rates the clock
        }
        syncClockRate()
        clock.ingest(event.timecode, dropFrameFlag: event.dropFrame, boundaryTime: event.boundaryTime)
    }

    /// Rebuilds the show clock when the rate in use changes.
    private func syncClockRate() {
        guard clock.rate != ltcRate else { return }
        clock = LTCClock(rate: ltcRate, freewheel: settings.freewheelSeconds)
        decks.forEach { $0.resetChase() }
    }

    private func settingsChanged(from old: AppSettings) {
        syncClockRate()
        if settings.keepAwake != old.keepAwake {
            showMachine.keepAwake(settings.keepAwake)
        }
        if settings.freewheelSeconds != old.freewheelSeconds {
            clock.freewheel = settings.freewheelSeconds
        }
        if settings.recordMode != old.recordMode {
            decks.forEach { $0.buildsTakeMaps = settings.recordMode == .continuous }
        }
        if settings.audioDeviceUID != old.audioDeviceUID || settings.audioChannel != old.audioChannel
            || settings.separatePlaybackInput != old.separatePlaybackInput
            || settings.playbackAudioDeviceUID != old.playbackAudioDeviceUID
            || settings.playbackAudioChannel != old.playbackAudioChannel {
            syncInput()
        }
        if settings.chase != old.chase || settings.deckTimecodeAtVideoRate != old.deckTimecodeAtVideoRate {
            decks.forEach { $0.resetChase() }
        }
    }

    // MARK: Loop

    private func tick() {
        let now = HostClock.now()
        var snapshot = clock.snapshot(at: now)
        if !rateKnown { snapshot = LTCSnapshot(rolling: false, position: nil, jumped: false, fps: snapshot.fps) }
        updateReadout(now: now, rolling: snapshot.rolling)
        let pollDue = now - lastPoll >= 0.1
        if pollDue { lastPoll = now }
        if pollDue { watchAudio(now: now) }
        if pollDue && rateKnown { logTakes() }
        if mode == .playback { chase(snapshot, now: now, pollDue: pollDue) }
    }

    private func updateReadout(now: Double, rolling: Bool) {
        let text = clock.timecode(at: now)?.display(dropFrame: ltcRate.isDropFrame) ?? "--:--:--:--"
        if text != ltcText { ltcText = text }
        if rolling != ltcRolling { ltcRolling = rolling }
        let freewheeling = clock.isFreewheeling(at: now)
        if freewheeling != ltcFreewheeling { ltcFreewheeling = freewheeling }
        let rateAgrees = settings.ltcRateAuto
            ? rateDetector.detected != nil
            : (rateDetector.detected == nil || rateDetector.detected == settings.ltcRate)
        let locked = rolling && !freewheeling && rateAgrees
        if locked != ltcLocked { ltcLocked = locked }
        guard now - lastInfoUpdate > 0.5 else { return }
        lastInfoUpdate = now
        let info: String
        if clock.lastTimecode == nil {
            info = "NO LTC"
        } else if let fps = rateDetector.measuredFPS {
            info = String(format: "LTC %.3f fps", fps)
        } else {
            info = "MEASURING LTC…"
        }
        if info != ltcInfo { ltcInfo = info }
        var warning: String?
        if !settings.ltcRateAuto, let detected = rateDetector.detected, detected != settings.ltcRate {
            warning = "Incoming LTC looks like \(detected.rawValue); rate is set to \(settings.ltcRate.rawValue)."
        }
        if warning != ltcWarning { ltcWarning = warning }
    }

    /// While decks record, pair each deck timecode reading with show code at the same instant.
    /// Readings while show code is absent are skipped; the deck keeps recording regardless.
    private func logTakes() {
        let ltcFPS = ltcRate.exact
        for deck in activeDecks where deck.isLoggingTake {
            guard let rate = deckTimecodeRate(deck) else { continue }
            deck.poll { [weak self, weak deck] timecode, observedAt in
                guard let self, let deck, let ltcAt = self.clock.position(at: observedAt) else { return }
                deck.logTakeReading(
                    ltcSeconds: ltcAt / ltcFPS,
                    deckSeconds: self.deckSeconds(timecode, rate: rate),
                    now: HostClock.now()
                )
            }
        }
    }

    private func chase(_ snapshot: LTCSnapshot, now: Double, pollDue: Bool) {
        let ltcFPS = ltcRate.exact

        for deck in activeDecks {
            let config = settings.decks[deck.id]
            guard let clip = deck.clip(takeOffset: selectedTake),
                  let video = deck.videoRate(dropFrame: ltcRate.isDropFrame),
                  let tcRate = deckTimecodeRate(deck)
            else {
                if deck.chase != DeckChaseState() { deck.resetChase() }
                continue
            }
            let (clipStart, clipEnd) = deckSpan(clip, rate: tcRate)
            // Logged show code if this take has it; otherwise assume the clip was stamped with show code.
            let map = (deck.maps.map(for: clip) ?? .identity(deckStart: clipStart, duration: clipEnd - clipStart))
                .clipped(toDeck: clipStart, clipEnd)
            let input = DeckChaseInput(
                startLatencyFrames: config.playOffsetFrames,
                coverage: map.segments.map { ($0.ltcStart * ltcFPS)..<($0.ltcEnd * ltcFPS) },
                observedError: deck.takeFreshError(),
                deckIsPlaying: deck.transport.status == .play
            )

            var state = deck.chase
            let actions = ChaseEngine.step(&state, ltc: snapshot, input: input, now: now, settings: settings.chase)
            if state != deck.chase { deck.chase = state }

            for action in actions {
                switch action {
                case .cue(let target):
                    guard let deckAt = map.deckSeconds(atLTC: Double(target) / ltcFPS) else { continue }
                    deck.cue(clipID: clip.id, frame: Int(((deckAt - clipStart) * video.exact).rounded()))
                case .play:
                    deck.play()
                case .stop:
                    deck.stopTransport()
                }
            }

            if pollDue, case .playing = deck.chase.phase {
                deck.poll { [weak self, weak deck] timecode, observedAt in
                    guard let self, let deck,
                          let ltcAt = self.clock.position(at: observedAt),
                          let expected = map.deckSeconds(atLTC: ltcAt / ltcFPS)
                    else { return }
                    deck.noteDrift((self.deckSeconds(timecode, rate: tcRate) - expected) * ltcFPS)
                }
            }
        }
    }
}
