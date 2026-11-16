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

    init() {
        load()
    }

    // MARK: Playlist

    func importCSV(from url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
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
        for path in Set(songs.compactMap(\.audioPath)) where analyses[path] == nil && !analyzing.contains(path) {
            analyzing.insert(path)
            Task.detached(priority: .utility) {
                let analysis = AudioAnalyzer.analyze(path: path, rate: rate)
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
        }
        if changed { layoutChanged() }
        if analyzing.isEmpty { summarizeTimecode() }
    }

    /// One line on what the scans found, once they've all finished.
    private func summarizeTimecode() {
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
        layout = TimelineLayout(ordered: setSongs, rate: rate, gap: gap, library: songs)
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

    // MARK: Persistence

    private struct Stored: Codable {
        var songs: [Song]
        var gap: Double
        var setlists: [Setlist]?
        var currentSetlist: UUID?
        var autoOrderFromTakes: Bool?
    }

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

    private static var fileURL: URL { storeDirectory.appendingPathComponent("timeline.json") }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        songs = SongLibrary.arranged(stored.songs, rate: rate)
        gap = stored.gap
        setlists = stored.setlists ?? []
        currentSetlistID = stored.currentSetlist.flatMap { id in setlists.contains { $0.id == id } ? id : nil }
        autoOrderFromTakes = stored.autoOrderFromTakes ?? false
        layout = TimelineLayout(ordered: setSongs, rate: rate, gap: gap, library: songs)
        player.update(layout: layout)
        analyzeAudio()
    }

    private func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stored = Stored(songs: songs, gap: gap, setlists: setlists, currentSetlist: currentSetlistID,
                            autoOrderFromTakes: autoOrderFromTakes)
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// The timeline's playhead on its own, so only views that draw it redraw as it moves.
@MainActor
final class PlayheadClock: ObservableObject {
    @Published var position: Double = 0
}
