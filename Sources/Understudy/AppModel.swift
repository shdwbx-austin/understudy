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
            // Recording from the timeline, then show code switched to LTC: the timeline no longer
            // drives the take, so Decks comes up.
            if mode == .record, settings.showCodeSource != oldValue.showCodeSource { followMode() }
        }
    }
    @Published private(set) var mode: Mode = .stop {
        // Dev Record sends the track timecode out (see devTimecodeChannel); other modes don't.
        didSet {
            if mode != oldValue {
                applyTimelineOutputs()
                followMode()
            }
        }
    }

    /// The main window's screens. Program (the timeline) and View (its pictures) take the decks:
    /// they follow the timeline (Timeline mode). Decks is where they stop, record or chase LTC,
    /// and where they're set up.
    enum Screen: String, CaseIterable {
        case program, view, decks
    }

    @Published private(set) var screen: Screen = Screen(rawValue: UserDefaults.standard.string(forKey: "understudy.screen") ?? "") ?? .program {
        didSet { UserDefaults.standard.set(screen.rawValue, forKey: "understudy.screen") }
    }
    /// Program or View, waiting on "Stop recording?" before it takes the decks.
    private var pendingScreen: Screen?

    /// Switch screens. Program and View put the decks into Timeline mode (leaving Record asks
    /// first, and the screen changes only once it's confirmed); Decks leaves them as they are.
    func show(_ next: Screen) {
        pendingScreen = nil
        guard next != .decks, !showsTimelineWorkspace else { screen = next; return }
        requestMode(.timeline)
        if showsTimelineWorkspace { screen = next } else if pendingMode != nil { pendingScreen = next }
    }

    /// Decks that stop following the timeline (Stop, Record from LTC, Play to code, from a menu,
    /// OSC or a restart) bring the Record screen up, so what they're doing is in front of you.
    private func followMode() {
        if !showsTimelineWorkspace, screen != .decks { screen = .decks }
    }

    /// The main window opened (a project chosen): Program is the main tool, so the decks follow
    /// the timeline unless they came back recording or playing after a restart.
    func mainWindowOpened() {
        if screen != .decks, mode == .stop, resumedMode == nil { setMode(.timeline) }
        followMode()
    }
    /// While recording from the timeline (dev Record) with LTC out off: the song-audio device's
    /// channel the songs' own timecode plays on, the one after the music pair (e.g. 3).
    @Published private(set) var devTimecodeChannel: Int?
    /// OSC control in: listening state ("Listening on 9000"), or what's wrong.
    @Published private(set) var oscStatus = "Off"
    /// The last OSC message received, for checking a controller is reaching Understudy.
    @Published private(set) var lastOSC: String?
    /// Result of the last marker export, deploy or push.
    @Published var linkMessage: String?
    @Published private(set) var linkBusy = false
    let osc = OSCServer()
    /// This Mac's network ports, refreshed every few seconds (for Settings' port warnings).
    @Published private(set) var portStates: [NetworkPortState] = []
    let projects = ProjectManager()
    /// Recordings played in Understudy, locked to the timeline, and sent out over NDI.
    let viewer = VideoViewer()
    /// The View screen or the video window is showing (either, or NDI, keeps the viewer loading takes).
    var viewerVisible: Bool { viewerViews > 0 }
    private var viewerViews = 0
    func viewerAppeared() {
        viewerViews += 1
        if viewerViews == 1 { loadViewerTake() }
    }
    func viewerDisappeared() { viewerViews = max(0, viewerViews - 1) }
    /// Backup files by name, so a take's recordings are found without searching the drive each time.
    /// AES67 out (test), when on.
    private var aes67: AES67Sender?
    private var aes67State: TimelineModel.RenderState?
    @Published private(set) var aes67Status: String?
    private var lastAES67Status = 0.0
    let updater = Updater()
    private var projectCreated = Date()
    private var projectSave: Task<Void, Never>?
    /// When Record was last pressed: the {date}/{time} in recording names.
    private(set) var recordStartedAt: Date?
    /// Dante out through Dante Virtual Soundcard: off, sending, or what's stopping it.
    @Published private(set) var danteStatus: DanteOut.Status = .off
    private var danteSoundcard: DanteOut.Device?
    private var lastDanteCheck = 0.0
    /// The show clock text and input meters change every frame; they live in `readout` so only
    /// the digits and meters redraw, not the whole window.
    let readout = Readout()
    var ltcText: String { readout.ltcText }
    /// Whether the clock has any code to show (it reads dashes otherwise); changes rarely.
    @Published private(set) var hasShowCode = false
    @Published private(set) var ltcRolling = false
    @Published private(set) var ltcFreewheeling = false
    /// Code is rolling, its rate is known (and matches the set rate when fixed), and it isn't freewheeling.
    @Published private(set) var ltcLocked = false
    @Published private(set) var ltcInfo = "NO LTC"
    @Published private(set) var ltcWarning: String?
    @Published private(set) var audioDevices: [AudioInputDevice] = []
    @Published private(set) var audioError: String?
    /// Peak level per channel of the open input, dBFS (−60…0), with meter-style fall-off.
    var inputLevels: [Float] { readout.inputLevels }
    /// The open input's channels, as the device names them ("" where it doesn't).
    @Published private(set) var inputChannelNames: [String] = []
    @Published private(set) var takes: [Take] = []
    @Published var selectedTake = 0 {
        didSet { if selectedTake != oldValue { decks.forEach { $0.resetChase() } } }
    }

    /// One controller per deck in the show (1–16), indexed by deck id.
    @Published private(set) var decks: [DeckController] = []
    let discovery = DeckDiscovery()
    let timeline = TimelineModel()
    /// Last paused timeline seek sent to the decks.
    private var sentSeek = -1
    /// The seek each deck was last parked for (Timeline mode, paused).
    private var parkedSeek: [Int: Int] = [:]
    private var lastSeekSent = 0.0
    let showMachine = ShowMachine()
    let backup = TakeBackup()
    let notchLC = NotchLCTranscoder()
    let confidence = ConfidenceMonitor()
    /// Capture devices and NDI sources the Understudy recorder can record from.
    let recorderSources = RecorderSources()
    /// Set when the app came back in Record or Play after a restart; shown as a banner until dismissed.
    @Published var resumedMode: Mode?
    private static let lastModeKey = "understudy.lastMode"

    private var clock: LTCClock
    private var rateDetector = LTCRateDetector()
    private let audio = AudioLTCInput()
    private var loop: Task<Void, Never>?
    private var portWatch: Task<Void, Never>?
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
        for deck in decks { wire(deck) }
        for config in loaded.decks where config.enabled { applyHost(config.id) }
        refreshAudioDevices()
        startAudio()
        viewer.onNDIEnabled = { [weak self] in self?.loadViewerTake() }
        syncViewerTransforms()
        if viewer.ndiEnabled { loadViewerTake() }
        // Interface unplugged, replugged or arriving after launch: re-read devices and reopen.
        AudioDeviceCatalog.observeDevices { [weak self] in
            MainActor.assumeIsolated { self?.audioDevicesChanged() }
        }
        discovery.skip = { [weak self] in
            guard let self else { return [] }
            return Set(self.decks.filter(\.isConnected).compactMap { self.settings.decks[$0.id].networkHost })
        }
        discovery.interface = { [weak self] in self?.settings.discoveryInterface }
        // Bonjour browsing runs only while Assign decks is open, so it never touches decks in use mid-show.
        if loaded.decks.allSatisfy({ !$0.isAssigned }) {
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
        osc.onMessage = { [weak self] message, from in self?.handleOSC(message, from: from) }
        osc.onState = { [weak self] in self?.refreshOSCStatus() }
        applyOSC()
        applyAES67()
        portWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.watchNetworkPorts()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
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
        pendingScreen = nil
        guard newMode != mode else { return }
        if mode == .record { pendingMode = newMode } else { setMode(newMode) }
    }

    func confirmPendingMode() {
        let screenAfter = pendingScreen
        pendingScreen = nil
        if let next = pendingMode { setMode(next) }
        pendingMode = nil
        if let screenAfter, showsTimelineWorkspace { screen = screenAfter }
    }

    func setMode(_ newMode: Mode) {
        // Re-sending the current mode would split a recording or re-cue every deck.
        guard newMode != mode || newMode == .stop else { return }
        pendingMode = nil
        if mode == .timeline, newMode != .timeline { timeline.stop() }
        // Never copy files off the decks while they record.
        if newMode == .record, backup.isRunning { backup.cancel() }
        // One time for the whole take, so every deck's file (and a deck that rejoins) shares it.
        if newMode == .record { recordStartedAt = Date() }
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
            parkedSeek = [:]
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
        deck.arm(prefix: recordName(for: deck.id), mode: settings.recordMode, dropFrame: ltcRate.isDropFrame)
    }

    /// The file name a deck records under for the take started at `recordStartedAt` (the deck adds _0001…).
    func recordName(for id: Int, at date: Date? = nil) -> String {
        settings.recordNaming.name(deck: settings.decks[id].name, number: id + 1,
                                   show: timeline.currentSetlist?.name ?? "",
                                   at: date ?? recordStartedAt ?? Date())
    }

    /// Where the Understudy recorder in slot `id` writes takes: the project's VideoFile/<deck> folder
    /// (where the View screen looks first), else the backup folder's day/<deck> folder (where it
    /// looks next), else ~/Movies/Understudy/<deck>.
    func recorderFolder(for id: Int, date: Date = Date()) -> URL {
        let deck = settings.decks.indices.contains(id) ? settings.decks[id].name : "Deck \(id + 1)"
        if let layout = projects.current {
            return layout.objects(.video).appendingPathComponent(ProjectManager.folderName(deck), isDirectory: true)
        }
        if let backup = settings.backupFolder {
            return URL(fileURLWithPath: backup, isDirectory: true)
                .appendingPathComponent(date.formatted(.iso8601.year().month().day()), isDirectory: true)
                .appendingPathComponent(FTPPaths.safeFolderName(deck), isDirectory: true)
        }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("Understudy", isDirectory: true)
            .appendingPathComponent(ProjectManager.folderName(deck), isDirectory: true)
    }

    /// What the recorder stamps a take with: show code at host time `host`, or the time of day
    /// when there's no (trusted) show code, as a deck's own clock would.
    func recorderStartCode(at host: Double) -> RecorderStartCode {
        if rateKnown || showCodeFromTimeline, let frames = showPosition(at: host) {
            return RecorderStartCode(seconds: frames / ltcRate.exact, isClockTime: false)
        }
        return .clock(Date())
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
            parkedSeek[deck.id] = nil
            deck.enterPlayback { [weak self] in self?.rebuildTakes() }
        }
    }

    // MARK: Decks

    private func wire(_ deck: DeckController) {
        deck.buildsTakeMaps = settings.recordMode == .continuous
        let id = deck.id
        deck.recorderFolder = { [unowned self] in self.recorderFolder(for: id) }
        deck.recorderStartCode = { [unowned self] host in self.recorderStartCode(at: host) }
        deck.recorderTimecodeAtVideoRate = { [unowned self] in self.settings.deckTimecodeAtVideoRate }
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

    // MARK: Deck list

    var canAddDeck: Bool { !setupLocked && settings.decks.count < AppSettings.maxDecks }
    var canRemoveDeck: Bool { !setupLocked && settings.decks.count > 1 }

    /// Adds a deck at the end (up to 16), named after the last one's pattern.
    func addDeck() {
        guard canAddDeck else { return }
        let n = settings.decks.count
        var list = settings.decks
        list.append(DeckConfig(id: n, name: "ME \(n + 1)", host: ""))
        setDeckList(list)
    }

    /// Removes deck `id`; the ones after it move up a number (their take maps go with them).
    func removeDeck(_ id: Int) {
        guard canRemoveDeck, settings.decks.indices.contains(id) else { return }
        var list = settings.decks
        list.remove(at: id)
        setDeckList(list, removed: [id])
    }

    /// Applies an edited deck list (Assign decks): entries keep their old ids, new ones have ids
    /// past the end, missing ids were removed.
    func applyDeckDraft(_ draft: [DeckConfig]) {
        guard !setupLocked else { return }
        let oldCount = settings.decks.count
        let kept = Set(draft.map(\.id).filter { $0 < oldCount })
        let removed = (0..<oldCount).filter { !kept.contains($0) }
        var list = draft
        for i in list.indices { list[i].host = list[i].host.trimmingCharacters(in: .whitespaces) }
        if removed.isEmpty, list.count == oldCount {
            for i in list.indices where list[i] != settings.decks[i] {
                let old = settings.decks[i]
                settings.decks[i] = list[i]
                if list[i].host != old.host || list[i].enabled != old.enabled || list[i].kind != old.kind
                    || list[i].recorder != old.recorder || (list[i].isRecorder && list[i].name != old.name) { applyHost(i) }
            }
        } else {
            setDeckList(list, removed: removed)
        }
    }

    /// Makes the deck list `configs` (from a project, or after an add/remove): controllers are
    /// added, dropped or rebuilt to match, and every deck reconnects to its address.
    func setDeckList(_ configs: [DeckConfig], removed: [Int] = []) {
        let list = AppSettings.normalized(configs)
        if let first = removed.min(), first < decks.count {
            // Controllers from the first removed one on are rebuilt under their new numbers.
            for deck in decks[first...] {
                if deck.transport.status == .record { deck.stopTransport() }
                deck.disconnect()
            }
            var count = decks.count
            for id in removed.sorted(by: >) {
                TakeMapStore.removeDeck(id: id, count: count)
                RecorderTakeStore.removeDeck(id: id, count: count)
                count -= 1
            }
            decks.removeSubrange(first...)
        }
        while decks.count > list.count {
            let deck = decks.removeLast()
            if deck.transport.status == .record { deck.stopTransport() }
            deck.disconnect()
        }
        while decks.count < list.count {
            let deck = DeckController(id: decks.count)
            wire(deck)
            decks.append(deck)
        }
        settings.decks = list
        settings.normalizeDecks()
        for id in list.indices { applyHost(id) }
        applyConfidence()
    }

    func applyHost(_ id: Int) {
        let config = settings.decks[id]
        // A deck leaving its slot mid-take must not keep recording on its own.
        if decks[id].transport.status == .record { decks[id].stopTransport() }
        if config.enabled, config.isRecorder {
            decks[id].attachRecorder(config.recorder, dropFrame: ltcRate.isDropFrame)
        } else if config.enabled {
            decks[id].connect(host: config.host, interface: settings.discoveryInterface)
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
        let targets = activeDecks.filter { !$0.isRecorder }
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
        // The recorder's files are on this Mac already (in the project or the backup folder).
        let items = activeDecks.filter { !$0.isRecorder }.compactMap { deck -> TakeBackup.Item? in
            guard let clip = deck.clip(takeOffset: offset) else { return nil }
            let config = settings.decks[deck.id]
            return TakeBackup.Item(
                deckName: config.name,
                host: config.host.trimmingCharacters(in: .whitespaces),
                fileName: clip.name
            )
        }
        backup.start(items, into: URL(fileURLWithPath: folder, isDirectory: true), interface: settings.discoveryInterface)
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
            if viewerVisible || viewer.ndiEnabled { loadViewerTake() }
            return
        }
        takes = reference.clips.reversed().enumerated().map { offset, clip in
            Take(offset: offset, clipID: clip.id, start: clip.start, duration: clip.duration,
                 name: clip.name, logged: reference.maps.map(for: clip).map { !$0.isEmpty })
        }
        if settings.followLatestTake || selectedTake >= takes.count {
            selectedTake = 0
        }
        // The takes just changed (or arrived after switching modes): park the decks again.
        if mode == .timeline { sentSeek = -1; parkedSeek = [:] }
        if viewerVisible || viewer.ndiEnabled { loadViewerTake() }
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
        readout.inputLevels = Array(repeating: -60, count: count)
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
        if levels != inputLevels { readout.inputLevels = levels }
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
        if settings.playback != old.playback || settings.decks.map(\.name) != old.decks.map(\.name) { syncViewerTransforms() }
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
            || settings.extraSongOutputs != old.extraSongOutputs
            || settings.ltcOutputDeviceUID != old.ltcOutputDeviceUID || settings.ltcOutputChannel != old.ltcOutputChannel
            || settings.ltcOutUseTrackTimecode != old.ltcOutUseTrackTimecode
            || settings.danteOut != old.danteOut || settings.danteInterface != old.danteInterface
            || settings.showCodeSource != old.showCodeSource {
            applyTimelineOutputs()
        }
        if settings.chase != old.chase || settings.deckTimecodeAtVideoRate != old.deckTimecodeAtVideoRate {
            decks.forEach { $0.resetChase() }
        }
        if settings.oscEnabled != old.oscEnabled || settings.oscPort != old.oscPort
            || settings.interfaces.oscIn != old.interfaces.oscIn { applyOSC() }
        if settings.discoveryInterface != old.discoveryInterface { applyDeckInterface() }
        if settings.aes67Enabled != old.aes67Enabled || settings.aes67Interface != old.aes67Interface
            || settings.aes67Multicast != old.aes67Multicast || settings.aes67Name != old.aes67Name { applyAES67() }
        if settings.decks != old.decks || settings.recordNaming != old.recordNaming || targets(of: settings) != targets(of: old)
            || settings.playback != old.playback {
            scheduleProjectSave()
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
        if let aes67 {
            // The sender renders on its own thread: hand it the timeline whenever it changes.
            let state = timeline.renderState()
            if state != aes67State { aes67State = state; aes67.update(state) }
            if now - lastAES67Status >= 0.5 { lastAES67Status = now; refreshAES67Status() }
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
        if mode == .record, settings.recordMode == .timecodeRun {
            // The recorder's stand-in for a deck's timecode-run trigger.
            let rolling = (rateKnown || showCodeFromTimeline) && showPosition(at: now) != nil
                && (showCodeFromTimeline ? timeline.isPlaying : snapshot.rolling)
            for deck in activeDecks where deck.isRecorder { deck.recorderShowCode(rolling: rolling) }
        }
        if mode == .playback { chase(snapshot, now: now, pollDue: pollDue) }
        if mode == .timeline, !viewer.slots.isEmpty {
            // The viewer's videos follow the timeline like the decks: playing, or parked on the frame.
            viewer.sync(now: now, playing: timeline.isPlaying && !timeline.isScrubbing) { [unowned self] deck, host in
                self.viewerSeconds(deck: deck, host: host)
            }
        } else if !viewer.slots.isEmpty {
            viewer.stop()
        }
        if mode == .timeline {
            // Scrubbing a playing timeline: park the decks under the playhead as it moves (like a
            // paused seek); when it settles, fast pickup starts them from there.
            if timeline.isScrubbing {
                seekDecksToPlayhead(now: now)
            } else {
                chase(timelineSnapshot, now: now, pollDue: pollDue)
                // Paused, or in the downtime between songs: parked, ready to roll.
                if !timeline.isPlaying || timeline.downtimeSong != nil { seekDecksToPlayhead(now: now) }
            }
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
              let show = timeline.parkShowSeconds else { return }
        lastSeekSent = now
        let ltcFrames = show * ltcRate.exact
        let active = activeDecks
        for deck in active where parkedSeek[deck.id] != timeline.seekCount {
            guard let target = playbackTarget(deck, ltcFrames: ltcFrames) else { continue }
            deck.resetChase()
            deck.cue(clipID: target.clipID, frame: target.frame)
            parkedSeek[deck.id] = timeline.seekCount
        }
        // Done once every deck has been sent this position. Right after switching to Timeline a
        // deck's takes may not have arrived yet: it's parked when they do (each deck once per seek).
        if active.allSatisfy({ parkedSeek[$0.id] == timeline.seekCount }) { sentSeek = timeline.seekCount }
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
        var ltcRoute = settings.ltcOutputChannel.map { AudioRoute(deviceUID: settings.ltcOutputDeviceUID, channel: $0) }
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

    /// Re-points the timeline's outputs; a playing timeline carries on through the change. The
    /// extra song outputs go along whatever the main one is (Dante or a device); one that's the
    /// same as the main output, or listed twice, plays once.
    private func reroute(music: AudioRoute, ltc: AudioRoute?) {
        var extra: [AudioRoute] = []
        for output in settings.extraSongOutputs {
            let route = AudioRoute(deviceUID: output.deviceUID, channel: output.channel)
            if route != music, !extra.contains(route) { extra.append(route) }
        }
        if timeline.player.configure(music: music, extra: extra, ltc: ltc) { timeline.resumeAudioAfterReroute() }
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

    private func setClockText(_ text: String) {
        if text != readout.ltcText { readout.ltcText = text }
        let has = !text.hasPrefix("--")
        if has != hasShowCode { hasShowCode = has }
    }

    private func updateReadout(now: Double, rolling: Bool) {
        if showCodeFromTimeline {
            // The timeline is the clock: show its code, not whatever arrives on the LTC input.
            let text = timeline.showTimecode?.display(dropFrame: ltcRate.isDropFrame) ?? "--:--:--:--"
            setClockText(text)
            let playing = timeline.isPlaying
            if playing != ltcRolling { ltcRolling = playing }
            if playing != ltcLocked { ltcLocked = playing }
            if ltcFreewheeling { ltcFreewheeling = false }
            if ltcInfo != "TIMELINE" { ltcInfo = "TIMELINE" }
            if ltcWarning != nil { ltcWarning = nil }
            return
        }
        let text = clock.timecode(at: now)?.display(dropFrame: ltcRate.isDropFrame) ?? "--:--:--:--"
        setClockText(text)
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

        // The recorder has no output to chase with: the View screen plays its files instead.
        for deck in activeDecks where !deck.isRecorder {
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

/// Readouts that change every frame (show clock text, input meters), observed only by the views
/// that draw them.
@MainActor
final class Readout: ObservableObject {
    @Published var ltcText = "--:--:--:--"
    @Published var inputLevels: [Float] = []
}

// MARK: - OSC control and show links

extension AppModel {
    func applyOSC() {
        if settings.oscEnabled { osc.listen(on: settings.oscPort, interface: settings.interfaces.oscIn) } else { osc.stop() }
        refreshOSCStatus()
    }

    func refreshOSCStatus() {
        let on = osc.route == .automatic ? "all network ports" : osc.route.summary
        let status = !settings.oscEnabled ? "Off" : (osc.problem ?? "Listening on UDP \(settings.oscPort) · \(on)")
        if status != oscStatus { oscStatus = status }
    }

    /// The deck port changed: decks reconnect through it (a recording deck when it next reconnects),
    /// and Bonjour browsing moves to it.
    func applyDeckInterface() {
        for (id, config) in settings.decks.enumerated() where id < decks.count && config.enabled {
            guard let host = config.networkHost else { continue }
            decks[id].setInterface(settings.discoveryInterface, host: host)
        }
        discovery.restartBrowsingIfNeeded()
    }

    /// Ports coming and going (a cable pulled, an adaptor plugged in, DHCP): Settings' warnings
    /// follow, and the OSC listener moves onto or off its chosen port. Senders pick the route
    /// up on their next connection.
    func watchNetworkPorts() {
        let states = NetworkPorts.states()
        if states != portStates { portStates = states }
        if settings.oscEnabled, PortRoute.resolve(settings.interfaces.oscIn, ports: states) != osc.route { applyOSC() }
    }

    /// A Stream Deck, MA3 or anything else asked for something.
    func handleOSC(_ message: OSCMessage, from: String) {
        let args = message.arguments.map(\.text).joined(separator: " ")
        lastOSC = "\(message.address)\(args.isEmpty ? "" : " " + args)  ·  \(from)"
        guard let command = RemoteControl.command(for: message, types: timeline.markerTypes) else { return }
        perform(command)
    }

    func perform(_ command: RemoteCommand) {
        switch command {
        case .play: timeline.play()
        case .pause, .stop: timeline.pause()
        case .togglePlay: timeline.togglePlay()
        case .nextSong: timeline.nextSong()
        case .previousSong: timeline.previousSong()
        case .gotoSong(let n): timeline.jump(toSong: n - 1)
        case .addMarker(let kind, let label): timeline.addMarker(kind, label: label)
        case .nextMarker: timeline.nextMarker()
        case .previousMarker: timeline.previousMarker()
        case .mode(let name):
            let modes: [String: Mode] = ["stop": .stop, "record": .record, "play": .playback, "timeline": .timeline]
            if let m = modes[name] { requestMode(m) }
        }
    }

    // MARK: Markers out

    private var markerSetName: String {
        let name = timeline.currentSetlist?.name ?? "Set"
        return "Understudy · \(name)"
    }


    func exportMarkersCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(timeline.currentSetlist?.name ?? "Markers") markers.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = MarkerExport.csv(timeline.markers, rate: ltcRate, songs: timeline.songs, types: timeline.markerTypes)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            linkMessage = "Exported \(timeline.markers.count) markers to \(url.lastPathComponent)."
        } catch {
            linkMessage = "Couldn't write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// The set, in order, as the exports see it.
    var exportSongs: [ExportSong] { ExportSong.set(timeline.layout) }

    /// What a grandMA3 export makes with the current setup.
    func ma3Plan() -> MA3Plan {
        MA3Plan.make(timeline.markers, songs: exportSongs, rate: ltcRate, types: timeline.markerTypes,
                     settings: settings.markerExport.ma3, sequenceStart: settings.ma3Sequence,
                     timecodeStart: settings.ma3Timecode, name: markerSetName)
    }

    /// The rows a disguise export writes with the current setup.
    func d3Rows() -> (rows: [D3Row], outside: Int) {
        let start = Timecode(settings.d3TrackStart).map { Double($0.frameIndex(at: ltcRate.ltcRate)) / ltcRate.ltcRate.exact } ?? 0
        return D3Row.rows(timeline.markers, songs: exportSongs, rate: ltcRate, types: timeline.markerTypes,
                          settings: settings.markerExport.d3, fallback: settings.d3Style,
                          singleTrack: settings.d3Track.isEmpty ? nil : settings.d3Track, singleStart: start)
    }

    /// A grandMA3 plugin (XML + Lua) that builds the export on the console.
    func exportMA3Plugin() {
        let plan = ma3Plan()
        guard plan.markerCount > 0 else { linkMessage = "No markers to export."; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "understudy_markers.xml"
        panel.allowedContentTypes = [.xml]
        panel.message = "Save the plugin into the console's plugins folder (or a USB stick), then import it in the Plugins pool."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let luaName = url.deletingPathExtension().lastPathComponent + ".lua"
        let lua = MA3Deploy.pluginLua(plan)
        let xml = MA3Deploy.pluginXML(name: "Understudy markers", luaFile: luaName)
        do {
            try xml.write(to: url, atomically: true, encoding: .utf8)
            try lua.write(to: url.deletingLastPathComponent().appendingPathComponent(luaName), atomically: true, encoding: .utf8)
            linkMessage = "MA3 plugin saved: \(url.lastPathComponent) + \(luaName) (\(plan.markerCount) markers)."
        } catch {
            linkMessage = "Couldn't write the plugin: \(error.localizedDescription)"
        }
    }

    /// Builds the export on a grandMA3 over OSC. Adds to what's there; see `MA3Deploy`.
    func deployMarkersToMA3(confirm: Bool = true) {
        let plan = ma3Plan()
        guard plan.markerCount > 0 else { linkMessage = "No markers to send."; return }
        guard let sender = OSCSender(host: settings.ma3Host, port: settings.ma3Port, interface: settings.interfaces.ma3) else {
            linkMessage = "Set the grandMA3's IP in Settings › Show control."
            return
        }
        if confirm {
            let alert = NSAlert()
            alert.messageText = "Send \(plan.markerCount) markers to grandMA3 at \(settings.ma3Host)?"
            alert.informativeText = MA3Deploy.summary(plan)
                + "\n\nNothing Understudy didn't make is deleted or reassigned: taken pool numbers and executors are left alone"
                + (plan.sequences.contains { $0.write == .override } ? ", and Override backs a sequence up before replacing its cues." : ".")
                + (plan.warnings.isEmpty ? "" : "\n\n" + plan.warnings.joined(separator: "\n"))
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let steps = MA3Deploy.steps(plan)
        let address = settings.ma3Prefix.isEmpty ? "/cmd" : "/\(settings.ma3Prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/cmd"
        let summary = MA3Deploy.summary(plan)
        let via = " (via \(sender.route.summary))"
        linkBusy = true
        linkMessage = "Sending to grandMA3…" + via
        Task { @MainActor [weak self] in
            do {
                for (i, step) in steps.enumerated() {
                    try await sender.send(OSCMessage(address, [.string(step.command)]))
                    if step.pause > 0 { try await Task.sleep(nanoseconds: UInt64(step.pause * 1e9)) }
                    if i % 10 == 0 { self?.linkMessage = "Sending to grandMA3… \(i + 1)/\(steps.count)" + via }
                }
                self?.linkMessage = "Sent to grandMA3: \(summary)\(via). (OSC can't confirm; check the console's command line feedback.)"
            } catch {
                self?.linkMessage = "grandMA3: \(error.localizedDescription)"
            }
            self?.linkBusy = false
        }
    }

    /// Writes the markers onto disguise tracks (by song name, or one track).
    func pushMarkersToD3() {
        let (rows, _) = d3Rows()
        guard !rows.isEmpty else { linkMessage = "No markers to send."; return }
        guard D3Client.base(settings.d3Host) != nil else {
            linkMessage = "Set the disguise machine's IP in Settings › Show control."
            return
        }
        let script = D3Push.script(rows, rate: ltcRate)
        let host = settings.d3Host
        let interface = settings.interfaces.d3
        let via = " (via \(NetworkPorts.route(interface).summary))"
        linkBusy = true
        linkMessage = "Sending to disguise…" + via
        Task { @MainActor [weak self] in
            do {
                let result = try await D3Client.execute(host: host, script: script, interface: interface)
                if let code = result.status?.code, code != 0 {
                    self?.linkMessage = "disguise: \(result.status?.message ?? "error \(code)")"
                } else if let inner = D3Client.resultDictionary(result.returnValue) {
                    self?.linkMessage = Self.d3Report(inner, via: via)
                } else {
                    self?.linkMessage = "disguise answered: \(result.returnValue ?? result.pythonLog ?? "no result")"
                }
            } catch {
                self?.linkMessage = "disguise: \(error.localizedDescription)" + via
            }
            self?.linkBusy = false
        }
    }

    /// One line from the script's result; `via` names the network port it went out of.
    nonisolated static func d3Report(_ r: [String: Any], via: String = "") -> String {
        let placed = r["placed"] as? Int ?? 0
        let tracks = (r["tracks"] as? [String: Any])?.keys.sorted() ?? []
        let missing = (r["missing"] as? [Any])?.compactMap { $0 as? String } ?? []
        let skipped = (r["skipped"] as? [Any])?.count ?? 0
        let kept = r["kept"] as? Int ?? 0
        let tags = r["tcTags"] as? Int ?? 0
        var s = "disguise: \(placed) markers on " + (tracks.count == 1 ? "“\(tracks[0])”" : "\(tracks.count) tracks")
        if tags > 0 { s += " (placed by \(tags) TC tag\(tags == 1 ? "" : "s"))" }
        if !missing.isEmpty { s += "; no track named " + missing.map { "“\($0)”" }.joined(separator: ", ") }
        if skipped > 0 { s += "; \(skipped) outside the track" }
        if kept > 0 { s += "; \(kept) existing note\(kept == 1 ? "" : "s") kept" }
        return s + via + "."
    }
}

// MARK: - Projects

extension AppModel {
    var projectName: String? { projects.current?.name }

    func targets(of s: AppSettings) -> ShowTargets {
        var t = ShowTargets()
        t.ma3Host = s.ma3Host; t.ma3Port = s.ma3Port; t.ma3Prefix = s.ma3Prefix
        t.ma3Sequence = s.ma3Sequence; t.ma3Timecode = s.ma3Timecode
        t.d3Host = s.d3Host; t.d3Track = s.d3Track; t.d3Style = s.d3Style; t.d3TrackStart = s.d3TrackStart
        t.markerExport = s.markerExport
        return t
    }

    private func apply(_ t: ShowTargets) {
        settings.ma3Host = t.ma3Host; settings.ma3Port = t.ma3Port; settings.ma3Prefix = t.ma3Prefix
        settings.ma3Sequence = t.ma3Sequence; settings.ma3Timecode = t.ma3Timecode
        settings.d3Host = t.d3Host; settings.d3Track = t.d3Track; settings.d3Style = t.d3Style; settings.d3TrackStart = t.d3TrackStart
        settings.markerExport = t.markerExport
    }

    /// The open show as a project file.
    func currentProjectFile() -> ProjectFile {
        var f = ProjectFile(name: projectName ?? "Untitled", created: projectCreated, show: timeline.content(),
                            decks: settings.decks, recordNaming: settings.recordNaming, targets: targets(of: settings),
                            playback: settings.playback)
        f.modified = Date()
        return f
    }

    /// Opens a project: its show, decks, recording names and marker targets. Not while recording.
    @discardableResult
    func openProject(_ layout: ProjectLayout) -> Bool {
        guard mode != .record else {
            projects.lastError = "Stop recording before opening another project."
            return false
        }
        if projects.current != nil { saveProjectNow() }
        do {
            let file = try projects.read(layout)
            projectSave?.cancel()
            projects.didOpen(layout)
            projectCreated = file.created
            hookTimeline()
            timeline.analysisRoot = layout.analysis
            timeline.load(file.show)
            if file.decks != settings.decks { setDeckList(file.decks) }
            settings.recordNaming = file.recordNaming
            settings.playback = file.playback
            adoptPlaybackLUTs()
            apply(file.targets)
            linkMessage = nil
            refreshTakes()
            return true
        } catch {
            projects.lastError = "Couldn't open \(layout.name): \(error.localizedDescription)"
            return false
        }
    }

    /// Makes a new project under the projects folder and opens it. `keepShow` carries the open
    /// show over (songs, set, markers); otherwise it starts empty. Decks carry over either way.
    @discardableResult
    func newProject(named name: String, keepShow: Bool, show: ShowContent? = nil) -> Bool {
        let content = show ?? (keepShow ? timeline.content() : ShowContent())
        let file = ProjectFile(name: name, show: content, decks: settings.decks, recordNaming: settings.recordNaming,
                               targets: targets(of: settings), playback: settings.playback)
        do {
            let layout = try projects.create(named: name, file: file)
            return openProject(layout)
        } catch {
            projects.lastError = error.localizedDescription
            return false
        }
    }

    /// The show from before projects (if any): songs and set kept in Application Support.
    var legacyShow: ShowContent? {
        guard let show = TimelineModel.legacyContent(), !show.songs.isEmpty else { return nil }
        return show
    }

    func closeProject() {
        guard mode != .record else { return }
        saveProjectNow()
        timeline.stop()
        projects.close()
    }

    /// Copies every song's audio from outside the project folder into it.
    func collectProjectFiles() {
        timeline.collectAudio()
    }

    private func hookTimeline() {
        timeline.onChange = { [weak self] in self?.scheduleProjectSave() }
        timeline.adoptFile = { [weak self] url, asset in self?.projects.adopt(url, as: asset) }
        timeline.adoptAudio = { [weak self] path, done in self?.projects.adoptAudio(path, done: done) }
    }

    func scheduleProjectSave() {
        guard projects.current != nil else { return }
        projectSave?.cancel()
        projectSave = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveProjectNow()
        }
    }

    func saveProjectNow() {
        projectSave?.cancel()
        projectSave = nil
        guard projects.current != nil else { return }
        projects.save(currentProjectFile())
    }
}

// MARK: - AES67 out (test)

extension AppModel {
    /// The IPv4 address of a network port, if it has one.
    func address(of bsd: String?) -> String? {
        guard let bsd else { return nil }
        return DeckDiscovery.localNetworks().first { $0.interface == bsd }?.address
    }

    func applyAES67() {
        aes67?.stop()
        aes67 = nil
        aes67State = nil
        guard settings.aes67Enabled else { aes67Status = nil; return }
        guard let ip = address(of: settings.aes67Interface) else {
            aes67Status = "Choose the network port the stream goes out of (it needs an IPv4 address)."
            return
        }
        let group = settings.aes67Multicast.trimmingCharacters(in: .whitespaces)
        let config = AES67Sender.Config(interfaceIP: ip, multicast: group.isEmpty ? AES67.defaultMulticast(for: ip) : group,
                                        name: settings.aes67Name.isEmpty ? "Understudy" : settings.aes67Name)
        let sender = AES67Sender(config: config)
        if let problem = sender.start() {
            aes67Status = problem
            return
        }
        aes67 = sender
        refreshAES67Status()
    }

    func refreshAES67Status() {
        guard let aes67 else { return }
        let s = aes67.status
        let group = settings.aes67Multicast.isEmpty ? (address(of: settings.aes67Interface).map(AES67.defaultMulticast) ?? "?") : settings.aes67Multicast
        var text = "Sending \(group):\(AES67.defaultPort) · 3 ch L24/48k · "
        text += s.ptpLocked ? "PTP locked to \(s.grandmaster ?? "?")" : "no PTP master: free-running (Dante won't accept it)"
        if let p = s.problem, !s.ptpLocked { text += " · \(p)" }
        if text != aes67Status { aes67Status = text }
    }

    var aes67Locked: Bool { aes67?.status.ptpLocked ?? false }
}

// MARK: - Video viewer

extension AppModel {
    /// Seconds into deck `deck`'s recording for the timeline at host time `host`, or nil where the
    /// take has no footage (the same mapping the deck chases).
    func viewerSeconds(deck id: Int, host: Double) -> Double? {
        guard decks.indices.contains(id), let context = playbackContext(decks[id]),
              viewer.slots.first(where: { $0.deckID == id })?.clipName == context.clip.name else { return nil }
        let show: Double?
        if timeline.isPlaying, !timeline.isScrubbing {
            show = timeline.showFrames(at: host).map { $0 / ltcRate.exact }
        } else {
            show = timeline.layout.showSeconds(at: timeline.playhead)
        }
        guard let show, let deckAt = context.map.deckSeconds(atLTC: show) else { return nil }
        return deckAt - context.clipStart
    }

    /// Loads the selected take's recordings for the first three decks, played where they are:
    /// the project's copy or the backup folder (the newest file with the take's name in the deck's
    /// folder), else the Understudy recorder's file. With Copy takes into the project on, a backup
    /// is also copied in, if the project's disk has room.
    func loadViewerTake() {
        let decksWithTakes = activeDecks.prefix(VideoViewer.maxSlots)
        let backups = backupFiles()
        var slots: [VideoViewer.Slot] = []
        for deck in decksWithTakes {
            let name = settings.decks[deck.id].name.trimmingCharacters(in: .whitespaces)
            guard let clip = deck.clip(takeOffset: selectedTake) else {
                slots.append(.init(deckID: deck.id, name: name, clipName: nil, url: nil, status: "No take on this deck"))
                continue
            }
            if let found = takeFile(clip.name, deck: name, backups: backups) {
                let url = URL(fileURLWithPath: found.path)
                if found.inProject {
                    slots.append(.init(deckID: deck.id, name: name, clipName: clip.name, url: url, status: "In the project"))
                    continue
                }
                let from = "From the backup" + (found.day.map { " · \($0)" } ?? "")
                guard settings.copyTakesIntoProject, let project = projects.current else {
                    slots.append(.init(deckID: deck.id, name: name, clipName: clip.name, url: url, status: from))
                    continue
                }
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let free = (try? project.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage) ?? nil
                if let free, !TakeFileLookup.fits(size: size, available: free) {
                    let gb = { (b: Int64) in String(format: "%.0f GB", Double(b) / 1e9) }
                    slots.append(.init(deckID: deck.id, name: name, clipName: clip.name, url: url,
                                       status: from + " (no room to copy it into the project: \(gb(size)), \(gb(free)) free)"))
                    continue
                }
                slots.append(.init(deckID: deck.id, name: name, clipName: clip.name, url: url, status: from + " · copying into the project…"))
                let deckID = deck.id
                projects.adoptVideo(found.path, deck: name) { [weak self] _ in
                    // Next load plays the project copy; now just say it's there.
                    guard let self else { return }
                    var updated = self.viewer.slots
                    if let i = updated.firstIndex(where: { $0.deckID == deckID }) { updated[i].status = "In the project" }
                    self.viewer.load(updated)
                }
            } else if let recorded = deck.recorderTakePath(clip.name) {
                slots.append(.init(deckID: deck.id, name: name, clipName: clip.name, url: URL(fileURLWithPath: recorded),
                                   status: "Recorded on this Mac"))
            } else {
                slots.append(.init(deckID: deck.id, name: name, clipName: clip.name, url: nil,
                                   status: settings.backupFolder == nil ? "Back up this take first (⌘B)" : "\(clip.name) isn't in the backup yet: back it up (⌘B)"))
            }
        }
        viewer.load(slots)
    }

    /// The take's file: the project's copy or a backup, whichever is this deck's newest.
    private func takeFile(_ file: String, deck: String, backups: [String: [TakeFileLookup.Candidate]]) -> TakeFileLookup.Candidate? {
        var candidates = backups[file] ?? []
        if let p = projects.videoPath(deck: deck, file: file) {
            let url = URL(fileURLWithPath: p)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            candidates.append(.init(path: p, modified: date, folder: url.deletingLastPathComponent().lastPathComponent, inProject: true))
        }
        return TakeFileLookup.best(candidates, deck: deck)
    }

    /// Complete recordings in the backup folder (its day and deck folders), by file name. Read
    /// afresh each time: a download in progress is a .part file until it finishes, and a name
    /// can be in several day folders.
    private func backupFiles() -> [String: [TakeFileLookup.Candidate]] {
        guard let folder = settings.backupFolder else { return [:] }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: folder, isDirectory: true), includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [:] }
        var out: [String: [TakeFileLookup.Candidate]] = [:]
        for case let url as URL in walker {
            if walker.level > 3 { walker.skipDescendants(); continue }
            guard ["mov", "mp4", "mxf"].contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let parent = url.deletingLastPathComponent()
            let day = parent.deletingLastPathComponent().lastPathComponent
            out[url.lastPathComponent, default: []].append(.init(
                path: url.path, modified: values.contentModificationDate ?? .distantPast, folder: parent.lastPathComponent,
                day: day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? day : nil))
        }
        return out
    }
}

// MARK: - NotchLC transcodes

extension AppModel {
    /// One take's files (by offset, 0 = latest), one per connected deck, found where View finds
    /// them: the project, then the backup folder, then the recorder's own folder. Each with where
    /// its NotchLC transcode goes: a NotchLC folder beside the project's media for that deck (or
    /// beside the file when no project is open), or a deck folder inside the chosen folder.
    func notchLCItems(_ offset: Int) -> [NotchLCTranscoder.Item] {
        let backups = backupFiles()
        return activeDecks.compactMap { deck -> NotchLCTranscoder.Item? in
            let name = settings.decks[deck.id].name.trimmingCharacters(in: .whitespaces)
            guard let clip = deck.clip(takeOffset: offset) else { return nil }
            let source = takeFile(clip.name, deck: name, backups: backups)?.path
                ?? deck.recorderTakePath(clip.name)
            guard let source else {
                return .init(deckName: name, source: nil, destination: nil,
                             missing: "\(clip.name) isn't on this Mac: back it up first (⌘B)")
            }
            let url = URL(fileURLWithPath: source)
            let folder: URL
            if let chosen = settings.notchLCFolder {
                folder = NotchLC.chosenFolder(URL(fileURLWithPath: chosen, isDirectory: true), deck: name)
            } else if let layout = projects.current {
                folder = NotchLC.defaultFolder(mediaFolder: layout.objects(.video)
                    .appendingPathComponent(ProjectManager.folderName(name), isDirectory: true))
            } else {
                folder = NotchLC.defaultFolder(mediaFolder: url.deletingLastPathComponent())
            }
            return .init(deckName: name, source: url, destination: NotchLC.outputURL(for: url, in: folder))
        }
    }

    /// Transcodes one take (0 = latest) to NotchLC. Not while recording: the files are still growing.
    func transcodeTake(_ offset: Int) {
        guard mode != .record else { return }
        notchLC.start(notchLCItems(offset), preset: settings.notchLCPreset)
    }

    func chooseNotchLCFolder() {
        if let path = NotchLCTranscoder.chooseFolder(startingAt: settings.notchLCFolder ?? settings.backupFolder) {
            settings.notchLCFolder = path
        }
    }

    func chooseNotchLCPreset() {
        if let path = NotchLCTranscoder.choosePreset(startingAt: settings.notchLCPreset) {
            settings.notchLCPreset = path
        }
    }
}
