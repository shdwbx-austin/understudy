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
            VStack(alignment: .trailing, spacing: 2) {
                Text(timeline.showTimecode?.display(dropFrame: model.ltcRate.isDropFrame) ?? "--:--:--:--")
                    .font(Theme.mono(30, bold: false))
                    .monospacedDigit()
                    .foregroundStyle(timeline.isPlaying ? Theme.lock : Theme.paper)
                Text(currentName).font(Theme.grotesk(14, .regular)).foregroundStyle(Theme.grey).lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        if timeline.songs.isEmpty { return "IMPORT A SONG LIST TO START" }
        let mode = model.mode == .timeline ? "DRIVING THE DECKS" : "SWITCH TO TIMELINE MODE (⌘4) TO DRIVE THE DECKS"
        return "\(timeline.songs.count) SONGS · \(clock(timeline.layout.totalDuration)) · \(mode)"
    }

    private var currentName: String {
        guard let i = timeline.currentIndex else { return "—" }
        let item = timeline.layout.items[i]
        let lead = timeline.playhead < item.timelineStart ? "Next: " : ""
        return "\(lead)\(String(format: "%02d", i + 1))  \(item.song.name)"
    }
}

// MARK: - Track

/// Song blocks to scale, lead-ins hatched, a marker and number at each song start, and the playhead.
/// Drag anywhere to scrub; double-click a song to jump to its start.
private struct TimelineTrack: View {
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
                        Rectangle().strokeBorder(current ? Theme.paper : Theme.rule, lineWidth: 1)
                        if w > 46 {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.song.name).font(Theme.grotesk(13, .medium)).lineLimit(2)
                                Text(item.song.start.description).font(Theme.mono(9)).foregroundStyle(Theme.grey)
                                if item.song.audioPath == nil {
                                    Text("NO AUDIO").font(Theme.mono(8, bold: true)).tracking(1).foregroundStyle(Theme.quiet)
                                }
                            }
                            .padding(6)
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
                let px = min(max(0, timeline.playhead * scale), geo.size.width - 1)
                Rectangle()
                    .fill(timeline.isPlaying ? Theme.lock : Theme.signal)
                    .frame(width: 2, height: geo.size.height)
                    .offset(x: px - 1)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if timeline.isPlaying { timeline.pause() }
                        timeline.seek(to: value.location.x / scale)
                    }
            )
        }
        .clipped()
        .overlay(alignment: .center) {
            if timeline.songs.isEmpty {
                TextButton(title: "Import song list…") { timeline.chooseCSV() }
            }
        }
    }
}

// MARK: - Transport

private struct TransportBar: View {
    @ObservedObject var timeline: TimelineModel

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

            Text("\(clock(timeline.playhead)) / \(clock(timeline.layout.totalDuration))")
                .font(Theme.mono(12)).monospacedDigit().foregroundStyle(Theme.grey)
            Spacer()
            Stepper(value: $timeline.gap, in: 0...10, step: 0.5) {
                Text(String(format: "LEAD-IN %.1f S", timeline.gap)).font(Theme.mono(10)).tracking(1.2)
            }
            .help("Gap before each song, so the decks can park on its footage and be rolling on its first frame")
            TextButton(title: "Show order") { timeline.sortByShowOrder() }
                .help("Put the songs back in show timecode order")
            TextButton(title: "Import CSV…") { timeline.chooseCSV() }
        }
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

/// Playlist order. Drag rows to reorder; drop an audio file on a row (or use Audio…) to give it sound.
private struct SongList: View {
    @ObservedObject var timeline: TimelineModel

    var body: some View {
        List {
            ForEach(Array(timeline.songs.enumerated()), id: \.element.id) { index, song in
                SongRow(timeline: timeline, index: index, song: song,
                        duration: timeline.layout.items.indices.contains(index) ? timeline.layout.items[index].duration : nil,
                        current: timeline.currentSongID == song.id)
                    .listRowBackground(timeline.currentSongID == song.id ? Theme.fill : Theme.ink)
            }
            .onMove { timeline.move(from: $0, to: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.ink)
        .environment(\.defaultMinListRowHeight, 40)
    }
}

private struct SongRow: View {
    @ObservedObject var timeline: TimelineModel
    let index: Int
    let song: Song
    let duration: Double?
    let current: Bool
    @State private var dropTarget = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.gutter) {
            Text(String(format: "%02d", index + 1))
                .font(Theme.grotesk(20, current ? .medium : .light))
                .frame(width: 36, alignment: .leading)
            Text(song.name).font(Theme.grotesk(15, current ? .medium : .regular)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(song.start.description).font(Theme.mono(11)).foregroundStyle(Theme.grey)
                .frame(width: 96, alignment: .leading)
            Text(duration.map(clock) ?? "—").font(Theme.mono(11)).foregroundStyle(Theme.grey)
                .frame(width: 64, alignment: .trailing)
            audio.frame(width: 220, alignment: .leading)
            TextButton(title: "Play from", color: Theme.grey) { timeline.jump(toSong: index) }
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
            Button("Choose Audio…") { timeline.chooseAudio(for: song.id) }
            if song.audioPath != nil { Button("Remove Audio") { timeline.removeAudio(from: song.id) } }
            Divider()
            Button("Remove Song", role: .destructive) { timeline.remove(song.id) }
        }
    }

    @ViewBuilder private var audio: some View {
        if let path = song.audioPath {
            HStack(spacing: 6) {
                Text(URL(fileURLWithPath: path).lastPathComponent).font(Theme.mono(10)).lineLimit(1).truncationMode(.middle)
                Button { timeline.removeAudio(from: song.id) } label: { Text("×").font(Theme.mono(12)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.grey).help("Remove audio")
            }
        } else {
            TextButton(title: "Audio… or drop a file", color: Theme.quiet) { timeline.chooseAudio(for: song.id) }
        }
    }
}

/// `m:ss` or `h:mm:ss`.
private func clock(_ seconds: Double) -> String {
    let s = Int(max(0, seconds).rounded(.down))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
