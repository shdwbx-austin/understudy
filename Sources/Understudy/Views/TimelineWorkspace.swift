import SwiftUI
import UniformTypeIdentifiers
import UnderstudyCore

/// The main window in Timeline mode: the playlist down the left (label column plus the first grid
/// column), and the timeline across the other three: the whole set to scrub, the current song up
/// close, transport, the take, and the decks.
struct TimelineWorkspace: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var timeline: TimelineModel
    /// Width of one grid column, so the panes sit on the show grid.
    let column: CGFloat
    /// The playlist folds away to give the timeline the whole width (remembered).
    @AppStorage("understudy.playlistCollapsed") private var collapsed = false

    var body: some View {
        GeometryReader { geo in
        HStack(alignment: .top, spacing: collapsed ? 12 : Theme.gutter) {
            if collapsed {
                // A slim rail: the button to bring the playlist back, and the set count.
                VStack(spacing: 10) {
                    PlaylistToggle(collapsed: $collapsed)
                    Text("\(timeline.setSongs.count)").font(Theme.mono(10)).foregroundStyle(Theme.grey)
                        .help("\(timeline.setSongs.count) songs on the set")
                }
                .frame(width: 28)
            } else {
                PlaylistPanel(timeline: timeline, collapse: $collapsed)
                    .frame(width: playlistWidth(total: geo.size.width))
            }
            VStack(alignment: .leading, spacing: 12) {
                TimelineTrack(timeline: timeline)
                    .frame(height: 118)
                    .help("The set: click, drag or swipe to move through it (keeps playing). Double-click a song to go to its start.")
                MarkerBar(timeline: timeline)
                // Takes whatever height is spare: taller on a big show monitor, easier to scrub.
                HStack(alignment: .top, spacing: Theme.gutter) {
                    SongDetailTrack(timeline: timeline)
                    MarkerList(timeline: timeline)
                        .frame(width: max(300, column * 1.1))
                }
                // The current song takes all the height that's spare.
                .frame(minHeight: 180, maxHeight: .infinity)
                TransportBar(timeline: timeline, compact: true)
                Rule()
                TakePicker()
                DeckChips()
                if let message = model.linkMessage ?? timeline.message {
                    Text(message).font(Theme.mono(10)).foregroundStyle(Theme.grey).lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        }
    }

    /// The playlist is a narrow column: the timeline gets the room. Long song names truncate
    /// (the full name is in the row's tooltip); a short set list can be narrower still.
    private func playlistWidth(total: CGFloat) -> CGFloat {
        let font = NSFont(name: "NHaasGroteskTXPro-55Rg", size: 14) ?? NSFont(name: "HelveticaNeue", size: 14) ?? .systemFont(ofSize: 14)
        let longest = timeline.songs.map { ($0.name as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        // Number, badges, duration and spacing around the name.
        let needed = longest + 22 + 20 + 22 + 40 + 4 * 10 + 24
        return min(max(250, needed), max(250, total * 0.24))
    }

}

private struct SectionCaption: View {
    let text: String

    var body: some View {
        Text(text.uppercased()).font(Theme.mono(9)).tracking(1.2).foregroundStyle(Theme.grey)
    }
}

// MARK: - Playlist

/// Tonight's set (click a song to go there, drag to reorder) and the library (+ to add).
/// Drop an audio file on any row to give the song its sound.
struct PlaylistPanel: View {
    @ObservedObject var timeline: TimelineModel
    @EnvironmentObject private var model: AppModel
    var collapse: Binding<Bool>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                if let collapse { PlaylistToggle(collapsed: collapse) }
                Text("Playlist").font(Theme.grotesk(18, .medium))
                Spacer()
                // Bringing songs in, and tidying the set, in one menu.
                Menu {
                    Button("Find Audio in Folder…") { timeline.chooseAudioFolder() }
                    Button("Import Song List (CSV)…") { timeline.chooseCSV() }
                    Divider()
                    Button("Put the Set in Timecode Order") { timeline.sortByShowOrder() }.disabled(timeline.setSongs.isEmpty)
                    Button("Clear the Set") { timeline.clearSet() }.disabled(timeline.setSongs.isEmpty)
                } label: {
                    Text("···").font(Theme.mono(14, bold: true)).foregroundStyle(Theme.grey)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Find audio, import a song list, order or clear the set")
            }
            SetlistMenu(timeline: timeline)
            Text("\(timeline.setSongs.count) ON THE SET · \(clock(timeline.layout.totalDuration))")
                .font(Theme.mono(9)).tracking(1.2).foregroundStyle(Theme.grey)
            Rule()
            List {
                Section {
                    ForEach(Array(timeline.setSongs.enumerated()), id: \.element.id) { index, song in
                        PlaylistRow(timeline: timeline, song: song, setIndex: index,
                                    duration: timeline.layout.items.indices.contains(index) ? timeline.layout.items[index].duration : nil)
                            .listRowBackground(timeline.currentSongID == song.id ? Theme.fill : Theme.ink)
                    }
                    .onMove { timeline.move(from: $0, to: $1) }
                    if timeline.setSongs.isEmpty {
                        Text(timeline.songs.isEmpty ? "Import a song list to start." : "Add songs from the library below with +.")
                            .font(Theme.grotesk(13, .light)).foregroundStyle(Theme.grey)
                            .listRowBackground(Theme.ink)
                    }
                } header: {
                    PlaylistHeader(title: "Set")
                }
                if !timeline.librarySongs.isEmpty {
                    Section {
                        ForEach(timeline.librarySongs) { song in
                            PlaylistRow(timeline: timeline, song: song, setIndex: nil, duration: song.duration)
                                .listRowBackground(Theme.ink)
                        }
                    } header: {
                        PlaylistHeader(title: "Library · \(timeline.librarySongs.count)")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.ink)
            .environment(\.defaultMinListRowHeight, 30)
        }
    }
}

/// The saved setlists: pick one, start or save one, rename or delete it, and order the set by
/// where its songs played in a recorded take.
private struct SetlistMenu: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var timeline: TimelineModel

    var body: some View {
        // A macOS menu shows only the first text of a composite label, so the caption and the
        // auto-order badge sit beside the menu and the menu's label is just the setlist's name.
        HStack(spacing: 6) {
            Text("SETLIST").font(Theme.mono(9)).tracking(1.2).foregroundStyle(Theme.grey)
            menu
            if timeline.autoOrderFromTakes {
                Text("AUTO-ORDER").font(Theme.mono(8, bold: true)).tracking(1).foregroundStyle(Theme.lock)
            }
        }
    }

    private var menu: some View {
        Menu {
            if !timeline.setlists.isEmpty {
                ForEach(timeline.setlists) { list in
                    Button((list.id == timeline.currentSetlistID ? "✓ " : "   ") + list.name + "  (\(list.songs.count))") {
                        timeline.selectSetlist(list.id)
                    }
                }
                Divider()
            }
            Button("New Setlist…") { if let name = ask("New setlist", default: "Set \(timeline.setlists.count + 1)") { timeline.newSetlist(named: name) } }
            Button("Save Set As…") { if let name = ask("Save the set as", default: "Set \(timeline.setlists.count + 1)") { timeline.saveSetAs(name) } }
            if let current = timeline.currentSetlist {
                Button("Rename “\(current.name)”…") { if let name = ask("Rename setlist", default: current.name) { timeline.renameSetlist(current.id, to: name) } }
                Button("Delete “\(current.name)”") { timeline.deleteSetlist(current.id) }
            }
            Divider()
            Button("Order Set by Latest Take") { model.orderSetByTake(0) }
                .disabled(model.takes.isEmpty)
            if model.selectedTake != 0, !model.takes.isEmpty {
                Button("Order Set by Selected Take") { model.orderSetByTake(model.selectedTake) }
            }
            Toggle("Auto-Order After Each Take", isOn: $timeline.autoOrderFromTakes)
        } label: {
            Text(timeline.currentSetlist?.name ?? "Unsaved set").font(Theme.grotesk(14, .medium)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Saved setlists, and ordering the set by where songs played in a take")
    }

    /// A one-line name prompt.
    private func ask(_ title: String, default value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

private struct PlaylistHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(Theme.mono(9, bold: true)).tracking(1.2).foregroundStyle(Theme.grey)
            .padding(.top, 8)
    }
}

private struct PlaylistRow: View {
    @ObservedObject var timeline: TimelineModel
    let song: Song
    let setIndex: Int?
    let duration: Double?
    @State private var dropTarget = false
    @State private var hover = false

    private var current: Bool { timeline.currentSongID == song.id }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let setIndex {
                Text(String(format: "%02d", setIndex + 1))
                    .font(Theme.mono(11, bold: current)).foregroundStyle(current ? Theme.paper : Theme.grey)
                    .frame(width: 22, alignment: .leading)
            } else {
                Button { timeline.addToSet(song.id) } label: {
                    Text("+").font(Theme.grotesk(17, .light)).frame(width: 22, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Add to the end of the set")
            }
            Text(song.name)
                .font(Theme.grotesk(14, current ? .medium : .regular))
                .foregroundStyle(setIndex == nil ? Theme.grey : Theme.paper)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let channel = song.audioLTCChannel {
                Text("TC").font(Theme.mono(9, bold: true)).tracking(0.8)
                    .foregroundStyle(song.audioOffset == nil ? Theme.amber : Theme.grey)
                    .help(timecodeHelp(channel))
            }
            if song.audioPath != nil {
                Text("♪").font(Theme.mono(11)).foregroundStyle(Theme.grey).help(URL(fileURLWithPath: song.audioPath!).lastPathComponent)
            }
            if hover, setIndex != nil {
                TextButton(title: "−", color: Theme.grey) { timeline.removeFromSet(song.id) }
                    .help("Take off the set (stays in the library)")
            }
            Text(duration.map(clock) ?? "—").font(Theme.mono(10)).foregroundStyle(Theme.grey)
                .frame(width: 40, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let setIndex { timeline.jump(toSong: setIndex) } else { timeline.addToSet(song.id) }
        }
        .onHover { hover = $0 }
        .overlay(Rectangle().strokeBorder(dropTarget ? Theme.paper : .clear, lineWidth: 1))
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in timeline.attachAudio(url, to: song.id) }
            }
            return true
        }
        .contextMenu {
            if song.inSet {
                Button("Take Off the Set") { timeline.removeFromSet(song.id) }
            } else {
                Button("Add to the Set") { timeline.addToSet(song.id) }
            }
            Button("Choose Audio…") { timeline.chooseAudio(for: song.id) }
            Button(song.bpm.map { "Tempo (\(TimelineModel.bpmText($0)) BPM)…" } ?? "Tempo…") { TempoPrompt.ask(timeline: timeline, song: song) }
            if timeline.currentSongID == song.id, song.bpm != nil {
                Button("Set Downbeat at Playhead") { timeline.setDownbeatAtPlayhead() }
            }
            if song.audioPath != nil { Button("Remove Audio") { timeline.removeAudio(from: song.id) } }
            if song.audioLTCChannel != nil {
                Toggle("Play Timecode Channel", isOn: Binding(get: { song.keepLTCChannel },
                                                             set: { _ in timeline.toggleKeepLTCChannel(song.id) }))
            }
            Divider()
            Button("Delete from Library", role: .destructive) { timeline.remove(song.id) }
        }
        .help(song.start.description)
    }

    private func timecodeHelp(_ channel: Int) -> String {
        var text = "Timecode on channel \(channel + 1): "
        text += song.keepLTCChannel ? "playing (Play Timecode Channel is on)." : "muted on the music output."
        if let offset = song.audioOffset {
            text += abs(offset) < 0.02 ? " Starts on the song start." : String(format: " Lined up by it (the file starts %.2f s %@ the song).", abs(offset), offset < 0 ? "before" : "after")
        } else {
            text += " Its code doesn't match the song list, so the song list is used."
        }
        return text
    }
}

// MARK: - Current song, up close

/// The song under the playhead (with its lead-in) stretched across the width, a ruler with show
/// timecode, and the playhead. Drag for fine scrubbing within the song; drag along the ruler to
/// draw a loop. Zoom in (pinch, ⌘=, or the
/// + by the ruler) to edit a section: the view follows the playhead, and the ruler goes down to
/// single frames.
struct SongDetailTrack: View {
    @ObservedObject var timeline: TimelineModel
    /// Where the visible window starts when zoomed in (timeline seconds), kept on the playhead.
    @State private var viewStart: Double = 0
    @State private var pinchBase: Double?
    /// A loop being dragged out along the ruler (timeline seconds), shown before it's set.
    @State private var rulerLoop: (from: Double, to: Double)?

    var body: some View {
        GeometryReader { geo in
            if let index = timeline.currentIndex ?? (timeline.layout.items.isEmpty ? nil : 0) {
                let item = timeline.layout.items[index]
                let gap = timeline.gap
                let from = item.timelineStart - gap
                let full = max(item.timelineEnd - from, 1)
                let zoom = min(max(1, timeline.detailZoom), TimelineModel.maxZoom)
                let span = full / zoom
                let start = zoom <= 1.0001 ? from : min(max(from, viewStart), item.timelineEnd - span)
                let end = start + span
                let width = geo.size.width
                let height = geo.size.height
                let scale = width / span
                let x: (Double) -> CGFloat = { CGFloat(($0 - start) * scale) }
                let fps = timeline.rate.exact
                let step = Self.tickStep(span: span, width: width, fps: fps)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Theme.fill)
                    // Lead-in.
                    let leadEnd = min(width, x(item.timelineStart))
                    if leadEnd > 0 {
                        Rectangle().fill(Theme.rule.opacity(0.35))
                            .frame(width: leadEnd - max(0, x(from)), height: height - 22)
                            .offset(x: max(0, x(from)), y: 22)
                    }
                    // Beat grid: bar lines, and beats when there's room.
                    if timeline.showGrid, let grid = timeline.grid(for: item.song) {
                        BeatGridLines(grid: grid, showStart: item.showStart, songStart: item.timelineStart,
                                      viewStart: start, scale: scale, height: height)
                            .allowsHitTesting(false)
                    }
                    // Waveform: only the part on screen, so zooming in stays light.
                    if let path = item.song.audioPath, let peaks = timeline.waveforms[path], !peaks.isEmpty,
                       let audio = item.song.audioDuration, audio > 0 {
                        let audioStart = item.timelineStart + max(-gap, item.song.audioOffset ?? 0)
                        let a0 = max(0, start - audioStart), a1 = min(audio, end - audioStart)
                        if a1 > a0 {
                            let n = Double(peaks.count)
                            let lo = max(0, min(peaks.count - 1, Int((a0 / audio * n).rounded(.down))))
                            let hi = max(lo + 1, min(peaks.count, Int((a1 / audio * n).rounded(.up))))
                            let t0 = Double(lo) / n * audio, t1 = Double(hi) / n * audio
                            WaveformView(peaks: Array(peaks[lo..<hi]), color: Theme.paper.opacity(0.32)).equatable()
                                .frame(width: max(1, (t1 - t0) * scale), height: (height - 22) * 0.62)
                                .offset(x: x(audioStart + t0), y: 22 + (height - 22) * 0.3)
                        }
                    }
                    // Song outline (its ends run off screen when zoomed in).
                    let s0 = max(-2, x(item.timelineStart)), s1 = min(width + 2, x(item.timelineEnd))
                    if s1 > s0 {
                        Rectangle().strokeBorder(Theme.paper, lineWidth: 1)
                            .frame(width: s1 - s0, height: height - 22)
                            .offset(x: s0, y: 22)
                    }
                    // The loop: everything outside it dimmed, solid edges, a bar along the top.
                    let shownLoop: Range<Double>? = rulerLoop.map { min($0.from, $0.to)..<max($0.from, $0.to) } ?? timeline.loopRange
                    if let r = shownLoop, r.upperBound > start, r.lowerBound < end {
                        let a = max(0, x(r.lowerBound)), b = min(width, x(r.upperBound))
                        let body = height - 22
                        Group {
                            if a > 0 { Rectangle().fill(Theme.ink.opacity(0.7)).frame(width: a, height: body).offset(y: 22) }
                            if b < width { Rectangle().fill(Theme.ink.opacity(0.7)).frame(width: width - b, height: body).offset(x: b, y: 22) }
                            Rectangle().fill(Theme.paper.opacity(0.11)).frame(width: max(1, b - a), height: body).offset(x: a, y: 22)
                            Rectangle().fill(Theme.paper).frame(width: max(1, b - a), height: 3).offset(x: a, y: 22)
                            if x(r.lowerBound) >= 0 { Rectangle().fill(Theme.paper).frame(width: 2, height: body).offset(x: a - 1, y: 22) }
                            if x(r.upperBound) <= width { Rectangle().fill(Theme.paper).frame(width: 2, height: body).offset(x: b - 1, y: 22) }
                        }
                        .allowsHitTesting(false)
                    }
                    // Ruler: song-relative time, frames when zoomed in close.
                    let first = (max(0, start - item.timelineStart) / step).rounded(.up) * step
                    let last = min(item.duration, end - item.timelineStart)
                    if last >= first {
                        ForEach(Array(stride(from: first, through: last, by: step)), id: \.self) { s in
                            let px = x(item.timelineStart + s)
                            Rectangle().fill(Theme.rule).frame(width: 1, height: 10).offset(x: px, y: 12)
                            Text(Self.label(s, step: step, fps: fps)).font(Theme.mono(9)).foregroundStyle(Theme.grey)
                                .fixedSize()
                                .offset(x: px + 3, y: 0)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(format: "%02d  ", index + 1) + item.song.name).font(Theme.grotesk(15, .medium)).lineLimit(1)
                        Text(item.song.start.description + (item.song.audioPath == nil ? "  ·  NO AUDIO" : ""))
                            .font(Theme.mono(9)).foregroundStyle(Theme.grey)
                    }
                    .padding(.leading, max(8, x(item.timelineStart) + 8))
                    .padding(.top, 30)
                    .allowsHitTesting(false)
                    MarkerOverlay(timeline: timeline, from: start, scale: scale, width: width, height: height)
                    // Playhead.
                    PlayheadLine(head: timeline.head, playing: timeline.isPlaying, height: height) { t in
                        let px = (t - start) * scale
                        return px >= 0 && px <= width ? px : nil
                    }
                    ZoomFollower(head: timeline.head, from: from, to: item.timelineEnd, span: span, zoomed: zoom > 1.0001,
                                 playing: timeline.isPlaying, viewStart: $viewStart)
                }
                .contentShape(Rectangle())
                // Click or drag within the song to scrub; while playing it keeps playing from there.
                // Drag along the ruler (the top strip) to draw a loop.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let at = start + min(max(0, value.location.x), width) / scale
                            if value.startLocation.y < 22, abs(value.translation.width) > 3 {
                                rulerLoop = (start + min(max(0, value.startLocation.x), width) / scale, at)
                            } else if rulerLoop == nil {
                                timeline.scrub(to: at)
                            }
                        }
                        .onEnded { _ in
                            if let r = rulerLoop {
                                timeline.setLoopSection(from: r.from, to: r.to)
                                rulerLoop = nil
                            }
                            timeline.endScrub()
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { v in
                            let base = pinchBase ?? timeline.detailZoom
                            pinchBase = base
                            timeline.setZoom(base * v)
                        }
                        .onEnded { _ in pinchBase = nil }
                )
                .overlay(alignment: .topTrailing) { ZoomControls(timeline: timeline, song: item.song).padding(.trailing, 4) }
                .overlay(alignment: .bottomLeading) {
                    if let r = timeline.loopRange, r.upperBound > start, r.lowerBound < end {
                        LoopChip(timeline: timeline, range: r, songStart: item.timelineStart, fps: fps)
                            .offset(x: min(max(4, x(r.lowerBound) + 6), max(4, width - 330)), y: -6)
                    }
                }
            } else {
                Rectangle().fill(Theme.fill)
            }
        }
        .clipped()
        // Two-finger swipe, side wheel or Shift + wheel steps frame by frame.
        .background(HorizontalScrollReader { physical, precise, _ in
            timeline.scrollFrames(Double(physical), precise: precise)
        })
    }

    /// A ruler step giving labels at least ~70 pt apart: whole frames when zoomed in close.
    static func tickStep(span: Double, width: CGFloat, fps: Double = 30) -> Double {
        let frame = 1 / max(fps, 1)
        let steps: [Double] = [frame, 2 * frame, 5 * frame, 10 * frame, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let perSecond = Double(width) / span
        return steps.first { $0 * perSecond >= 70 } ?? 600
    }

    /// m:ss, or m:ss:ff when ticks are under a second apart.
    static func label(_ s: Double, step: Double, fps: Double) -> String {
        if step >= 1 { return clock(s) }
        let frames = Int((s * fps).rounded())
        let perSecond = Int(fps.rounded())
        let whole = frames / max(perSecond, 1)
        return String(format: "%d:%02d:%02d", whole / 60, whole % 60, frames % max(perSecond, 1))
    }
}

/// Keeps a zoomed-in view on the playhead: pages along while playing, centres on a jump. Watches
/// the playhead on its own, so the track only redraws when the view actually moves.
private struct ZoomFollower: View {
    @ObservedObject var head: PlayheadClock
    let from: Double
    let to: Double
    let span: Double
    let zoomed: Bool
    let playing: Bool
    @Binding var viewStart: Double

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onAppear { centre(head.position) }
            .onChange(of: span) { _ in centre(head.position) }
            .onChange(of: from) { _ in centre(head.position) }
            .onChange(of: head.position) { p in follow(p) }
    }

    private func follow(_ p: Double) {
        guard zoomed else { return }
        if p < viewStart || p > viewStart + span * 0.95 {
            viewStart = clamp(playing ? p - span * 0.1 : p - span / 2)
        }
    }

    private func centre(_ p: Double) { viewStart = clamp(p - span / 2) }
    private func clamp(_ s: Double) -> Double { min(max(from, s), max(from, to - span)) }
}

