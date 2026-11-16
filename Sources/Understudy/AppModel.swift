import AppKit
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
        case stop, record, playback, timeline
    }

    /// Decks are playing footage back: chasing show code, or following the timeline.
    var isPlayingBack: Bool { mode == .playback || mode == .timeline }

    /// The main window shows the timeline workspace: Timeline mode, or Record driven by the timeline.
    var showsTimelineWorkspace: Bool {
        mode == .timeline || (mode == .record && settings.showCodeSource == .timeline)
    }

    /// Show code comes from the song timeline rather than the LTC input: always in Timeline mode,
    /// and in Stop and Record when Settings says so. Play to code always chases the LTC input.
    var showCodeFromTimeline: Bool {
        mode == .timeline || (mode != .playback && settings.showCodeSource == .timeline)
    }

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            settingsChanged(from: oldValue)
        }
    }
    @Published private(set) var mode: Mode = .stop {
        // Dev Record sends the track timecode out (see devTimecodeChannel); other modes don't.
        didSet { if mode != oldValue { applyTimelineOutputs() } }
    }
    /// While recording from the timeline (dev Record) with LTC out off: the song-audio device's
    /// channel the songs' own timecode plays on, the one after the music pair (e.g. 3).
    @Published private(set) var devTimecodeChannel: Int?
    /// Dante out through Dante Virtual Soundcard: off, sending, or what's stopping it.
    @Published private(set) var danteStatus: DanteOut.Status = .off
    private var danteSoundcard: DanteOut.Device?
    private var lastDanteCheck = 0.0
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
    let timeline = TimelineModel()
    /// Last paused timeline seek sent to the decks.
    private var sentSeek = -1
    private var lastSeekSent = 0.0
    let showMachine = ShowMachine()
    let backup = TakeBackup()
    let confidence = ConfidenceMonitor()
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
    private var lastSlotRefresh = 0.0
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
        // Interface unplugged, replugged or arriving after launch: re-read devices and reopen.
        AudioDeviceCatalog.observeDevices { [weak self] in
            MainActor.assumeIsolated { self?.audioDevicesChanged() }
        }
        discovery.skip = { [weak self] in
            guard let self else { return [] }
            return Set(self.decks.filter(\.isConnected).map { self.settings.decks[$0.id].host.trimmingCharacters(in: .whitespaces) })
        }
        discovery.interface = { [weak self] in self?.settings.discoveryInterface }
        // Bonjour browsing runs only while Assign decks is open, so it never touches decks in use mid-show.
        if loaded.decks.allSatisfy({ $0.host.trimmingCharacters(in: .whitespaces).isEmpty }) {
            discovery.scan()
        }
        showMachine.keepAwake(loaded.keepAwake)
        // A normal Quit is not a crash: don't come back recording next time.
        let lastModeKey = Self.lastModeKey
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            UserDefaults.standard.set(Mode.stop.rawValue, forKey: lastModeKey)
        }
        applyConfidence()
        applyTimelineOutputs()
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
    private var rateKnown: Bool {
        // A fixed rate the incoming code contradicts would re-cue every second and log wrong
        // positions: wait (the header warns) rather than act on it.
        settings.ltcRateAuto ? rateDetector.detected != nil
            : (rateDetector.detected == nil || rateDetector.detected == settings.ltcRate)
    }

    /// Header label for the rate, e.g. "AUTO 25" or "SET 29.97 DF".
    var rateLabel: String {
        guard settings.ltcRateAuto else { return "SET \(settings.ltcRate.rawValue)" }
        return rateDetector.detected.map { "AUTO \($0.rawValue)" } ?? "AUTO · DETECTING"
    }

    var activeDecks: [DeckController] {
        decks.filter { settings.decks[$0.id].enabled && $0.isConnected }
    }

    // MARK: Modes

    /// A mode change waiting for the operator to confirm (leaving Record ends the take).
    @Published var pendingMode: Mode?

    /// Mode change from the UI: leaving Record asks first; the current mode again does nothing.
    func requestMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        if mode == .record { pendingMode = newMode } else { setMode(newMode) }
    }

    func confirmPendingMode() {
        if let next = pendingMode { setMode(next) }
        pendingMode = nil
    }

    func setMode(_ newMode: Mode) {
        // Re-sending the current mode would split a recording or re-cue every deck.
        guard newMode != mode || newMode == .stop else { return }
        pendingMode = nil
        if mode == .timeline, newMode != .timeline { timeline.stop() }
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
            // Decks offline right now still owe a stop (they may be recording on their own).
            for deck in decks where settings.decks[deck.id].enabled && !deck.isConnected { deck.owesStop = true }
            scheduleTakeRefresh()
        case .record:
            active.forEach { arm($0) }
        case .playback, .timeline:
            sentSeek = -1
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
            // Missed a Stop while offline: stop it now.
            if deck.owesStop { deck.stopAll() }
            deck.owesStop = false
        case .record:
            deck.owesStop = false
            if deck.transport.status != .record { arm(deck) }
        case .playback, .timeline:
            deck.owesStop = false
            sentSeek = -1
            deck.enterPlayback { [weak self] in self?.rebuildTakes() }
        }
    }

    // MARK: Decks

    func applyHost(_ id: Int) {
        let config = settings.decks[id]
        // A deck leaving its slot mid-take must not keep recording on its own.
        if decks[id].transport.status == .record { decks[id].stopTransport() }
        if config.enabled {
            decks[id].connect(host: config.host)
        } else {
            decks[id].disconnect()
        }
    }

    // MARK: Confidence monitor

    /// Starts, stops or re-maps the confidence monitor to match settings.
    private func applyConfidence(restart: Bool = true) {
        confidence.configure(
            layout: settings.confidenceLayout,
            quadrants: settings.confidenceQuadrants,
            singleDeck: settings.confidenceSingleDeck,
            check: settings.pictureCheck
        )
        guard restart else { return }
        confidence.stop()
        if settings.confidenceEnabled { confidence.start(deviceID: settings.confidenceDeviceID) }
    }

    /// The connected deck with the least recording time left, if any has reported.
    var lowestMedia: (deck: Int, seconds: Int)? {
        activeDecks.compactMap { d in d.mediaSecondsLeft.map { (d.id, $0) } }.min { $0.1 < $1.1 }
    }

    // MARK: Deck setup

    /// Deck settings can't change while recording.
    var setupLocked: Bool { mode == .record }

    /// Editable settings that differ between connected decks, by key, with each deck's value.
    var settingMismatches: [String: [Int: String]] {
        deckSettingMismatches(Dictionary(uniqueKeysWithValues: activeDecks.map { ($0.id, $0.config) }))
    }

    /// Applies one setting to every connected deck. `done` gets the problems, by deck name.
    func applyToAll(_ key: String, _ value: String, done: @escaping ([String]) -> Void) {
        guard !setupLocked else { done(["Stop recording first."]); return }
        let targets = activeDecks
        guard !targets.isEmpty else { done([]); return }
        var remaining = targets.count
        var problems: [String] = []
        for deck in targets {
            deck.apply(key, value) { [weak self] problem in
                if let problem, let self { problems.append("\(self.settings.decks[deck.id].name): \(problem)") }
                remaining -= 1
                if remaining == 0 { done(problems) }
            }
        }
    }

    // MARK: Backup

    /// The take to play, chosen by the operator. Choosing an older take stops following the latest.
    func chooseTake(_ offset: Int) {
        selectedTake = offset
        if offset != 0 { settings.followLatestTake = false }
    }

    /// Copies one take's clip (by offset, 0 = latest) from every connected deck into the backup folder.
    /// Independent of the playback take, so backing up never changes what's playing.
    func backUpTake(_ offset: Int) {
        guard mode != .record, let folder = settings.backupFolder else { return }
        let items = activeDecks.compactMap { deck -> TakeBackup.Item? in
            guard let clip = deck.clip(takeOffset: offset) else { return nil }
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
        // A new recording: put the set in the order it played, if asked (once per take).
        if timeline.autoOrderFromTakes, let latest = takes.first, latest.clipID != lastAutoOrderedClip,
           latest.logged == true {
            lastAutoOrderedClip = latest.clipID
            orderSetByTake(0)
        }
    }

    private var lastAutoOrderedClip: Int?

    /// Puts the timeline's set in the order its songs played in a take (0 = latest), read from the
    /// take's show-code map on the first deck that has one.
    @discardableResult
    func orderSetByTake(_ offset: Int) -> Bool {
        for deck in activeDecks {
            guard let clip = deck.clip(takeOffset: offset), let map = deck.maps.map(for: clip), !map.isEmpty else { continue }
            return timeline.orderSet(by: map, takeName: "take #\(clip.id) (\(clip.name))") > 0
        }
        timeline.message = "That take has no show-code map yet (record with continuous recording to make one)."
        return false
    }

    // MARK: Timecode

    /// Rate the deck's timecode labels count at, or nil before the deck reports a video format.
    /// How the deck's own timecode counts: what the deck reports (its timecode preference), or
    /// the show rate's drop-frame if it hasn't said.
    private func deckDropFrame(_ deck: DeckController) -> Bool {
        deck.deckDropFrame ?? ltcRate.isDropFrame
    }

    private func deckTimecodeRate(_ deck: DeckController, dropFrame: Bool? = nil) -> FrameRate? {
        guard let video = deck.videoRate(dropFrame: dropFrame ?? deckDropFrame(deck)) else { return nil }
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
        // Record what's really open: if the chosen device is missing, that's the system default.
        openInput = audio.isRunning ? (device?.uid, wanted.channel) : nil
        if audio.isRunning, wanted.uid != nil, device == nil {
            audioError = "The chosen LTC interface isn't connected; reading the system default input."
        }
        // The chosen channel doesn't exist on this device: fall back to its first channel.
        if count > 0, wanted.channel >= count {
            if inputRole == .playback { settings.playbackAudioChannel = 0 } else { settings.audioChannel = 0 }
        }
    }

    /// Reopens the input if it stops delivering audio (e.g. the interface glitched or was replugged).
    private func audioDevicesChanged() {
        refreshAudioDevices()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        // Reopen if what's open isn't what's wanted (the interface came back) or nothing is open.
        if openInput?.uid != wantedInput().uid || !audio.isRunning { openAudio() }
        // Dante Virtual Soundcard started, stopped or restarted; any output device came or went.
        applyTimelineOutputs()
    }

    private func watchAudio(now: Double) {
        // Nothing open (failed to start, device vanished): keep trying every few seconds.
        if !audio.isRunning, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, now - lastAudioRestart > 5 {
            lastAudioRestart = now
            refreshAudioDevices()
            openAudio()
            return
        }
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
        if settings.confidenceEnabled != old.confidenceEnabled || settings.confidenceDeviceID != old.confidenceDeviceID {
            applyConfidence()
        } else if settings.confidenceLayout != old.confidenceLayout || settings.confidenceQuadrants != old.confidenceQuadrants
            || settings.confidenceSingleDeck != old.confidenceSingleDeck || settings.pictureCheck != old.pictureCheck {
            applyConfidence(restart: false)   // same device: just re-map / re-tune
        }
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
        if settings.timelineOutputUID != old.timelineOutputUID || settings.timelineOutputChannel != old.timelineOutputChannel
            || settings.ltcOutputUID != old.ltcOutputUID || settings.ltcOutputChannel != old.ltcOutputChannel
            || settings.ltcOutUseTrackTimecode != old.ltcOutUseTrackTimecode
            || settings.danteOut != old.danteOut || settings.danteInterface != old.danteInterface
            || settings.showCodeSource != old.showCodeSource {
            applyTimelineOutputs()
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
        // The timeline keeps its playhead (and end-of-set stop) current in every mode.
        timeline.rate = ltcRate
        let timelineSnapshot = timeline.snapshot(at: now)
        updateReadout(now: now, rolling: snapshot.rolling)
        let pollDue = now - lastPoll >= 0.1
        if pollDue { lastPoll = now }
        if pollDue {
            watchAudio(now: now)
            confidence.checkStale(now: now)
        }
        if settings.danteOut, now - lastDanteCheck >= 2 {
            lastDanteCheck = now
            updateDanteStatus()
        }
        if now - lastSlotRefresh >= 15 {
            lastSlotRefresh = now
            activeDecks.forEach { $0.refreshSlots() }
        }
        if pollDue && (rateKnown || showCodeFromTimeline) { logTakes() }
        if mode == .playback { chase(snapshot, now: now, pollDue: pollDue) }
        if mode == .timeline {
            chase(timelineSnapshot, now: now, pollDue: pollDue)
            if !timeline.isPlaying { seekDecksToPlayhead(now: now) }
        }
    }

    // MARK: Timeline

    /// Dev/test: record on the decks while the timeline runs. Show code comes from the timeline, so
    /// takes log against each song's code; the timeline stays on screen. Leaving Record asks first.
    func startTimelineRecording() {
        settings.showCodeSource = .timeline
        requestMode(.record)
    }

    /// Show code (LTC frames) at host time `t` from whichever source is in charge.
    private func showPosition(at t: Double) -> Double? {
        showCodeFromTimeline ? timeline.showFrames(at: t) : clock.position(at: t)
    }

    /// Paused timeline: park every deck on the frame under the playhead (scrub, frame step).
    /// Throttled; the latest position always goes out.
    private func seekDecksToPlayhead(now: Double) {
        guard timeline.seekCount != sentSeek, now - lastSeekSent >= 0.06,
              let show = timeline.layout.showSeconds(at: timeline.playhead) else { return }
        sentSeek = timeline.seekCount
        lastSeekSent = now
        let ltcFrames = show * ltcRate.exact
        for deck in activeDecks {
            guard let target = playbackTarget(deck, ltcFrames: ltcFrames) else { continue }
            deck.resetChase()
            deck.cue(clipID: target.clipID, frame: target.frame)
        }
    }

    func applyTimelineOutputs() {
        timeline.useTrackTimecode = settings.ltcOutUseTrackTimecode
        danteSoundcard = settings.danteOut ? DanteOut.soundcard(in: AudioDeviceCatalog.outputDevices().map {
            DanteOut.Device(uid: $0.uid, name: $0.name, channels: $0.channels, model: $0.model)
        }) : nil
        updateDanteStatus()
        if danteStatus.isRouted, let card = danteSoundcard {
            // Left and right on DVS 1–2, timecode on 3, on the one device so they stay locked.
            if devTimecodeChannel != nil { devTimecodeChannel = nil }
            reroute(music: AudioRoute(deviceUID: card.uid, channel: DanteOut.musicChannel),
                    ltc: AudioRoute(deviceUID: card.uid, channel: DanteOut.timecodeChannel))
            return
        }
        var ltcRoute = settings.ltcOutputChannel.map { AudioRoute(deviceUID: settings.ltcOutputUID, channel: $0) }
        // Dev Record with LTC out off: the songs' own timecode goes out on the song-audio device,
        // on the channel after the music (3 for music on 1–2), so the decks or a recorder can take it.
        let recordingFromTimeline = mode == .record && showCodeFromTimeline
        let devChannel = DevTimecodeOut.channel(
            recordingFromTimeline: recordingFromTimeline, ltcOutSet: ltcRoute != nil,
            musicChannel: settings.timelineOutputChannel,
            deviceChannels: recordingFromTimeline ? AudioDeviceCatalog.outputChannels(uid: settings.timelineOutputUID) : 0
        )
        if let devChannel { ltcRoute = AudioRoute(deviceUID: settings.timelineOutputUID, channel: devChannel) }
        if devChannel != devTimecodeChannel { devTimecodeChannel = devChannel }
        reroute(music: AudioRoute(deviceUID: settings.timelineOutputUID, channel: settings.timelineOutputChannel),
                ltc: ltcRoute)
    }

    /// Re-points the timeline's outputs; a playing timeline carries on through the change.
    private func reroute(music: AudioRoute, ltc: AudioRoute?) {
        if timeline.player.configure(music: music, ltc: ltc) { timeline.resumeAudioAfterReroute() }
    }

    /// Re-reads whether the preferred Dante port has a link (the soundcard is re-read on device changes).
    private func updateDanteStatus() {
        let port = settings.danteInterface
        let status = DanteOut.status(
            enabled: settings.danteOut, soundcard: danteSoundcard,
            port: port.map { bsd in DeckDiscovery.networkPorts().first { $0.bsd == bsd }?.label ?? bsd },
            portLinked: port.map(DeckDiscovery.hasLink) ?? true
        )
        if status != danteStatus { danteStatus = status }
    }

    /// Where the timeline's timecode is going, for status lines: "Dante 3", "LTC out ch 4" or nil (off).
    var timecodeOutLabel: String? {
        if danteStatus.isRouted { return "Dante ch \(DanteOut.timecodeChannel + 1)" }
        if let channel = devTimecodeChannel { return "Track TC ch \(channel + 1) (dev)" }
        return settings.ltcOutputChannel.map { "LTC out ch \($0 + 1)" }
    }

    private func updateReadout(now: Double, rolling: Bool) {
        if showCodeFromTimeline {
            // The timeline is the clock: show its code, not whatever arrives on the LTC input.
            let text = timeline.showTimecode?.display(dropFrame: ltcRate.isDropFrame) ?? "--:--:--:--"
            if text != ltcText { ltcText = text }
            let playing = timeline.isPlaying
            if playing != ltcRolling { ltcRolling = playing }
            if playing != ltcLocked { ltcLocked = playing }
            if ltcFreewheeling { ltcFreewheeling = false }
            if ltcInfo != "TIMELINE" { ltcInfo = "TIMELINE" }
            if ltcWarning != nil { ltcWarning = nil }
            return
        }
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
            let dropFrame = deckDropFrame(deck)
            guard let rate = deckTimecodeRate(deck, dropFrame: dropFrame) else { continue }
            deck.poll { [weak self, weak deck] timecode, observedAt in
                guard let self, let deck, let ltcAt = self.showPosition(at: observedAt) else { return }
                deck.logTakeReading(
                    ltcSeconds: ltcAt / ltcFPS,
                    deckSeconds: self.deckSeconds(timecode, rate: rate),
                    deckDropFrame: dropFrame,
                    now: HostClock.now()
                )
            }
        }
    }

    /// The selected take on a deck, and how show code maps onto it.
    private struct PlaybackContext {
        let clip: DeckClip
        let map: TakeMap
        let clipStart: Double
        let video: FrameRate
        let tcRate: FrameRate
    }

    private func playbackContext(_ deck: DeckController) -> PlaybackContext? {
        let logged = deck.clip(takeOffset: selectedTake).flatMap { deck.maps.map(for: $0) }
        // Read deck timecode the way the deck counted when this take was recorded.
        let dropFrame = logged?.deckDropFrame ?? deckDropFrame(deck)
        guard let clip = deck.clip(takeOffset: selectedTake),
              let video = deck.videoRate(dropFrame: dropFrame),
              let tcRate = deckTimecodeRate(deck, dropFrame: dropFrame)
        else { return nil }
        let (clipStart, clipEnd) = deckSpan(clip, rate: tcRate)
        // Logged show code if this take has it; otherwise assume the clip was stamped with show code.
        let map = (logged ?? .identity(deckStart: clipStart, duration: clipEnd - clipStart))
            .clipped(toDeck: clipStart, clipEnd)
        return PlaybackContext(clip: clip, map: map, clipStart: clipStart, video: video, tcRate: tcRate)
    }

    /// Clip and frame on a deck for show code `ltcFrames`, or nil if the take has no footage there.
    private func playbackTarget(_ deck: DeckController, ltcFrames: Double) -> (clipID: Int, frame: Int)? {
        guard let context = playbackContext(deck),
              let deckAt = context.map.deckSeconds(atLTC: ltcFrames / ltcRate.exact) else { return nil }
        return (context.clip.id, Int(((deckAt - context.clipStart) * context.video.exact).rounded()))
    }

    private func chase(_ snapshot: LTCSnapshot, now: Double, pollDue: Bool) {
        let ltcFPS = ltcRate.exact

        for deck in activeDecks {
            let config = settings.decks[deck.id]
            guard let context = playbackContext(deck) else {
                if deck.chase != DeckChaseState() { deck.resetChase() }
                continue
            }
            let (clip, map, clipStart, video, tcRate) = (context.clip, context.map, context.clipStart, context.video, context.tcRate)
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
                case .cueAndPlay(let target):
                    guard let deckAt = map.deckSeconds(atLTC: Double(target) / ltcFPS) else { continue }
                    deck.cueAndPlay(clipID: clip.id, frame: Int(((deckAt - clipStart) * video.exact).rounded()))
                case .play:
                    deck.play()
                case .stop:
                    deck.stopTransport()
                case .learnOffset(let by), .trimOffset(let by):
                    // Same setting Calibrate writes, shown in deck Setup; half-frame steps, ±30 frames.
                    let adjusted = settings.decks[deck.id].playOffsetFrames + by
                    settings.decks[deck.id].playOffsetFrames = max(-30, min(30, (adjusted * 2).rounded() / 2))
                }
            }

            if pollDue, case .playing = deck.chase.phase {
                deck.poll { [weak self, weak deck] timecode, observedAt in
                    // Against the code the deck is chasing: the timeline in Timeline mode, LTC in otherwise.
                    guard let self, let deck,
                          let ltcAt = self.mode == .timeline ? self.timeline.showFrames(at: observedAt) : self.clock.position(at: observedAt),
                          let expected = map.deckSeconds(atLTC: ltcAt / ltcFPS)
                    else { return }
                    deck.noteDrift((self.deckSeconds(timecode, rate: tcRate) - expected) * ltcFPS)
                }
            }
        }
    }
}
