import SwiftUI
import UniformTypeIdentifiers
import UnderstudyCore

/// The song timeline: songs laid end to end in playlist order, a playhead to scrub, transport,
/// and the song list to reorder and give audio to.
struct TimelineView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var timeline: TimelineModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineHeader(timeline: timeline)
                .padding(.bottom, 18)
            TimelineTrack(timeline: timeline)
                .frame(height: 132)
                .padding(.bottom, 14)
            TransportBar(timeline: timeline)
                .padding(.bottom, 22)
            Rule()
            SongList(timeline: timeline)
            if let message = timeline.message {
                Text(message).font(Theme.mono(10)).foregroundStyle(Theme.grey)
                    .padding(.top, 8)
            }
        }
        .padding(28)
        .frame(minWidth: 960, minHeight: 620, alignment: .topLeading)
        .background(Theme.ink)
        .foregroundStyle(Theme.paper)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Header

private struct TimelineHeader: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var timeline: TimelineModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.gutter) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Timeline").font(Theme.grotesk(26, .medium))
                Text(subtitle).font(Theme.mono(10)).tracking(1.2).foregroundStyle(Theme.grey)
            }
            Spacer()
            HeaderReadout(timeline: timeline, head: timeline.head, dropFrame: model.ltcRate.isDropFrame)
        }
    }

    private var subtitle: String {
        if timeline.songs.isEmpty { return "IMPORT A SONG LIST TO START" }
        let set = timeline.setSongs.count
        return "\(set) ON THE SET · \(clock(timeline.layout.totalDuration)) · \(timeline.songs.count - set) IN THE LIBRARY · \(role)"
    }

    /// What the timeline's code is feeding right now.
    private var role: String {
        switch model.mode {
        case .timeline: return "DRIVING THE DECKS"
        case .record where model.showCodeFromTimeline: return "SHOW CODE FOR THE RECORDING"
        case .stop where model.showCodeFromTimeline: return "SHOW CODE"
        default: return "⌘4 DRIVES THE DECKS"
        }
    }

}

/// Show timecode and the current song: the only part of the header that moves every frame.
private struct HeaderReadout: View {
    let timeline: TimelineModel
    @ObservedObject var head: PlayheadClock
    let dropFrame: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(timeline.showTimecode?.display(dropFrame: dropFrame) ?? "--:--:--:--")
                .font(Theme.mono(30, bold: false))
                .monospacedDigit()
                .foregroundStyle(timeline.isPlaying ? Theme.lock : Theme.paper)
            Text(currentName).font(Theme.grotesk(14, .regular)).foregroundStyle(Theme.grey).lineLimit(1)
        }
    }

    private var currentName: String {
        guard let i = timeline.currentIndex, timeline.layout.items.indices.contains(i) else { return "—" }
        let item = timeline.layout.items[i]
        let lead = head.position < item.timelineStart ? "Next: " : ""
        return "\(lead)\(String(format: "%02d", i + 1))  \(item.song.name)"
    }
}

/// A playhead line that watches only the playhead. `x` maps timeline seconds to points (nil: off-screen).
struct PlayheadLine: View {
    @ObservedObject var head: PlayheadClock
    let playing: Bool
    let height: CGFloat
    let x: (Double) -> CGFloat?

    var body: some View {
        if let px = x(head.position) {
            Rectangle()
                .fill(playing ? Theme.lock : Theme.signal)
                .frame(width: 2, height: height)
                .offset(x: px - 1)
                .allowsHitTesting(false)
        }
    }
}

/// "1:23 / 8:11", watching only the playhead.
struct PlayheadTime: View {
    @ObservedObject var head: PlayheadClock
    let total: Double

    var body: some View {
        Text("\(clock(head.position)) / \(clock(total))")
            .font(Theme.mono(12)).monospacedDigit().foregroundStyle(Theme.grey)
    }
}

// MARK: - Track

/// Song blocks to scale, lead-ins hatched, a marker and number at each song start, and the playhead.
/// Drag anywhere to scrub; double-click a song to jump to its start.
struct TimelineTrack: View {
    @ObservedObject var timeline: TimelineModel