/// The loop's times and length, with × to clear it. Sits at the bottom of the loop.
private struct LoopChip: View {
    @ObservedObject var timeline: TimelineModel
    let range: Range<Double>
    let songStart: Double
    let fps: Double

    var body: some View {
        let a = range.lowerBound - songStart, b = range.upperBound - songStart
        HStack(spacing: 10) {
            Text(timeline.loop.mode == .song ? "LOOP SONG" : "LOOP").font(Theme.mono(9, bold: true)).tracking(1.2)
            Text("\(Self.time(a, fps)) – \(Self.time(b, fps))").font(Theme.mono(9))
            Text(String(format: "%.1f S", b - a)).font(Theme.mono(9)).foregroundStyle(Theme.ink.opacity(0.6))
            Button { timeline.clearLoop() } label: {
                Text("×").font(Theme.grotesk(15, .medium)).frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Clear the loop (⇧L)")
        }
        .foregroundStyle(Theme.ink)
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 3)
        .background(Rectangle().fill(Theme.paper))
        .fixedSize()
    }

    /// m:ss.ff, song-relative (negative in the lead-in).
    static func time(_ s: Double, _ fps: Double) -> String {
        let sign = s < 0 ? "-" : ""
        let frames = Int((abs(s) * fps).rounded())
        let per = max(1, Int(fps.rounded()))
        let whole = frames / per
        return sign + String(format: "%d:%02d.%02d", whole / 60, whole % 60, frames % per)
    }
}

