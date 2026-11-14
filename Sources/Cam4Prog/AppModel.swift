import AVFoundation
import Foundation
import Cam4ProgCore

struct Take: Identifiable, Hashable {
    /// 0 = latest take.
    let offset: Int
    let clipID: Int
    let start: Timecode
    let duration: Timecode
    let name: String
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
    @Published private(set) var ltcInfo = "NO LTC"
    @Published private(set) var ltcWarning: String?
    @Published private(set) var audioDevices: [AudioInputDevice] = []
    @Published private(set) var audioError: String?
    @Published private(set) var takes: [Take] = []
    @Published var selectedTake = 0 {
        didSet { if selectedTake != oldValue { decks.forEach { $0.resetChase() } } }
    }

    let decks: [DeckController]

    private var clock: LTCClock
    private let audio = AudioLTCInput()
    private var loop: Task<Void, Never>?
    private var lastPoll = 0.0
    private var lastInfoUpdate = 0.0
    private var detectedFPS: Double?
    private var detectedDF = false
    private var appRecordRolling = false
    private var appRecordStopAt: Double?
    private var takeRefreshScheduled = false

    init() {
        let loaded = AppSettings.load()
        settings = loaded
        clock = LTCClock(rate: loaded.ltcRate)
        decks = loaded.decks.map { DeckController(id: $0.id) }
        for deck in decks {
            deck.onRecordingFinished = { [weak self] in self?.scheduleTakeRefresh() }
        }
        for config in loaded.decks where config.enabled {
            decks[config.id].connect(host: config.host)
        }
        refreshAudioDevices()
        startAudio()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    var activeDecks: [DeckController] {
        decks.filter { settings.decks[$0.id].enabled && $0.isConnected }
    }

    // MARK: Modes

    func setMode(_ newMode: Mode) {
        mode = newMode
        appRecordRolling = false
        appRecordStopAt = nil
        let active = activeDecks
        switch newMode {
        case .stop:
            active.forEach { $0.stopAll() }
            scheduleTakeRefresh()
        case .record:
            for deck in active {
                deck.arm(prefix: settings.decks[deck.id].name, nativeTrigger: settings.nativeRecordTrigger)
            }
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

    // MARK: Decks

    func applyHost(_ id: Int) {
        let config = settings.decks[id]
        if config.enabled {
            decks[id].connect(host: config.host)
        } else {
            decks[id].disconnect()
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
            Take(offset: offset, clipID: clip.id, start: clip.start, duration: clip.duration, name: clip.name)
        }
        if settings.followLatestTake || selectedTake >= takes.count {
            selectedTake = 0
        }
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
            audioError = "Audio input is blocked. Allow cam4prog in System Settings › Privacy & Security › Microphone."
        }
    }

    private func openAudio() {
        let device = audioDevices.first { $0.uid == settings.audioDeviceUID }
        do {
            try audio.start(deviceID: device?.id, channel: settings.audioChannel) { [weak self] event in
                Task { @MainActor in self?.ingest(event) }
            }
            audioError = nil
        } catch {
            audioError = error.localizedDescription
        }
    }

    private func ingest(_ event: AudioLTCInput.Event) {
        clock.ingest(event.timecode, dropFrameFlag: event.dropFrame, boundaryTime: event.boundaryTime)
        detectedFPS = event.estimatedFPS
        detectedDF = event.dropFrame
    }

    private func settingsChanged(from old: AppSettings) {
        if settings.ltcRate != old.ltcRate {
            clock = LTCClock(rate: settings.ltcRate)
            decks.forEach { $0.resetChase() }
        }
        if settings.audioDeviceUID != old.audioDeviceUID || settings.audioChannel != old.audioChannel {
            openAudio()
        }
        if settings.chase != old.chase || settings.deckTimecodeAtVideoRate != old.deckTimecodeAtVideoRate {
            decks.forEach { $0.resetChase() }
        }
    }

    // MARK: Loop

    private func tick() {
        let now = HostClock.now()
        let snapshot = clock.snapshot(at: now)
        updateReadout(now: now, rolling: snapshot.rolling)
        switch mode {
        case .stop:
            break
        case .record:
            if !settings.nativeRecordTrigger { appTriggeredRecord(rolling: snapshot.rolling, now: now) }
        case .playback:
            chase(snapshot, now: now)
        }
    }

    private func updateReadout(now: Double, rolling: Bool) {
        let text = clock.timecode(at: now)?.display(dropFrame: settings.ltcRate.isDropFrame) ?? "--:--:--:--"
        if text != ltcText { ltcText = text }
        if rolling != ltcRolling { ltcRolling = rolling }
        guard now - lastInfoUpdate > 0.5 else { return }
        lastInfoUpdate = now
        let info: String
        if let fps = detectedFPS, clock.lastTimecode != nil {
            info = String(format: "LTC ≈%.2f%@", fps, detectedDF ? " DF" : "")
        } else {
            info = "NO LTC"
        }
        if info != ltcInfo { ltcInfo = info }
        let warning: String? = (detectedFPS != nil && detectedDF != settings.ltcRate.isDropFrame)
            ? "Incoming LTC is \(detectedDF ? "drop" : "non-drop") frame; rate is set to \(settings.ltcRate.rawValue)."
            : nil
        if warning != ltcWarning { ltcWarning = warning }
    }

    /// Fallback when decks are not using their own timecode-run trigger.
    private func appTriggeredRecord(rolling: Bool, now: Double) {
        if rolling {
            appRecordStopAt = nil
            if !appRecordRolling {
                appRecordRolling = true
                activeDecks.forEach { $0.record() }
            }
        } else if appRecordRolling {
            if let stopAt = appRecordStopAt {
                if now >= stopAt {
                    appRecordRolling = false
                    appRecordStopAt = nil
                    activeDecks.forEach { $0.stopTransport() }
                }
            } else {
                appRecordStopAt = now + 1.0
            }
        }
    }

    private func chase(_ snapshot: LTCSnapshot, now: Double) {
        let ltcRate = settings.ltcRate
        let pollDue = now - lastPoll >= 0.1
        if pollDue { lastPoll = now }

        for deck in activeDecks {
            let config = settings.decks[deck.id]
            guard let clip = deck.clip(takeOffset: selectedTake),
                  let video = deck.videoRate(dropFrame: ltcRate.isDropFrame)
            else {
                if deck.chase != DeckChaseState() { deck.resetChase() }
                continue
            }
            let tcRate = settings.deckTimecodeAtVideoRate ? video : video.ltcRate
            let clipStart = clip.start.seconds(at: tcRate)
            let startFrame = clipStart * ltcRate.exact
            let length = Double(clip.duration.durationFrames(nominal: tcRate.nominal)) / tcRate.exact * ltcRate.exact
            let input = DeckChaseInput(
                startLatencyFrames: config.playOffsetFrames,
                range: startFrame...(startFrame + max(0, length - 1)),
                observedError: deck.takeFreshError(),
                deckIsPlaying: deck.transport.status == .play
            )

            var state = deck.chase
            let actions = ChaseEngine.step(&state, ltc: snapshot, input: input, now: now, settings: settings.chase)
            if state != deck.chase { deck.chase = state }

            for action in actions {
                switch action {
                case .cue(let target):
                    let targetSeconds = Double(target) / ltcRate.exact
                    let frame = Int(((targetSeconds - clipStart) * video.exact).rounded())
                    deck.cue(clipID: clip.id, frame: frame)
                case .play:
                    deck.play()
                case .stop:
                    deck.stopTransport()
                }
            }

            if pollDue, case .playing = deck.chase.phase {
                deck.poll { [weak self, weak deck] timecode, observedAt in
                    guard let self, let deck, let ltcAt = self.clock.position(at: observedAt) else { return }
                    // Displayed TC is the frame on screen; +0.5 centres it within that frame.
                    let deckSeconds = (Double(timecode.frameIndex(at: tcRate)) + 0.5) / tcRate.exact
                    deck.noteDrift(deckSeconds * ltcRate.exact - ltcAt)
                }
            }
        }
    }
}