    var body: some View {
        GeometryReader { geo in
            let total = max(timeline.layout.totalDuration, 1)
            let scale = geo.size.width / total
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.fill)
                ForEach(Array(timeline.layout.items.enumerated()), id: \.element.song.id) { index, item in
                    let leadX = (item.timelineStart - timeline.gap) * scale
                    let x = item.timelineStart * scale
                    let w = max(1, item.duration * scale)
                    let current = timeline.currentSongID == item.song.id
                    // Lead-in.
                    Rectangle()
                        .fill(Theme.rule.opacity(0.35))
                        .frame(width: max(0, x - leadX), height: geo.size.height - 28)
                        .offset(x: leadX, y: 28)
                    // Song.
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(current ? Theme.paper.opacity(0.14) : Theme.ink)
                        if let path = item.song.audioPath, let peaks = timeline.waveforms[path], let audio = item.song.audioDuration {
                            let offset = item.song.audioOffset ?? 0
                            WaveformView(peaks: peaks, color: Theme.paper.opacity(current ? 0.35 : 0.22)).equatable()
                                .frame(width: max(1, audio * scale), height: (geo.size.height - 28) * 0.42)
                                .offset(x: offset * scale, y: (geo.size.height - 28) * 0.56)
                                .frame(width: w, alignment: .leading)
                                .clipped()
                        }
                        Rectangle().strokeBorder(current ? Theme.paper : Theme.rule, lineWidth: 1)
                        // Names wrap and shrink to stay readable in narrow blocks; the smaller lines go first.
                        if w > 22 {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.song.name)
                                    .font(Theme.grotesk(13, .medium))
                                    .lineLimit(w < 90 ? 3 : 2)
                                    .minimumScaleFactor(0.6)
                                    .fixedSize(horizontal: false, vertical: true)
                                if w >= 90 {
                                    Text(item.song.start.description).font(Theme.mono(9)).foregroundStyle(Theme.grey)
                                }
                                if item.song.audioPath == nil, w >= 70 {
                                    Text("NO AUDIO").font(Theme.mono(8, bold: true)).tracking(1).foregroundStyle(Theme.quiet)
                                }
                            }
                            .padding(.horizontal, w < 60 ? 3 : 6)
                            .padding(.vertical, 5)
                            .frame(width: w, alignment: .leading)
                        }
                    }
                    .frame(width: w, height: geo.size.height - 28)
                    .offset(x: x, y: 28)
                    .onTapGesture(count: 2) { timeline.jump(toSong: index) }
                    // Marker.
                    Rectangle().fill(Theme.paper).frame(width: 1, height: 24).offset(x: x, y: 2)
                    Text(String(format: "%02d", index + 1))
                        .font(Theme.mono(9, bold: true))
                        .offset(x: x + 4, y: 4)
                }
                // Playhead.
                let width = geo.size.width
                PlayheadLine(head: timeline.head, playing: timeline.isPlaying, height: geo.size.height) { t in
                    min(max(0, t * scale), width - 1)
                }
            }
            .contentShape(Rectangle())
            // Click or drag to a spot; while playing it keeps playing from there.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in timeline.scrub(to: value.location.x / scale) }
                    .onEnded { _ in timeline.endScrub() }
            )
        }
        .clipped()
        // Two-finger swipe, side wheel or Shift + wheel scrubs across the set.
        .background(HorizontalScrollReader { physical, precise, width in
            let total = max(timeline.layout.totalDuration, 1)
            let points = precise ? Double(physical) : Double(physical) * 12
            timeline.scrub(by: points * total / Double(max(width, 1)))
        })
        .overlay(alignment: .center) {
            if timeline.songs.isEmpty {
                TextButton(title: "Import song list…") { timeline.chooseCSV() }
            } else if timeline.setSongs.isEmpty {
                Text("ADD SONGS TO THE SET FROM THE LIBRARY BELOW")
                    .font(Theme.mono(10, bold: true)).tracking(1.2).foregroundStyle(Theme.grey)
            }
        }
    }
}

// MARK: - Transport

struct TransportBar: View {
    @ObservedObject var timeline: TimelineModel
    /// In the main window: no import (the playlist has it) and no show-code box (Timeline mode is the timeline).
    var compact = false