/// Bar lines (and beat lines when they're far enough apart) across the current song, with bar
/// numbers along the bottom when there's room. One Canvas, only the visible span.
private struct BeatGridLines: View {
    let grid: BeatGrid
    let showStart: Double
    let songStart: Double
    let viewStart: Double
    let scale: Double
    let height: CGFloat

    var body: some View {
        Canvas { context, size in
            let beatPx = grid.beatSeconds * scale
            let barPx = beatPx * Double(grid.beatsPerBar)
            // Lines only where they read as a grid, not a barcode: every bar, or every 2nd, 4th…
            // so they're at least 14 pt apart; beats once they're 10 pt apart.
            guard let stride = SongTempo.barStride(barPoints: barPx, minimum: 14) else { return }
            // Timeline time ↔ show seconds within this song.
            let from = showStart + (viewStart - songStart)
            let to = from + Double(size.width) / scale
            for beat in grid.beats(from: from, to: to) {
                if !beat.isBarStart && beatPx < 10 { continue }
                if beat.isBarStart, (beat.bar - 1) % stride != 0 { continue }
                let x = CGFloat((beat.seconds - showStart + songStart - viewStart) * scale)
                let line = CGRect(x: x, y: 22, width: 1, height: size.height - 22)
                context.fill(Path(line), with: .color(beat.isBarStart ? Theme.paper.opacity(0.22) : Theme.paper.opacity(0.08)))
                if beat.isBarStart, barPx * Double(stride) >= 34 {
                    context.draw(Text("\(beat.bar)").font(Theme.mono(8)).foregroundColor(Theme.grey),
                                 at: CGPoint(x: x + 3, y: size.height - 8), anchor: .leading)
                }
            }
        }
        .frame(height: height)
    }
}

