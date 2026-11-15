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
    /// Playlist order.
    @Published private(set) var songs: [Song] = []
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
            let imported = try SongListCSV.parse(text)
            // Keep audio already attached to songs of the same name.
            let audio = Dictionary(songs.map { ($0.name, ($0.audioPath, $0.audioDuration)) }, uniquingKeysWith: { a, _ in a })
            songs = imported.map { song in
                var s = song
                if let (path, duration) = audio[s.name] { s.audioPath = path; s.audioDuration = duration }
                return s
            }
            message = "Imported \(songs.count) songs from \(url.lastPathComponent)."
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

    func move(from source: IndexSet, to destination: Int) {
        let current = currentSongID
        songs.move(fromOffsets: source, toOffset: destination)
        layoutChanged()
        // Keep the playhead on the same song after a reorder.
        if let current, let i = layout.items.firstIndex(where: { $0.song.id == current }) {
            seek(to: layout.items[i].timelineStart - gap)
        }
    }

    func remove(_ id: UUID) {
        songs.removeAll { $0.id == id }
        layoutChanged()
    }

    /// Back to show order (by start timecode).
    func sortByShowOrder() {
        songs.sort { $0.start.seconds(at: rate) < $1.start.seconds(at: rate) }
        layoutChanged()
    }

    private func layoutChanged() {
        layout = TimelineLayout(ordered: songs, rate: rate, gap: gap)
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
        songs = stored.songs
        gap = stored.gap
        layout = TimelineLayout(ordered: songs, rate: rate, gap: gap)
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