    var body: some View {
        HStack(spacing: 18) {
            TransportButton(symbol: "backward.end.fill", help: "Previous song (⌥←)") { timeline.previousSong() }
                .keyboardShortcut(.leftArrow, modifiers: .option)
            TransportButton(symbol: "backward.frame.fill", help: "Back one frame (←); ⇧← one second") { timeline.step(frames: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            TransportButton(symbol: timeline.isPlaying ? "pause.fill" : "play.fill", help: "Play / pause (space)", large: true) {
                timeline.togglePlay()
            }
            .keyboardShortcut(.space, modifiers: [])
            TransportButton(symbol: "forward.frame.fill", help: "Forward one frame (→); ⇧→ one second") { timeline.step(frames: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            TransportButton(symbol: "forward.end.fill", help: "Next song (⌥→)") { timeline.nextSong() }
                .keyboardShortcut(.rightArrow, modifiers: .option)
            // One-second steps.
            Button("") { timeline.step(frames: -Int(timeline.rate.exact.rounded())) }
                .keyboardShortcut(.leftArrow, modifiers: .shift).opacity(0).frame(width: 0)
            Button("") { timeline.step(frames: Int(timeline.rate.exact.rounded())) }
                .keyboardShortcut(.rightArrow, modifiers: .shift).opacity(0).frame(width: 0)

            PlayheadTime(head: timeline.head, total: timeline.layout.totalDuration)
            Spacer()
            OutputStatus(showToggle: !compact)
            Stepper(value: $timeline.gap, in: 0...10, step: 0.5) {
                Text(String(format: "LEAD-IN %.1f S", timeline.gap)).font(Theme.mono(10)).tracking(1.2)
            }
            .help("Gap before each song, so the decks can park on its footage and be rolling on its first frame")
            if !compact {
                TextButton(title: "Find audio…") { timeline.chooseAudioFolder() }
                    .help("Pick a folder: audio files are matched to songs by name")
                TextButton(title: "Import CSV…") { timeline.chooseCSV() }
            }
        }
    }
}

/// Where the timeline's code goes: LTC out, and/or Understudy's own recorder.
private struct OutputStatus: View {
    @EnvironmentObject private var model: AppModel
    var showToggle = true

    var body: some View {
        HStack(spacing: 14) {
            Text(ltcText).font(Theme.mono(10)).tracking(1.2)
                .foregroundStyle(model.danteStatus.isProblem ? Theme.amber
                                 : model.timecodeOutLabel == nil ? Theme.quiet : Theme.paper)
                .help(model.settings.danteOut ? model.danteStatus.message
                      : "Generated LTC follows the timeline. Set the device and channel in Settings › Timeline output.")
            if showToggle { Toggle(isOn: Binding(
                get: { model.settings.showCodeSource == .timeline },
                set: { model.settings.showCodeSource = $0 ? .timeline : .input }
            )) {
                Text("SHOW CODE FOR RECORD").font(Theme.mono(10)).tracking(1.2)
            }
            .toggleStyle(.checkbox)
            .help("Stop and Record take show code from this timeline instead of the LTC input, so takes log against it with no cable.") }
        }
    }

    private var ltcText: String {
        switch model.danteStatus {
        case .sending: return "DANTE OUT 1–3"
        case .portDown: return "DANTE OUT · NO LINK"
        case .noSoundcard: return "DANTE OUT · NO DVS"
        case .tooFewChannels: return "DANTE OUT · DVS NEEDS 3 CH"
        case .off: break
        }
        return model.timecodeOutLabel?.uppercased() ?? "LTC OUT OFF"
    }
}

private struct TransportButton: View {
    let symbol: String
    let help: String
    var large = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: large ? 22 : 15, weight: .medium))
                .frame(width: large ? 46 : 30, height: large ? 46 : 30)
                .background(large ? Theme.paper : Color.clear)
                .foregroundStyle(large ? Theme.ink : Theme.paper)
                .overlay(Rectangle().strokeBorder(Theme.rule, lineWidth: large ? 0 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Song list

/// Tonight's set, in playing order (drag to reorder, − to take off), then the library (+ to add).
/// Drop an audio file on any row, or right-click › Choose Audio…, to give a song its sound.
private struct SongList: View {
    @ObservedObject var timeline: TimelineModel

    var body: some View {
        List {
            Section {
                ForEach(Array(timeline.setSongs.enumerated()), id: \.element.id) { index, song in
                    SongRow(timeline: timeline, song: song, setIndex: index,
                            duration: timeline.layout.items.indices.contains(index) ? timeline.layout.items[index].duration : nil,
                            current: timeline.currentSongID == song.id)
                        .listRowBackground(timeline.currentSongID == song.id ? Theme.fill : Theme.ink)
                }
                .onMove { timeline.move(from: $0, to: $1) }
                if timeline.setSongs.isEmpty {
                    Text("Nothing on the set yet. Add songs from the library with +.")
                        .font(Theme.grotesk(14, .light)).foregroundStyle(Theme.grey)
                        .listRowBackground(Theme.ink)
                }
            } header: {
                ListHeader(title: "Set", detail: "\(timeline.setSongs.count) songs · drag to reorder") {
                    if !timeline.setSongs.isEmpty {
                        TextButton(title: "Show order", color: Theme.grey) { timeline.sortByShowOrder() }
                        TextButton(title: "Clear set", color: Theme.grey) { timeline.clearSet() }
                    }
                }
            }
            if !timeline.librarySongs.isEmpty {
                Section {
                    ForEach(timeline.librarySongs) { song in
                        SongRow(timeline: timeline, song: song, setIndex: nil, duration: song.duration, current: false)
                            .listRowBackground(Theme.ink)
                    }
                } header: {
                    ListHeader(title: "Library", detail: "\(timeline.librarySongs.count) songs · timecode order") { EmptyView() }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.ink)
        .environment(\.defaultMinListRowHeight, 40)
    }
}

private struct ListHeader<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).font(Theme.grotesk(15, .medium)).foregroundStyle(Theme.paper)
            Text(detail.uppercased()).font(Theme.mono(9)).tracking(1.2).foregroundStyle(Theme.grey)
            Spacer()
            trailing
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

private struct SongRow: View {
    @ObservedObject var timeline: TimelineModel
    let song: Song
    /// Position on the set, or nil for a library song.
    let setIndex: Int?
    let duration: Double?
    let current: Bool
    @State private var dropTarget = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.gutter) {
            if let setIndex {
                Text(String(format: "%02d", setIndex + 1))
                    .font(Theme.grotesk(20, current ? .medium : .light))
                    .frame(width: 36, alignment: .leading)
            } else {
                Button { timeline.addToSet(song.id) } label: {
                    Text("+").font(Theme.grotesk(22, .light)).frame(width: 36, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Add to the end of the set")
            }
            Text(song.name).font(Theme.grotesk(15, current ? .medium : .regular)).lineLimit(1)
                .foregroundStyle(setIndex == nil ? Theme.grey : Theme.paper)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(song.start.description).font(Theme.mono(11)).foregroundStyle(Theme.grey)
                .frame(width: 96, alignment: .leading)
            Text(duration.map(clock) ?? "—").font(Theme.mono(11)).foregroundStyle(Theme.grey)
                .frame(width: 64, alignment: .trailing)
            audio.frame(width: 220, alignment: .leading)
            HStack(spacing: 16) {
                if let setIndex {
                    TextButton(title: "Play from", color: Theme.grey) { timeline.jump(toSong: setIndex) }
                    TextButton(title: "Remove", color: Theme.grey) { timeline.removeFromSet(song.id) }
                        .help("Take off the set (stays in the library)")
                } else {
                    TextButton(title: "Add to set", color: Theme.grey) { timeline.addToSet(song.id) }
                }
            }
            .frame(width: 170, alignment: .trailing)
        }
        .padding(.vertical, 4)
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
            Divider()
            Button("Delete from Library", role: .destructive) { timeline.remove(song.id) }
        }
    }

    @ViewBuilder private var audio: some View {
        if let path = song.audioPath {
            HStack(spacing: 6) {
                Text(URL(fileURLWithPath: path).lastPathComponent + (song.audioLTCChannel.map { " · TC CH \($0 + 1) \(song.keepLTCChannel ? "PLAYING" : "MUTED")" } ?? ""))
                    .font(Theme.mono(10)).lineLimit(1).truncationMode(.middle)
                Button { timeline.removeAudio(from: song.id) } label: { Text("×").font(Theme.mono(12)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.grey).help("Remove audio")
            }
        } else {
            TextButton(title: "Audio… or drop a file", color: Theme.quiet) { timeline.chooseAudio(for: song.id) }
        }
    }
}

/// `m:ss` or `h:mm:ss`.
func clock(_ seconds: Double) -> String {
    let s = Int(max(0, seconds).rounded(.down))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