/// − 4× + FIT, by the ruler, and the beat grid's switch and tempo.
private struct ZoomControls: View {
    @ObservedObject var timeline: TimelineModel
    let song: Song

    var body: some View {
        let zoom = timeline.detailZoom
        HStack(spacing: 8) {
            Button {
                if song.bpm == nil { TempoPrompt.ask(timeline: timeline, song: song) } else { timeline.showGrid.toggle() }
            } label: {
                Text(song.bpm.map { "GRID \(TimelineModel.bpmText($0))" } ?? "GRID")
                    .font(Theme.mono(9, bold: timeline.showGrid && song.bpm != nil))
                    .foregroundStyle(timeline.showGrid && song.bpm != nil ? Theme.paper : Theme.grey)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(song.bpm == nil ? "Set this song's tempo to see a beat grid" : "Beat grid on or off (right-click the song for its tempo and downbeat)")
            .contextMenu {
                Button("Tempo…") { TempoPrompt.ask(timeline: timeline, song: song) }
                Button("Set Downbeat at Playhead") { timeline.setDownbeatAtPlayhead() }
            }
            Rectangle().fill(Theme.rule).frame(width: 1, height: 10)
            button("−", "Zoom out (⌘−)", enabled: zoom > 1) { timeline.setZoom(zoom / 2) }
            Text(zoom <= 1.0001 ? "SONG" : String(format: zoom < 10 ? "%.1f×" : "%.0f×", zoom))
                .font(Theme.mono(9)).foregroundStyle(zoom > 1 ? Theme.paper : Theme.grey)
                .frame(minWidth: 30)
            button("+", "Zoom in (⌘=), or pinch", enabled: zoom < TimelineModel.maxZoom) { timeline.setZoom(zoom * 2) }
            if zoom > 1 { button("FIT", "Whole song (⌘0)", enabled: true) { timeline.setZoom(1) } }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Theme.ink)
    }

    private func button(_ title: String, _ help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.mono(title.count == 1 ? 12 : 9, bold: true))
                .foregroundStyle(enabled ? Theme.paper : Theme.quiet)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

// MARK: - Take and decks

/// Dev/test: put the decks in Record with the timeline as show code, and back.
struct DevRecordButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.mode == .record {
            TextButton(title: "● Rec · stop (dev)", color: Theme.signal) { model.requestMode(.timeline) }
                .help("Stop recording and go back to Timeline mode")
        } else {
            TextButton(title: "Rec decks (dev)", color: Theme.quiet) { model.startTimelineRecording() }
                .help("Test: record on the decks while the timeline plays. Show code comes from the timeline (⌥⌘R).")
        }
    }
}

