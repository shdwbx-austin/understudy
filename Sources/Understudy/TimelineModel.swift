import AppKit
import Foundation
import UniformTypeIdentifiers
import UnderstudyCore

/// The show's songs as a rehearsal playlist, and the timeline transport that plays it.
///
/// In Timeline mode this is the master clock: it plays the song audio, feeds the chase engine
/// (in place of incoming LTC) so the decks follow, and can output LTC for everything else.
@MainActor
final class TimelineModel: ObservableObject {
    /// The library: tonight's set first, in playing order, then the other songs in timecode order.
    @Published private(set) var songs: [Song] = []

    /// The songs that play, in order.
    var setSongs: [Song] { songs.filter(\.inSet) }
    /// Songs imported but not on the set.
    var librarySongs: [Song] { songs.filter { !$0.inSet } }
    /// Lead-in before each song, giving the decks time to park on its footage.
    @Published var gap: Double = 2 {
        didSet { if gap != oldValue { layoutChanged() } }
    }
    /// Time between songs with no code, audio or LTC, before each lead-in (a show's changeovers).
    @Published var downtime: Double = 0 {
        didSet { if downtime != oldValue { layoutChanged() } }
    }
    /// Stop at the end of each song, parked on the next one's lead-in, instead of rolling on.
    @Published var stopAfterSong = false {
        didSet { if stopAfterSong != oldValue { save() } }
    }
    /// Loop the current song or a section.
    @Published var loop = LoopSetting() {
        didSet { if loop != oldValue { save() } }
    }
    /// Beat lines on the current song (for songs with a tempo).
    @Published var showGrid: Bool = UserDefaults.standard.object(forKey: "understudy.showGrid") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showGrid, forKey: "understudy.showGrid") }
    }
    /// The current song's zoom (1 = the whole song across the width).
    @Published var detailZoom: Double = 1
    static let maxZoom = 32.0
    /// Saved sets. The current one follows every change to the set.
    @Published private(set) var setlists: [Setlist] = []
    @Published private(set) var currentSetlistID: UUID?
    /// After each recording, put the set in the order the songs played in it.
    @Published var autoOrderFromTakes = false {
        didSet { if autoOrderFromTakes != oldValue { save() } }
    }
    var currentSetlist: Setlist? { setlists.first { $0.id == currentSetlistID } }
    /// Waveform overviews (0…1 peaks) by audio file path, filled in the background.
    /// What's known about each audio file (timecode, clean copies, waveform), by path.
    @Published private(set) var analyses: [String: AudioAnalysis] = [:]
    private var analyzing: Set<String> = []
    var waveforms: [String: [Float]] { analyses.mapValues(\.peaks) }
    /// Play a track's own timecode to LTC out instead of generated code (Settings).
    var useTrackTimecode = true {
        didSet { if useTrackTimecode != oldValue, isPlaying { restartPlayback() } }
    }
    /// The playhead, published on its own: it moves every frame while playing, and only the views
    /// that draw it (playhead lines, the time readout) watch it, so the playlist, waveforms and
    /// song blocks aren't redrawn 30 times a second.
    let head = PlayheadClock()
    /// Timeline seconds, refreshed by the app's loop.
    private(set) var playhead: Double {
        get { head.position }
        set {
            head.position = newValue
            refreshCurrent()
        }
    }
    /// The set song under the playhead (changes only at song boundaries).
    @Published private(set) var currentIndex: Int?
    /// True while the playhead is being dragged or swiped during playback: the transport keeps
    /// running at the new spot, but song audio and LTC out stay silent until it settles.
    private(set) var isScrubbing = false
    private var scrubSettle: Task<Void, Never>?
    @Published private(set) var isPlaying = false
    /// Markers, on show code (they stay with their song in any set order).
    @Published private(set) var markers: [Marker] = []
    /// Marker types hidden on the timeline and in the list.
    @Published var hiddenMarkerKinds: Set<MarkerKind> = [] {
        didSet { if hiddenMarkerKinds != oldValue { save() } }
    }
    /// The marker last chosen (where the playhead went, the anchor for ⇧-click ranges).
    @Published var selectedMarkerID: UUID? {
        didSet { if let id = selectedMarkerID, !selectedMarkerIDs.contains(id) { selectedMarkerIDs = [id] } }
    }
    /// Every selected marker: ⌘-click adds or removes one, ⇧-click a range. Edits from the list's
    /// selection bar or a selected marker's menu apply to all of them.
    @Published var selectedMarkerIDs: Set<UUID> = []
    /// The marker type editor is open (from the marker bar, a chip, or Markers › Edit Marker Types…).
    @Published var editingMarkerTypes = false
    /// The project's marker types: names, colours, order (keys 1–9).
    @Published var markerTypes: MarkerTypes = .defaults {
        didSet { if markerTypes != oldValue { save() } }
    }
    /// The type a bare "add marker" (M, or OSC /marker) uses: the last one chosen (or the first).
    private var lastKind: MarkerKind?
    var lastMarkerKind: MarkerKind {
        if let k = lastKind, markerTypes.types.contains(where: { $0.id == k }) { return k }
        return markerTypes.types.first?.id ?? .choreo
    }
    @Published var message: String?

    /// Show timecode rate the songs and decks count in (the show LTC rate).
    var rate: FrameRate = .fps30 {
        didSet {
            guard rate != oldValue else { return }
            // Timecode found in files is read at the show rate: read them again.
            analyses = [:]
            layoutChanged()
        }
    }
    private(set) var layout = TimelineLayout(ordered: [], rate: .fps30) {
        didSet { refreshCurrent() }
    }
    private var transport = TimelineTransport()
    let player = TimelinePlayer()
    /// Bumped on every seek, so paused frame seeks reach the decks once each.
    private(set) var seekCount = 0

    /// Called after every change, for the open project to save.
    var onChange: (() -> Void)?
    /// Where audio analysis is cached (the project's internal/analysis).
    var analysisRoot: URL = TimelineModel.storeDirectory.appendingPathComponent("audio", isDirectory: true)
    /// Copies a file into the project (song lists); returns the copy, or nil to keep the original.
    var adoptFile: ((URL, ProjectLayout.Asset) -> URL?)?
    /// Copies audio into the project in the background, then calls back with the copy's path.
    var adoptAudio: ((String, @escaping @MainActor @Sendable (String) -> Void) -> Void)?

    init() {}

    // MARK: Playlist

    func importCSV(from url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            _ = adoptFile?(url, .songList)
            let result = try SongListCSV.read(text)
            // Keeps audio and tonight's set (by song name); an alphabetical list goes to the library.
            songs = SongLibrary.merge(result.songs, into: songs, rate: rate)
            let inSet = setSongs.count
            message = "Imported \(songs.count) songs from \(url.lastPathComponent): \(inSet) on the set, \(songs.count - inSet) in the library."
            if inSet == 0 { message! += " Add tonight's songs to the set with +." }
            if !result.skipped.isEmpty {
                message! += " Skipped \(result.skipped.count) with no start timecode: \(result.skipped.joined(separator: ", "))."
            }
            stop()
            seek(to: 0)
            layoutChanged()
        } catch {
            message = "Couldn't import \(url.lastPathComponent): \(error)"
        }
    }

    func chooseCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, UTType(filenameExtension: "tsv") ?? .plainText]
        panel.message = "A song list: name, start timecode, optional end timecode."
        if panel.runModal() == .OK, let url = panel.url { importCSV(from: url) }
    }

    func attachAudio(_ url: URL, to id: UUID) {
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        guard let duration = TimelinePlayer.duration(of: url), duration > 0 else {
            message = "\(url.lastPathComponent) isn't an audio file Understudy can read."
            return
        }
        songs[i].audioPath = url.path
        songs[i].audioDuration = duration
        songs[i].audioLTCChannel = nil
        songs[i].audioOffset = nil
        message = nil
        layoutChanged()
        adopt(audio: url.path)
    }

    /// Plays from the original now; once the copy is in the project, switches every song using
    /// it over (the analysis carries across, keyed by file name, size and date).
    private func adopt(audio path: String) {
        adoptAudio?(path) { [weak self] copy in
            guard let self, copy != path else { return }
            var changed = false
            for i in self.songs.indices where self.songs[i].audioPath == path {
                self.songs[i].audioPath = copy
                changed = true
            }
            if let a = self.analyses[path] { self.analyses[copy] = a }
            if changed { self.layoutChanged() }
        }
    }

    /// Copies every song's audio that's outside the project into it.
    func collectAudio() {
        let outside = Set(songs.compactMap(\.audioPath))
        for path in outside { adopt(audio: path) }
    }

    func chooseAudio(for id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url { attachAudio(url, to: id) }
    }

    func removeAudio(from id: UUID) {
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        songs[i].audioPath = nil
        songs[i].audioDuration = nil
        layoutChanged()
    }

    /// Reorders the set. Offsets are positions within the set.
    func move(from source: IndexSet, to destination: Int) {
        let current = currentSongID
        var set = setSongs
        set.move(fromOffsets: source, toOffset: destination)
        songs = set + librarySongs
        layoutChanged()
        // Keep the playhead on the same song after a reorder.
        if let current, let i = layout.items.firstIndex(where: { $0.song.id == current }) {
            seek(to: layout.items[i].timelineStart - gap)
        }
    }

    /// Deletes a song from the library altogether.
    func remove(_ id: UUID) {
        songs.removeAll { $0.id == id }
        layoutChanged()
    }

    /// Adds a library song to the end of the set.
    func addToSet(_ id: UUID) {
        guard let i = songs.firstIndex(where: { $0.id == id }), !songs[i].inSet else { return }
        var song = songs.remove(at: i)
        song.inSet = true
        songs = setSongs + [song] + librarySongs
        layoutChanged()
    }

    /// Takes a song off the set; it stays in the library.
    func removeFromSet(_ id: UUID) {
        guard let i = songs.firstIndex(where: { $0.id == id }), songs[i].inSet else { return }
        songs[i].inSet = false
        songs = SongLibrary.arranged(songs, rate: rate)
        layoutChanged()
    }

    func clearSet() {
        for i in songs.indices { songs[i].inSet = false }
        songs = SongLibrary.arranged(songs, rate: rate)
        stop()
        seek(to: 0)
        layoutChanged()
    }

    /// Puts the set in show order (by start timecode).
    func sortByShowOrder() {
        let set = setSongs.sorted { $0.start.frameIndex(at: rate) < $1.start.frameIndex(at: rate) }
        songs = set + librarySongs
        layoutChanged()
    }

    /// Starts analysing any attached audio not analysed yet: timecode, clean copies, waveform.
    private func analyzeAudio() {
        let rate = self.rate
        let root = analysisRoot
        for path in Set(songs.compactMap(\.audioPath)) where analyses[path] == nil && !analyzing.contains(path) {
            analyzing.insert(path)
            Task.detached(priority: .utility) {
                let analysis = AudioAnalyzer.analyze(path: path, rate: rate, root: root)
                await MainActor.run { [weak self] in
                    guard let self, self.rate == rate else { return }
                    self.analyzing.remove(path)
                    if let analysis { self.apply(analysis, to: path) }
                }
            }
        }
    }

    /// Takes in a finished analysis: which channel is timecode, and where the audio sits by it.
    private func apply(_ analysis: AudioAnalysis, to path: String) {
        analyses[path] = analysis
        var changed = false
        for i in songs.indices where songs[i].audioPath == path {
            let channel = analysis.ltc?.channel
            let offset = analysis.ltc?.offset(fromSongStart: songs[i].start.seconds(at: rate))
            if songs[i].audioLTCChannel != channel || songs[i].audioOffset != offset {
                songs[i].audioLTCChannel = channel
                songs[i].audioOffset = offset
                changed = true
            }
            // A tempo heard in the audio fills in songs without one of yours: when it's clear, or
            // the file's name gave it. Yours (typed in, or a downbeat you set) are never replaced.
            if let tempo = analysis.tempo, songs[i].bpm == nil || songs[i].bpmDetected == true,
               tempo.isConfident || SongTempo.bpm(fromFileName: (path as NSString).lastPathComponent) != nil {
                let downbeat = (offset ?? 0) + tempo.downbeat
                if songs[i].bpm != tempo.bpm || songs[i].downbeat != downbeat || songs[i].bpmDetected != true {
                    songs[i].bpm = tempo.bpm
                    songs[i].downbeat = downbeat
                    songs[i].bpmDetected = true
                    tempoFound += 1
                    changed = true
                }
            }
        }
        if changed { layoutChanged() }
        if analyzing.isEmpty { summarizeTimecode() }
    }

    /// Songs given a tempo by listening, since the last summary.
    private var tempoFound = 0

    /// One line on what the scans found, once they've all finished.
    private func summarizeTimecode() {
        if tempoFound > 0 {
            message = "Tempo heard in \(tempoFound) song\(tempoFound == 1 ? "" : "s") (GRID shows ≈). Check one with right-click › Tempo…: half, double or ¾ speed are one click."
            tempoFound = 0
        }
        let withCode = songs.filter { $0.audioLTCChannel != nil }
        guard !withCode.isEmpty else { return }
        let mismatched = withCode.filter { $0.audioOffset == nil }.map(\.name)
        var text = "Timecode found in \(withCode.count) track\(withCode.count == 1 ? "" : "s"): muted on the music output"
        text += useTrackTimecode ? ", played to LTC out, and the audio lined up by it." : ", and the audio lined up by it."
        if !mismatched.isEmpty {
            text += " The timecode in \(mismatched.joined(separator: ", ")) doesn't match the song list (over a minute apart), so those follow the song list."
        }
        message = text
    }

    /// Play the track's timecode channel to the music output anyway (normally muted).
    func toggleKeepLTCChannel(_ id: UUID) {
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        songs[i].keepLTCChannel.toggle()
        layoutChanged()
    }

    /// What plays for each song: its music without the timecode channel (unless kept), and its
    /// own timecode for LTC out when that code is trusted and Settings says to use it.
    /// Everything another thread needs to render the timeline (the AES67 sender).
    struct RenderState: Sendable, Equatable {
        var layout: TimelineLayout
        var transport: TimelineTransport
        var sources: [UUID: SongSources]
        var rate: FrameRate
        var scrubbing: Bool
    }

    func renderState() -> RenderState {
        RenderState(layout: layout, transport: transport, sources: playbackSources(), rate: rate, scrubbing: isScrubbing)
    }

    private func playbackSources() -> [UUID: SongSources] {
        var out: [UUID: SongSources] = [:]
        for song in setSongs {
            guard let path = song.audioPath else { continue }
            let analysis = analyses[path]
            var music: String? = path
            if song.audioLTCChannel != nil, !song.keepLTCChannel, let analysis {
                music = analysis.musicPath    // nil when the file is only timecode
            }
            let code = useTrackTimecode && song.audioOffset != nil ? analysis?.ltcPath : nil
            out[song.id] = SongSources(music: music, timecode: code)
        }
        return out
    }

    // MARK: Finding audio

    func chooseAudioFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "A folder with the songs' audio. Files are matched to songs by name, including subfolders."
        if panel.runModal() == .OK, let url = panel.url { findAudio(in: url) }
    }

    /// Searches `folder` (and its subfolders) for audio files and attaches them by name to songs
    /// that don't have audio yet.
    func findAudio(in folder: URL) {
        message = "Looking for audio in \(folder.lastPathComponent)…"
        Task.detached(priority: .userInitiated) {
            let files = Self.audioFiles(in: folder)
            await MainActor.run { [weak self] in self?.attachFound(files, folder: folder) }
        }
    }

    private func attachFound(_ files: [String], folder: URL) {
        let needing = songs.filter { $0.audioPath == nil }
        let matched = AudioMatcher.match(songs: needing.map(\.name), files: files)
        var attached = 0
        for song in needing {
            guard let path = matched[song.name], let i = songs.firstIndex(where: { $0.id == song.id }),
                  let duration = TimelinePlayer.duration(of: URL(fileURLWithPath: path)), duration > 0 else { continue }
            songs[i].audioPath = path
            songs[i].audioDuration = duration
            songs[i].audioLTCChannel = nil
            songs[i].audioOffset = nil
            attached += 1
            adopt(audio: path)
        }
        let missing = songs.filter { $0.audioPath == nil }
        let missingOnSet = missing.filter(\.inSet).map(\.name)
        var text = "Found audio for \(attached) song\(attached == 1 ? "" : "s") in \(folder.lastPathComponent) (\(files.count) audio files)."
        if !missingOnSet.isEmpty {
            text += " Still no audio on the set: \(missingOnSet.joined(separator: ", "))."
        } else if !missing.isEmpty {
            text += " \(missing.count) library songs still have no audio."
        }
        message = text
        if attached > 0 { layoutChanged() }
    }

    nonisolated private static func audioFiles(in folder: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var out: [String] = []
        for case let url as URL in walker where AudioMatcher.extensions.contains(url.pathExtension.lowercased()) {
            out.append(url.path)
            if out.count >= 20_000 { break }
        }
        return out
    }

    // MARK: Setlists

    /// Starts an empty setlist and makes it current.
    func newSetlist(named name: String) {
        let list = Setlist(name: name.isEmpty ? "Set \(setlists.count + 1)" : name)
        setlists.append(list)
        currentSetlistID = list.id
        songs = SongLibrary.applying(list, to: songs, rate: rate)
        stop()
        seek(to: 0)
        layoutChanged()
    }

    /// Saves the set as it stands under a new name and makes that current.
    func saveSetAs(_ name: String) {
        let list = Setlist(name: name.isEmpty ? "Set \(setlists.count + 1)" : name, songs: setSongs.map(\.name))
        setlists.append(list)
        currentSetlistID = list.id
        save()
    }

    func selectSetlist(_ id: UUID) {
        guard let list = setlists.first(where: { $0.id == id }) else { return }
        currentSetlistID = id
        songs = SongLibrary.applying(list, to: songs, rate: rate)
        stop()
        seek(to: 0)
        layoutChanged()
    }

    func renameSetlist(_ id: UUID, to name: String) {
        guard let i = setlists.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        setlists[i].name = name
        save()
    }

    /// Deletes a saved setlist. The set on screen stays as it is, unsaved.
    func deleteSetlist(_ id: UUID) {
        setlists.removeAll { $0.id == id }
        if currentSetlistID == id { currentSetlistID = nil }
        save()
    }

    // MARK: Running order

    /// Puts the set in the order its songs played in a recorded take, from the take's map: songs
    /// the take recorded go on the set by where they started in it; the rest go to the library.
    @discardableResult
    func orderSet(by map: TakeMap, takeName: String) -> Int {
        let lengths = TimelineLayout(ordered: songs, rate: rate, gap: 0, library: songs).items
        let candidates = lengths.map { (id: $0.song.id, start: $0.showStart, length: $0.duration) }
        let placed = RunningOrder.placed(songs: candidates, in: map)
        guard !placed.isEmpty else {
            message = "\(takeName) has no song timecode in it, so the set wasn't reordered."
            return 0
        }
        let order = placed.map(\.id)
        var set: [Song] = []
        for id in order {
            guard let i = songs.firstIndex(where: { $0.id == id }) else { continue }
            var song = songs[i]
            song.inSet = true
            set.append(song)
        }
        let rest = songs.filter { !order.contains($0.id) }.map { s -> Song in var song = s; song.inSet = false; return song }
        songs = set + SongLibrary.arranged(rest, rate: rate)
        message = "Set ordered by \(takeName): \(set.count) song\(set.count == 1 ? "" : "s") in the order they played."
        stop()
        seek(to: 0)
        layoutChanged()
        return set.count
    }

    private func layoutChanged() {
        // The current setlist follows the set.
        if let i = setlists.firstIndex(where: { $0.id == currentSetlistID }) {
            let names = setSongs.map(\.name)
            if setlists[i].songs != names { setlists[i].songs = names }
        }
        analyzeAudio()
        layout = TimelineLayout(ordered: setSongs, rate: rate, gap: gap, downtime: downtime, library: songs)
        player.update(layout: layout)
        var paths = Set(songs.compactMap(\.audioPath))
        for analysis in analyses.values {
            if let p = analysis.musicPath { paths.insert(p) }
            if let p = analysis.ltcPath { paths.insert(p) }
        }
        player.prune(keeping: paths)
        if isPlaying { restartPlayback() }
        save()
    }

    // MARK: Transport

    private func refreshCurrent() {
        let index = layout.index(at: head.position)
        if index != currentIndex { currentIndex = index }
    }
    var currentSongID: UUID? { currentIndex.map { layout.items[$0].song.id } }

    /// Show timecode under the playhead.
    var showTimecode: Timecode? {
        layout.showSeconds(at: playhead).map { Timecode(frameIndex: Int(($0 * rate.exact).rounded(.down)), rate: rate) }
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard !layout.items.isEmpty else { return }
        if playhead >= layout.totalDuration { seek(to: 0) }
        // A short lead so audio, LTC and decks all start on the same instant.
        let start = HostClock.now() + 0.12
        transport.seek(to: playhead, at: start)
        transport.play(at: start)
        isPlaying = true
        player.start(layout: layout, from: playhead, at: start, sources: playbackSources())
    }

    func pause() {
        scrubSettle?.cancel()
        scrubSettle = nil
        isScrubbing = false
        let now = HostClock.now()
        transport.pause(at: now)
        isPlaying = false
        player.stop()
        playhead = transport.position(at: now)
    }

    func stop() {
        if isPlaying { pause() }
    }

    func seek(to t: Double) {
        let clamped = min(max(0, t), max(0, layout.totalDuration - 0.001))
        playhead = clamped
        seekCount &+= 1
        if isPlaying {
            restartPlayback()
        } else {
            transport.seek(to: clamped, at: HostClock.now())
        }
    }

    /// Moves by whole show-code frames (negative = back).
    func step(frames: Int) {
        if isPlaying { pause() }
        seek(to: playhead + Double(frames) / rate.exact)
    }

    /// Horizontal scroll over the whole set: moves the playhead by `seconds`. While playing it
    /// keeps playing from the new spot (audio silent until the swipe settles).
    func scrub(by seconds: Double) {
        scrub(to: playhead + seconds)
    }

    /// Drag, swipe or click to a spot. Paused: a plain seek. Playing: the transport jumps there and
    /// keeps running, so the decks follow, while song audio and LTC out stay silent until the
    /// gesture has been still for a moment, then start again in place.
    func scrub(to t: Double) {
        guard isPlaying else {
            seek(to: t)
            return
        }
        let clamped = min(max(0, t), max(0, layout.totalDuration - 0.001))
        if !isScrubbing {
            isScrubbing = true
            player.stop()
        }
        transport.seek(to: clamped, at: HostClock.now())
        playhead = clamped
        seekCount &+= 1
        scrubSettle?.cancel()
        scrubSettle = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.endScrub()
        }
    }

    /// The scrub settled (or a drag ended): audio and LTC out start again where the transport is.
    func endScrub() {
        scrubSettle?.cancel()
        scrubSettle = nil
        guard isScrubbing else { return }
        isScrubbing = false
        resumeAudioAfterReroute()
    }

    private var scrollRemainder = 0.0

    /// Horizontal scroll over the current song: whole frames. Trackpad points accumulate
    /// (`pointsPerFrame` each); a wheel notch is one frame.
    func scrollFrames(_ physical: Double, precise: Bool, pointsPerFrame: Double = 5) {
        let frames: Int
        if precise {
            scrollRemainder += physical / pointsPerFrame
            // A hair of slack so 0.4 + 0.6 counts as a whole frame despite floating-point error.
            frames = Int((scrollRemainder + (scrollRemainder >= 0 ? 1e-9 : -1e-9)).rounded(.towardZero))
            scrollRemainder -= Double(frames)
        } else {
            frames = physical > 0 ? max(1, Int(physical.rounded())) : min(-1, Int(physical.rounded()))
        }
        guard frames != 0 else { return }
        // Playing: nudge the running timeline instead of stopping it.
        if isPlaying {
            scrub(by: Double(frames) / rate.exact)
        } else {
            step(frames: frames)
        }
    }

    func nextSong() {
        if let t = layout.nextSongStart(after: playhead) { seek(to: t) }
    }

    func previousSong() {
        if let t = layout.previousSongStart(before: playhead) { seek(to: t) }
    }

    func jump(toSong index: Int) {
        if let t = layout.timelineTime(song: index) { seek(to: t) }
    }

    /// The outputs changed under a playing timeline: start the audio again where the transport is
    /// now, without moving the transport (decks and show code carry on undisturbed).
    func resumeAudioAfterReroute() {
        guard isPlaying else { return }
        let start = HostClock.now() + 0.05
        player.start(layout: layout, from: transport.position(at: start), at: start, sources: playbackSources())
    }

    private func restartPlayback() {
        let start = HostClock.now() + 0.12
        transport.seek(to: playhead, at: start)
        player.start(layout: layout, from: playhead, at: start, sources: playbackSources())
    }

    /// Show code (LTC frames at the show rate) at host time `t`, while playing; nil when stopped
    /// or past the set. Same code LTC out is sending.
    func showFrames(at t: Double) -> Double? {
        guard isPlaying, let show = layout.showSeconds(at: transport.position(at: t)) else { return nil }
        return show * rate.exact
    }

    /// Called by the app's loop: what the chase engine sees, and the playhead for the UI.
    func snapshot(at now: Double) -> LTCSnapshot {
        // Loop back or stop after a song, before the chase engine sees the new position.
        if isPlaying, !isScrubbing {
            let t = transport.position(at: now)
            if let previous = lastPlayPosition {
                switch layout.transition(from: previous, to: t, loop: loop, stopAfterSong: stopAfterSong) {
                case .jump(let to): jumpWhilePlaying(to: to)
                case .stop(let at):
                    pause()
                    seek(to: at)
                case .none: break
                }
            }
        }
        lastPlayPosition = isPlaying && !isScrubbing ? transport.position(at: now) : nil
        // Into a downtime: the decks park on the next song's lead-in once.
        let downtimeNow = isPlaying ? layout.downtimeSong(at: transport.position(at: now)) : nil
        if downtimeNow != downtimeSong {
            downtimeSong = downtimeNow
            if downtimeNow != nil { seekCount &+= 1 }
        }
        let snap = transport.snapshot(at: now, layout: layout)
        if isPlaying {
            let t = transport.position(at: now)
            if t >= layout.totalDuration {
                pause()
                playhead = layout.totalDuration
            } else if abs(t - playhead) >= 1.0 / 30 {
                playhead = max(0, t)
            }
        }
        return snap
    }

    private var lastPlayPosition: Double?
    /// Playing through the downtime before this song (nil otherwise).
    @Published private(set) var downtimeSong: Int?

    /// Show code the decks should be parked on: under the playhead, or in downtime the next
    /// song's first lead-in frame, so they're ready when its code starts.
    var parkShowSeconds: Double? {
        if let i = downtimeSong ?? layout.downtimeSong(at: playhead) { return layout.showSeconds(at: layout.leadInStart(i)) }
        return layout.showSeconds(at: playhead)
    }

    /// The current song's zoom, 1 (whole song) to `maxZoom`.
    func setZoom(_ z: Double) {
        let clamped = min(max(1, z), Self.maxZoom)
        if abs(clamped - detailZoom) > 0.001 { detailZoom = clamped }
    }

    // MARK: Loops

    /// The loop's range on the timeline now (for drawing), if one is on.
    var loopRange: Range<Double>? { layout.loopRange(loop, at: playhead) }

    func setLoop(_ mode: LoopSetting.Mode) {
        if mode == .section, !loop.hasSection {
            message = "Set a section first: I at its start, O at its end (or select two markers › Loop Between Them)."
            return
        }
        loop.mode = mode
    }

    /// Loop off and its section forgotten (the × on the loop, ⇧L).
    func clearLoop() {
        loop = LoopSetting()
        message = nil
    }

    /// L: loop off, or back to the last kind of loop (the song if none).
    func toggleLoop() {
        if loop.mode != .off { lastLoopMode = loop.mode; loop.mode = .off } else { loop.mode = lastLoopMode == .section && loop.hasSection ? .section : .song }
    }
    private var lastLoopMode: LoopSetting.Mode = .song

    /// I and O: a section end at the playhead, on show code.
    func setLoopIn() { setLoopEnd(start: true) }
    func setLoopOut() { setLoopEnd(start: false) }

    private func setLoopEnd(start: Bool) {
        let t = isPlaying ? transport.position(at: HostClock.now()) : playhead
        guard let show = layout.showSeconds(at: t) else {
            message = "Loop points go on a song: move the playhead onto the set first."
            return
        }
        var next = loop
        if start { next.sectionStart = show } else { next.sectionEnd = show }
        // A new start after the old end (or the other way round) starts a fresh section.
        if let a = next.sectionStart, let b = next.sectionEnd, a >= b {
            if start { next.sectionEnd = nil } else { next.sectionStart = nil }
        }
        if next.hasSection { next.mode = .section }
        loop = next
        message = next.hasSection ? nil : (start ? "Loop in set. Press O at the end of the section." : "Loop out set. Press I at the start of the section.")
    }

    /// A section loop between two timeline times (dragged along the ruler).
    func setLoopSection(from a: Double, to b: Double) {
        guard let s = layout.showSeconds(at: min(a, b)), let e = layout.showSeconds(at: max(a, b)), e - s >= 0.1 else { return }
        loop = LoopSetting(mode: .section, sectionStart: s, sectionEnd: e)
        message = nil
    }

    /// Loop from the first selected marker to the last.
    func loopSelectedMarkers() {
        let frames = selectedMarkers.map(\.frame)
        guard let lo = frames.min(), let hi = frames.max(), hi > lo else {
            message = "Select two or more markers to loop between them."
            return
        }
        loop = LoopSetting(mode: .section, sectionStart: Double(lo) / rate.exact, sectionEnd: Double(hi) / rate.exact)
    }

    // MARK: Markers

    /// Visible markers on the set, in timeline order, with their timeline time.
    var placedMarkers: [(marker: Marker, time: Double)] {
        layout.placed(markers.filter { !hiddenMarkerKinds.contains($0.kind) })
    }

    /// Adds a marker at the playhead (its show code). Returns it, or nil off the set.
    @discardableResult
    func addMarker(_ kind: MarkerKind? = nil, label: String = "") -> Marker? {
        let kind = kind ?? lastMarkerKind
        lastKind = kind
        // While playing, the transport is ahead of the last UI refresh: read it now.
        let t = isPlaying ? transport.position(at: HostClock.now()) : playhead
        guard let show = layout.showSeconds(at: t) else {
            message = "Markers go on a song: move the playhead onto the set first."
            return nil
        }
        let marker = Marker(frame: Int((show * rate.exact).rounded()), kind: kind, label: label)
        markers.append(marker)
        markers.sort { $0.frame < $1.frame }
        hiddenMarkerKinds.remove(kind)
        selectedMarkerID = marker.id
        save()
        return marker
    }

    func updateMarker(_ id: UUID, kind: MarkerKind? = nil, label: String? = nil, frame: Int? = nil) {
        guard let i = markers.firstIndex(where: { $0.id == id }) else { return }
        if let kind { markers[i].kind = kind; lastKind = kind }
        if let label { markers[i].label = label }
        if let frame { markers[i].frame = max(0, frame) }
        markers.sort { $0.frame < $1.frame }
        save()
    }

    func removeMarker(_ id: UUID) {
        markers.removeAll { $0.id == id }
        selectedMarkerIDs.remove(id)
        if selectedMarkerID == id { selectedMarkerID = nil }
        save()
    }

    // MARK: Tempo and beat grid

    /// The song's grid, if it has a tempo.
    func grid(for song: Song) -> BeatGrid? { BeatGrid(song: song, rate: rate) }

    /// A tempo to offer for a song: its own, else one in its audio file's name.
    func suggestedBPM(_ song: Song) -> Double? {
        song.bpm ?? song.audioPath.flatMap { SongTempo.bpm(fromFileName: ($0 as NSString).lastPathComponent) }
            ?? heardTempo(song)?.bpm
    }

    /// What listening to the song's audio found (also when it wasn't clear enough to use).
    func heardTempo(_ song: Song) -> TempoEstimate? {
        song.audioPath.flatMap { analyses[$0]?.tempo }
    }

    func setTempo(_ id: UUID, bpm: Double?, beatsPerBar: Int? = nil) {
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        songs[i].bpm = bpm.flatMap { $0 > 0 ? $0 : nil }
        if let beatsPerBar { songs[i].beatsPerBar = beatsPerBar == 4 ? nil : max(1, beatsPerBar) }
        songs[i].bpmDetected = nil
        songDetailsChanged()
    }

    /// A song's tempo or downbeat changed: the laid-out set carries copies of the songs (the
    /// views read the grid from them), so lay it out again. Timing is unchanged, so playback
    /// carries on without a restart.
    private func songDetailsChanged() {
        layout = TimelineLayout(ordered: setSongs, rate: rate, gap: gap, downtime: downtime, library: songs)
        player.update(layout: layout)
        save()
    }

    /// The bar starts on the playhead (lines the grid up with the music).
    func setDownbeatAtPlayhead() {
        guard let index = currentIndex, layout.items.indices.contains(index) else { return }
        let item = layout.items[index]
        guard let i = songs.firstIndex(where: { $0.id == item.song.id }) else { return }
        let t = isPlaying ? transport.position(at: HostClock.now()) : playhead
        songs[i].downbeat = t - item.timelineStart
        songs[i].bpmDetected = nil
        songDetailsChanged()
    }

    /// The set song a marker sits in.
    func song(of marker: Marker) -> TimelineLayout.Item? {
        guard let t = time(of: marker), let i = layout.index(at: t) else { return nil }
        return layout.items[i]
    }

    enum ArrayExtent: Equatable {
        case count(Int), nextMarker, songEnd, loopEnd
    }

    /// Hits every `note` after `anchor`, of the anchor's type and label, as one array that can be
    /// cleared at once. Never past the anchor's song. Returns how many were added.
    @discardableResult
    func arrayMarkers(from anchor: Marker, bpm: Double, note: NoteValue, extent: ArrayExtent) -> Int {
        guard let item = song(of: anchor) else {
            message = "That marker isn't on a song in the set."
            return 0
        }
        let fps = rate.ltcRate.exact
        let songEnd = Int(((item.showStart + item.duration) * fps).rounded(.down))
        var end = songEnd
        var count: Int?
        switch extent {
        case .count(let n): count = max(1, n)
        case .songEnd: break
        case .nextMarker:
            if let next = markers.filter({ $0.arrayID == nil && $0.frame > anchor.frame }).map(\.frame).min() { end = min(end, next) }
        case .loopEnd:
            if let r = loopRange, let show = layout.showSeconds(at: r.upperBound - 0.0001) { end = min(end, Int((show * fps).rounded())) }
        }
        if let song = songs.first(where: { $0.id == item.song.id }), song.bpm == nil { setTempo(song.id, bpm: bpm) }
        let perBar = songs.first(where: { $0.id == item.song.id })?.beatsPerBar ?? 4
        let frames = MarkerArray.frames(after: anchor.frame, bpm: bpm, stepBeats: note.beats(perBar: perBar), rate: rate,
                                        count: count, before: end)
        guard !frames.isEmpty else {
            message = "No room for hits there before the \(extent == .nextMarker ? "next marker" : "end")."
            return 0
        }
        let id = UUID()
        let hits = frames.map { Marker(frame: $0, kind: anchor.kind, label: anchor.label, arrayID: id, arrayStep: note.short) }
        markers += hits
        markers.sort { $0.frame < $1.frame }
        hiddenMarkerKinds.remove(anchor.kind)
        showGrid = true
        // Selected, so they stand out (and can be dragged together, or cleared from the list).
        selectedMarkerIDs = Set(hits.map(\.id))
        selectedMarkerID = hits.first?.id
        message = "Added \(frames.count) \(timeline_typeName(anchor.kind)) hits, every \(note.short) at \(Self.bpmText(bpm)) BPM. Clear them from any of them (right-click › Clear Array)."
        save()
        return frames.count
    }

    private func timeline_typeName(_ kind: MarkerKind) -> String { markerTypes.name(kind) }

    static func bpmText(_ bpm: Double) -> String {
        bpm == bpm.rounded() ? String(Int(bpm)) : String(format: "%.1f", bpm)
    }

    /// Every array's markers, by array.
    var markerArrays: [UUID: [Marker]] {
        Dictionary(grouping: markers.filter { $0.arrayID != nil }, by: { $0.arrayID! })
    }

    func clearArray(_ id: UUID) {
        let ids = Set(markers.filter { $0.arrayID == id }.map(\.id))
        removeMarkers(ids)
        message = "Cleared \(ids.count) arrayed markers."
    }

    /// Every arrayed marker (in `song`, or everywhere); hand-placed ones stay.
    func clearArrays(inSong song: UUID? = nil) {
        let ids = Set(markers.filter { m in
            m.arrayID != nil && (song == nil || self.song(of: m)?.song.id == song)
        }.map(\.id))
        removeMarkers(ids)
        message = ids.isEmpty ? nil : "Cleared \(ids.count) arrayed markers."
    }

    // MARK: Several markers

    var selectedMarkers: [Marker] { markers.filter { selectedMarkerIDs.contains($0.id) } }

    /// Click: just this one. ⌘: add or remove it. ⇧: everything from the anchor to it, in `order`.
    func select(_ id: UUID, toggle: Bool = false, extendIn order: [UUID]? = nil) {
        if let order, let anchor = selectedMarkerID, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
            selectedMarkerIDs.formUnion(order[min(a, b)...max(a, b)])
        } else if toggle {
            if selectedMarkerIDs.contains(id) {
                selectedMarkerIDs.remove(id)
                if selectedMarkerID == id { selectedMarkerID = selectedMarkerIDs.first }
            } else {
                selectedMarkerIDs.insert(id)
                selectedMarkerID = id
            }
        } else {
            selectedMarkerIDs = [id]
            selectedMarkerID = id
        }
    }

    func selectMarkers(_ ids: [UUID]) {
        selectedMarkerIDs = Set(ids)
        if let first = ids.first, selectedMarkerID.map({ !selectedMarkerIDs.contains($0) }) ?? true { selectedMarkerID = first }
    }

    func clearMarkerSelection() {
        selectedMarkerIDs = selectedMarkerID.map { [$0] } ?? []
    }

    /// Change the type, the label, or move by whole frames, for every one of `ids` at once.
    func updateMarkers(_ ids: Set<UUID>, kind: MarkerKind? = nil, label: String? = nil, moveFrames: Int = 0) {
        guard !ids.isEmpty else { return }
        for i in markers.indices where ids.contains(markers[i].id) {
            if let kind { markers[i].kind = kind }
            if let label { markers[i].label = label }
            if moveFrames != 0 { markers[i].frame = max(0, markers[i].frame + moveFrames) }
        }
        if let kind { lastKind = kind; hiddenMarkerKinds.remove(kind) }
        markers.sort { $0.frame < $1.frame }
        save()
    }

    func removeMarkers(_ ids: Set<UUID>) {
        markers.removeAll { ids.contains($0.id) }
        selectedMarkerIDs.subtract(ids)
        if let id = selectedMarkerID, ids.contains(id) { selectedMarkerID = nil }
        save()
    }

    /// How many markers have each type.
    func markerCount(_ kind: MarkerKind) -> Int { markers.filter { $0.kind == kind }.count }

    /// Removes a type; its markers move to `moveTo`, or go with it when nil.
    func removeMarkerType(_ kind: MarkerKind, moveTo: MarkerKind?) {
        guard markerTypes.types.count > 1 else { return }
        if let moveTo {
            for i in markers.indices where markers[i].kind == kind { markers[i].kind = moveTo }
        } else {
            markers.removeAll { $0.kind == kind }
        }
        hiddenMarkerKinds.remove(kind)
        markerTypes.types.removeAll { $0.id == kind }
        save()
    }

    /// Replaces every marker (e.g. from a project or an import).
    func setMarkers(_ list: [Marker]) {
        markers = list.sorted { $0.frame < $1.frame }
        save()
    }

    /// Timeline time of a marker on the current set, if its song is on it.
    func time(of marker: Marker) -> Double? {
        layout.timelineTime(forShowSeconds: marker.seconds(rate: rate))
    }

    /// Jumps to a marker (keeps playing if playing).
    func go(to marker: Marker) {
        selectedMarkerIDs = [marker.id]
        selectedMarkerID = marker.id
        if let t = time(of: marker) { isPlaying ? jumpWhilePlaying(to: t) : seek(to: t) }
    }

    func nextMarker() {
        var now = isPlaying ? transport.position(at: HostClock.now()) : playhead
        // Just jumped to the selected marker: step past it even if the playhead has landed (or,
        // while audio restarts, still reads) a hair before it.
        if let selected = placedMarkers.first(where: { $0.marker.id == selectedMarkerID }),
           abs(selected.time - now) < 0.25 { now = max(now, selected.time) }
        if let next = placedMarkers.first(where: { $0.time > now + 0.02 }) { go(to: next.marker) }
    }

    func previousMarker() {
        let now = isPlaying ? transport.position(at: HostClock.now()) : playhead
        // Back past one just passed (half a second of grace, like a CD player).
        if let prev = placedMarkers.last(where: { $0.time < now - 0.5 }) { go(to: prev.marker) }
    }

    /// A single jump while playing: the transport moves and audio restarts there at once.
    private func jumpWhilePlaying(to t: Double) {
        scrub(to: t)
        endScrub()
    }

    // MARK: Persistence

    /// Understudy's folder in Application Support.
    /// Where the timeline, audio analysis and take maps are kept. `UNDERSTUDY_STORE` overrides it,
    /// so test harnesses never touch the real store.
    nonisolated static var storeDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["UNDERSTUDY_STORE"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Understudy", isDirectory: true)
    }

    /// The show as it stands, for the project file.
    func content() -> ShowContent {
        ShowContent(songs: songs, gap: gap, setlists: setlists, currentSetlist: currentSetlistID,
                    autoOrderFromTakes: autoOrderFromTakes, markers: markers,
                    hiddenMarkerKinds: hiddenMarkerKinds.sorted { $0.rawValue < $1.rawValue },
                    markerTypes: markerTypes == .defaults ? nil : markerTypes,
                    downtime: downtime > 0 ? downtime : nil, stopAfterSong: stopAfterSong ? true : nil,
                    loop: loop == LoopSetting() ? nil : loop)
    }

    /// Opens a show (paths already resolved to absolute).
    func load(_ stored: ShowContent) {
        loading = true
        defer { loading = false }
        stop()
        analyses = [:]
        analyzing = []
        songs = SongLibrary.arranged(stored.songs, rate: rate)
        gap = stored.gap
        setlists = stored.setlists ?? []
        currentSetlistID = stored.currentSetlist.flatMap { id in setlists.contains { $0.id == id } ? id : nil }
        autoOrderFromTakes = stored.autoOrderFromTakes ?? false
        markers = stored.markers ?? []
        hiddenMarkerKinds = Set(stored.hiddenMarkerKinds ?? [])
        markerTypes = stored.markerTypes ?? .defaults
        downtime = stored.downtime ?? 0
        stopAfterSong = stored.stopAfterSong ?? false
        loop = stored.loop ?? LoopSetting()
        detailZoom = 1
        lastKind = nil
        selectedMarkerID = nil
        selectedMarkerIDs = []
        message = nil
        layout = TimelineLayout(ordered: setSongs, rate: rate, gap: gap, downtime: downtime, library: songs)
        player.update(layout: layout)
        seek(to: 0)
        analyzeAudio()
    }

    /// The show saved before projects (Application Support/Understudy/timeline.json), to bring into
    /// a first project.
    static func legacyContent() -> ShowContent? {
        guard let data = try? Data(contentsOf: storeDirectory.appendingPathComponent("timeline.json")) else { return nil }
        return try? JSONDecoder().decode(ShowContent.self, from: data)
    }

    private var loading = false

    private func save() {
        guard !loading else { return }
        onChange?()
    }
}

/// The timeline's playhead on its own, so only views that draw it redraw as it moves.
@MainActor
final class PlayheadClock: ObservableObject {
    @Published var position: Double = 0
}
