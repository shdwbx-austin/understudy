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

    var body: some View {
        GeometryReader { geo in
        HStack(alignment: .top, spacing: Theme.gutter) {
            PlaylistPanel(timeline: timeline)
                .frame(width: playlistWidth(total: geo.size.width))
            VStack(alignment: .leading, spacing: 14) {
                SectionCaption(text: "Set · drag or swipe to scrub · swipe the song below to step frames")
                TimelineTrack(timeline: timeline)
                    .frame(height: 84)
                // Takes whatever height is spare: taller on a big show monitor, easier to scrub.
                SongDetailTrack(timeline: timeline)
                    .frame(minHeight: 110, maxHeight: 300)
                TransportBar(timeline: timeline, compact: true)
                Rule()
                HStack(alignment: .firstTextBaseline, spacing: Theme.gutter) {
                    DevRecordButton()
                    TakePicker()
                }
                DeckChips()
                if let message = timeline.message {
                    Text(message).font(Theme.mono(10)).foregroundStyle(Theme.grey).lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        }
    }

    /// The playlist sits on the grid (label column plus one column) unless a song name needs more,
    /// then widens to fit the longest name, up to 45% of the workspace.
    private func playlistWidth(total: CGFloat) -> CGFloat {
        let grid = ShowGrid.labelWidth + Theme.gutter + column
        let font = NSFont(name: "NHaasGroteskTXPro-55Rg", size: 14) ?? NSFont(name: "HelveticaNeue", size: 14) ?? .systemFont(ofSize: 14)
        let longest = timeline.songs.map { ($0.name as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        // Number, badges, duration and spacing around the name.
        let needed = longest + 22 + 20 + 22 + 40 + 4 * 10 + 24
        return min(max(grid, needed), total * 0.45)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Playlist").font(Theme.grotesk(18, .medium))
                Spacer()
                TextButton(title: "Find audio…") { timeline.chooseAudioFolder() }
                    .help("Pick a folder: audio files are matched to songs by name")
                TextButton(title: "Import CSV…") { timeline.chooseCSV() }
            }
            SetlistMenu(timeline: timeline)
            HStack(spacing: 14) {
                Text("\(timeline.setSongs.count) ON THE SET · \(clock(timeline.layout.totalDuration))")
                    .font(Theme.mono(9)).tracking(1.2).foregroundStyle(Theme.grey)
                Spacer()
                if !timeline.setSongs.isEmpty {
                    TextButton(title: "Show order", color: Theme.grey) { timeline.sortByShowOrder() }
                    TextButton(title: "Clear", color: Theme.grey) { timeline.clearSet() }
                }
            }
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

/// The song under the playhead (with its lead-in) stretched across the width, a seconds ruler
/// with show timecode, and the playhead. Drag for fine scrubbing within the song.
struct SongDetailTrack: View {
    @ObservedObject var timeline: TimelineModel

    var body: some View {
        GeometryReader { geo in
            if let index = timeline.currentIndex ?? (timeline.layout.items.isEmpty ? nil : 0) {
                let item = timeline.layout.items[index]
                let from = item.timelineStart - timeline.gap
                let span = max(item.timelineEnd - from, 1)
                let scale = geo.size.width / span
                let step = Self.tickStep(span: span, width: geo.size.width)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Theme.fill)
                    // Lead-in.
                    Rectangle().fill(Theme.rule.opacity(0.35))
                        .frame(width: timeline.gap * scale, height: geo.size.height - 22)
                        .offset(y: 22)
                    // Song body, with its waveform.
                    if let path = item.song.audioPath, let peaks = timeline.waveforms[path], let audio = item.song.audioDuration {
                        // Placed by the audio's own timecode (pre-roll shows in the lead-in).
                        let offset = max(-timeline.gap, item.song.audioOffset ?? 0)
                        WaveformView(peaks: peaks, color: Theme.paper.opacity(0.32))
                            .frame(width: max(1, audio * scale), height: (geo.size.height - 22) * 0.62)
                            .offset(x: (timeline.gap + offset) * scale, y: 22 + (geo.size.height - 22) * 0.3)
                    }
                    Rectangle().strokeBorder(Theme.paper, lineWidth: 1)
                        .frame(width: item.duration * scale, height: geo.size.height - 22)
                        .offset(x: timeline.gap * scale, y: 22)
                    // Ruler: song-relative time, show timecode at each tick.
                    ForEach(Array(stride(from: 0.0, through: item.duration, by: step)), id: \.self) { s in
                        let x = (timeline.gap + s) * scale
                        Rectangle().fill(Theme.rule).frame(width: 1, height: 10).offset(x: x, y: 12)
                        Text(clock(s)).font(Theme.mono(9)).foregroundStyle(Theme.grey)
                            .fixedSize()
                            .offset(x: x + 3, y: 0)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(format: "%02d  ", index + 1) + item.song.name).font(Theme.grotesk(15, .medium)).lineLimit(1)
                        Text(item.song.start.description + (item.song.audioPath == nil ? "  ·  NO AUDIO" : ""))
                            .font(Theme.mono(9)).foregroundStyle(Theme.grey)
                    }
                    .padding(.leading, timeline.gap * scale + 8)
                    .padding(.top, 30)
                    // Playhead.
                    let px = (timeline.playhead - from) * scale
                    if px >= 0, px <= geo.size.width {
                        Rectangle()
                            .fill(timeline.isPlaying ? Theme.lock : Theme.signal)
                            .frame(width: 2, height: geo.size.height)
                            .offset(x: px - 1)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if timeline.isPlaying { timeline.pause() }
                            timeline.seek(to: from + min(max(0, value.location.x), geo.size.width) / scale)
                        }
                )
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

    /// A ruler step giving labels at least ~70 pt apart.
    static func tickStep(span: Double, width: CGFloat) -> Double {
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300]
        let perSecond = Double(width) / span
        return steps.first { $0 * perSecond >= 70 } ?? 600
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
        HStack(spacing: 12) {
            ForEach(model.decks.filter { !model.settings.decks[$0.id].host.trimmingCharacters(in: .whitespaces).isEmpty }, id: \.id) { deck in
                DeckChip(deck: deck, config: model.settings.decks[deck.id])
            }
            if model.settings.decks.allSatisfy({ $0.host.trimmingCharacters(in: .whitespaces).isEmpty }) {
                Text("No decks assigned.").font(Theme.grotesk(13, .light)).foregroundStyle(Theme.grey)
            }
        }
    }
}

private struct DeckChip: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var deck: DeckController
    let config: DeckConfig

    var body: some View {
        let status = DeckStatus.word(deck, model: model)
        HStack(alignment: .center, spacing: 10) {
            Text(String(format: "%02d", deck.id + 1))
                .font(Theme.grotesk(26, .light))
                .foregroundStyle(status.color == Theme.lock ? Theme.lock : Theme.paper)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name.trimmingCharacters(in: .whitespaces)).font(Theme.grotesk(12, .medium)).lineLimit(1)
                Text(status.text).font(Theme.grotesk(13, .medium)).foregroundStyle(status.color).lineLimit(1)
                Text(deck.smoothedError.map { String(format: "Δ %+.1f F", $0) } ?? "Δ —")
                    .font(Theme.mono(9)).foregroundStyle(Theme.grey)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().strokeBorder(deck.isLost ? Theme.signal : Theme.rule, lineWidth: 1))
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
struct WaveformView: View {
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