/// The take the decks play from, as a compact menu.
struct TakePicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("TAKE").font(Theme.mono(9)).tracking(1.2).foregroundStyle(Theme.grey)
            if model.takes.isEmpty {
                Text("No takes on the decks yet.").font(Theme.grotesk(14, .light)).foregroundStyle(Theme.grey)
            } else {
                Menu {
                    ForEach(model.takes) { take in
                        Button(label(take)) { model.chooseTake(take.offset) }
                    }
                } label: {
                    Text(current.map(label) ?? "Choose a take").font(Theme.grotesk(14, .regular)).lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Spacer()
            Toggle("Follow latest", isOn: $model.settings.followLatestTake)
                .toggleStyle(.checkbox)
                .font(Theme.mono(10))
        }
    }

    private var current: Take? { model.takes.first { $0.offset == model.selectedTake } }

    private func label(_ take: Take) -> String {
        "\(take.offset == 0 ? "Latest — " : "")#\(take.clipID)  \(take.name)  \(take.duration.description)"
    }
}

/// One small block per assigned deck: number, name, its one status word, and drift.
struct DeckChips: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let assigned = model.decks.filter { model.settings.decks.indices.contains($0.id) && !model.settings.decks[$0.id].host.trimmingCharacters(in: .whitespaces).isEmpty }
        // Up to four across, then wrap: 16 decks make four rows of four.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 6) {
            ForEach(assigned, id: \.id) { deck in
                DeckChip(deck: deck, config: model.settings.decks[deck.id])
            }
        }
        if assigned.isEmpty {
            Text("No decks assigned.").font(Theme.grotesk(13, .light)).foregroundStyle(Theme.grey)
        }
    }
}

