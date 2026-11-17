import SwiftUI
import UnderstudyCore

// MARK: - View

/// The View screen: the selected take's pictures, locked to the timeline. One deck large (ME 1
/// to start) with the others in a strip beside it, or all side by side; the set and transport
/// underneath so you can scrub here too; NDI out at the bottom.
struct ViewScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var viewer: VideoViewer
    @ObservedObject var timeline: TimelineModel
    @AppStorage("understudy.viewSideBySide") private var sideBySide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                Text(takeLabel).font(Theme.grotesk(15, .light)).foregroundStyle(Theme.grey).lineLimit(1)
                Spacer()
                if viewer.slots.count > 1 {
                    word("One large", !sideBySide) { sideBySide = false }
                    word("Side by side", sideBySide) { sideBySide = true }
                }
            }
            pictures.frame(maxHeight: .infinity)
            TimelineTrack(timeline: timeline)
                .frame(height: 96)
                .help("The set: click, drag or swipe to move through it")
            TransportBar(timeline: timeline, compact: true, outputs: false)
            Rule()
            HStack(spacing: 18) {
                Toggle("NDI out", isOn: $viewer.ndiEnabled).toggleStyle(.switch).controlSize(.small).tint(Theme.lock)
                Toggle("Full size", isOn: $viewer.ndiFullSize).toggleStyle(.checkbox).controlSize(.small)
                    .help("Send the files' own size over NDI (heavier); off sends 1080p")
                    .disabled(!viewer.ndiEnabled)
                PlaybackLUTMenus(viewer: viewer)
                Text(viewer.ndiStatus).font(Theme.grotesk(12, .light)).foregroundStyle(Theme.grey).lineLimit(1)
                Spacer()
                Button { model.loadViewerTake() } label: {
                    Text("Reload take").font(Theme.grotesk(13, .light)).foregroundStyle(Theme.grey)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { model.viewerAppeared() }
        .onDisappear { model.viewerDisappeared() }
    }

    private var takeLabel: String {
        guard let take = model.takes.first(where: { $0.offset == model.selectedTake }) else {
            return "No take selected"
        }
        return "Take #\(take.clipID) · \(take.name)"
    }

    @ViewBuilder private var pictures: some View {
        let slots = viewer.slots
        if slots.isEmpty {
            Text("No decks with takes yet. Record a take (⌘3), back it up (⌘B), and it plays here, locked to the timeline.")
                .font(Theme.grotesk(15, .light)).foregroundStyle(Theme.grey)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Rectangle().fill(Theme.fill))
        } else if sideBySide {
            HStack(alignment: .top, spacing: 12) {
                ForEach(slots) { VideoPane(slot: $0, player: viewer.players[$0.deckID]) }
            }
        } else {
            let main = slots.first { $0.deckID == viewer.solo } ?? slots[0]
            HStack(alignment: .top, spacing: Theme.gutter) {
                VideoPane(slot: main, player: viewer.players[main.deckID])
                if slots.count > 1 {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(slots.filter { $0.deckID != main.deckID }) { slot in
                            Button { viewer.solo = slot.deckID } label: {
                                VideoPane(slot: slot, player: viewer.players[slot.deckID]).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Show \(slot.name) large")
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: 280)
                }
            }
        }
    }

    private func word(_ title: String, _ active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Theme.grotesk(15, active ? .regular : .light)).foregroundStyle(active ? Theme.paper : Theme.grey)
                Rectangle().fill(active ? Theme.paper : Color.clear).frame(height: 2)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Decks

/// The Record screen: everything about the recorders. Control (what they're doing, the take, each
/// deck, Assign and Setup), then the settings that belong to them: timecode in, recording,
/// playback, backup.
struct DecksScreen: View {
    let content: CGFloat
    let height: CGFloat
    let assign: () -> Void
    let backup: () -> Void
    @AppStorage("understudy.decksSection") private var section = Section.control.rawValue

    enum Section: String, CaseIterable {
        case control, timecode, recording, playback, backup
        var title: String {
            switch self {
            case .control: return "Control"
            case .timecode: return "Timecode in"
            case .recording: return "Recording"
            case .playback: return "Playback"
            case .backup: return "Backup"
            }
        }
        var about: String {
            switch self {
            case .control: return ""
            case .timecode: return "Where show code comes from. Stop and Record log takes against it; Play to code chases it."
            case .recording: return "How the decks record, and what they call the files."
            case .playback: return "How the decks chase code, and pictures of them on this Mac."
            case .backup: return "Takes copied off the decks by FTP. Backed-up takes are what View plays."
            }
        }
    }

    var body: some View {
        let current = Section(rawValue: section) ?? .control
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 24) {
                ForEach(Section.allCases, id: \.self) { s in
                    Button { section = s.rawValue } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(s.title).font(Theme.grotesk(15, s == current ? .regular : .light))
                                .foregroundStyle(s == current ? Theme.paper : Theme.grey)
                            Rectangle().fill(s == current ? Theme.paper : Color.clear).frame(height: 1)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, ShowGrid.labelWidth + Theme.gutter)
            switch current {
            case .control:
                DeckControl(content: content, height: height, assign: assign)
            case .timecode:
                SettingsPage(about: current.about) { TimecodeSettings() }
            case .recording:
                SettingsPage(about: current.about) { RecordingSettings() }
            case .playback:
                SettingsPage(about: current.about) { PlaybackSettings() }
            case .backup:
                SettingsPage(about: current.about) {
                    BackupFolderSettings()
                    SwiftUI.Section {
                        Button("Back Up a Take… (⌘B)", action: backup)
                    }
                }
            }
        }
    }
}

/// A group of settings on the show grid: what they're for in the label column, the form beside
/// it, no wider than reads well.
private struct SettingsPage<Content: View>: View {
    let about: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: Theme.gutter) {
            Text(about)
                .font(Theme.grotesk(13, .light)).foregroundStyle(Theme.grey)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: ShowGrid.labelWidth, alignment: .topLeading)
                .padding(.top, 14)
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .font(Theme.grotesk(13))
                .tint(Theme.paper)
                .frame(maxWidth: 720, alignment: .topLeading)
            Spacer(minLength: 0)
        }
    }
}
