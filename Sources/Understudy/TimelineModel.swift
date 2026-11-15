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
    /// Timeline seconds, refreshed by the app's loop.
    @Published private(set) var playhead: Double = 0
    @Published private(set) var isPlaying = false
    @Published var message: String?

    /// Show timecode rate the songs and decks count in (the show LTC rate).
    var rate: FrameRate = .fps30 {
        didSet { if rate != oldValue { layoutChanged() } }
    }
    private(set) var layout = TimelineLayout(ordered: [], rate: .fps30)
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

    private func layoutChanged() {
        layout = TimelineLayout(ordered: setSongs, rate: rate, gap: gap, library: songs)
        player.update(layout: layout)
        player.prune(keeping: songs)
        if isPlaying { restartPlayback() }
        save()
    }

    // MARK: Transport

    var currentIndex: Int? { layout.index(at: playhead) }
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
        player.start(layout: layout, from: playhead, at: start)
    }

    func pause() {
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

    /// Horizontal scroll over the whole set: moves the playhead by `seconds` (pauses first).
    func scrub(by seconds: Double) {
        if isPlaying { pause() }
        seek(to: playhead + seconds)
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
        step(frames: frames)
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

    private func restartPlayback() {
        let start = HostClock.now() + 0.12
        transport.seek(to: playhead, at: start)
        player.start(layout: layout, from: playhead, at: start)
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
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Understudy", isDirectory: true).appendingPathComponent("timeline.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        songs = SongLibrary.arranged(stored.songs, rate: rate)
        gap = stored.gap
        layout = TimelineLayout(ordered: setSongs, rate: rate, gap: gap, library: songs)
        player.update(layout: layout)
    }

    private func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Stored(songs: songs, gap: gap)) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