private struct DeckChip: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var deck: DeckController
    let config: DeckConfig

    /// One slim line per deck: number, name, status word, drift. Red outline when lost.
    var body: some View {
        let status = DeckStatus.word(deck, model: model)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(format: "%02d", deck.id + 1))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.grey)
            Text(config.name.trimmingCharacters(in: .whitespaces)).font(Theme.grotesk(12, .regular)).lineLimit(1)
            Text(status.text).font(Theme.grotesk(12, .light)).foregroundStyle(status.color).lineLimit(1)
            Spacer(minLength: 4)
            Text(deck.smoothedError.map { String(format: "Δ %+.1f", $0) } ?? "")
                .font(Theme.mono(9)).foregroundStyle(Theme.quiet)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(deck.isLost ? Theme.signal.opacity(0.12) : Theme.fill)
        .overlay(Rectangle().strokeBorder(deck.isLost ? Theme.signal : Color.clear, lineWidth: 1))
        .help("\(config.name) · \(status.text)")
    }
}

// MARK: - Horizontal scrolling

/// Horizontal scrolling over a view: two-finger swipes on a trackpad, a mouse's side wheel, or
/// Shift + wheel. Vertical scrolling, clicks and drags pass straight through.
struct HorizontalScrollReader: NSViewRepresentable {
    /// `physical` is in the direction the fingers or wheel moved (positive = right, whatever the
    /// natural-scrolling setting); `precise` is true for trackpads and Magic Mouse; `width` is the
    /// view's width in points.
    let onScroll: (_ physical: CGFloat, _ precise: Bool, _ width: CGFloat) -> Void

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) {
        view.onScroll = onScroll
    }

    final class Catcher: NSView {
        var onScroll: ((CGFloat, Bool, CGFloat) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let dx = event.scrollingDeltaX
                guard abs(dx) > abs(event.scrollingDeltaY), dx != 0 else { return event }
                // Natural scrolling flips the sign: undo it so right always means later.
                let physical = event.isDirectionInvertedFromDevice ? dx : -dx
                self.onScroll?(physical, event.hasPreciseScrollingDeltas, self.bounds.width)
                return nil
            }
        }

        /// Never takes clicks; the monitor is removed when the view leaves its window.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Waveform

/// A song's waveform, mirrored about the centre line, one bar per point of width.
struct WaveformView: View, Equatable {
    let peaks: [Float]
    var color: Color = Theme.paper.opacity(0.35)

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty, size.width > 0 else { return }
            let mid = size.height / 2
            let columns = max(1, Int(size.width))
            var path = Path()
            for x in 0..<columns {
                let lo = x * peaks.count / columns
                let hi = max(lo + 1, (x + 1) * peaks.count / columns)
                var peak: Float = 0
                for i in lo..<min(hi, peaks.count) { peak = max(peak, peaks[i]) }
                let h = max(0.5, CGFloat(peak) * mid)
                path.addRect(CGRect(x: CGFloat(x), y: mid - h, width: 1, height: h * 2))
            }
            context.fill(path, with: .color(color))
        }
        .allowsHitTesting(false)
    }
}

/// Shows or hides the playlist (⌃⌘S, like a sidebar).
struct PlaylistToggle: View {
    @Binding var collapsed: Bool

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() } } label: {
            Image(systemName: "sidebar.left").font(.system(size: 14)).foregroundStyle(Theme.grey)
                .frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: [.command, .control])
        .help(collapsed ? "Show the playlist (⌃⌘S)" : "Hide the playlist (⌃⌘S)")
    }
}
