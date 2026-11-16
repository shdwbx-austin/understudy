import SwiftUI
import UnderstudyCore

/// The main window: one bar across the top (name, the three screens, what the decks are doing,
/// show timecode), then Program (the timeline), View (its pictures) or Decks (recording, chasing
/// and setting up the decks), and the input footer.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAssign = false
    @State private var showBackup = false

    var body: some View {
        GeometryReader { geo in
            // Width of the four content columns.
            let content = geo.size.width - Theme.marginLeading - Theme.marginTrailing - ShowGrid.labelWidth - Theme.gutter
            let column = (content - 3 * Theme.gutter) / 4
            VStack(alignment: .leading, spacing: 14) {
                TopBar()
                Rule()
                Group {
                    switch model.screen {
                    case .program:
                        TimelineWorkspace(timeline: model.timeline, column: column)
                    case .view:
                        ViewScreen(viewer: model.viewer, timeline: model.timeline)
                    case .decks:
                        DecksScreen(content: content, height: geo.size.height,
                                    assign: { showAssign = true }, backup: { showBackup = true })
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                Footer(backup: model.backup, openBackup: { showBackup = true })
            }
            .padding(.trailing, Theme.marginTrailing)
            .padding(.leading, Theme.marginLeading)
            .padding(.top, 30)
            .padding(.bottom, 20)
        }
        .frame(minWidth: 1100, minHeight: 760, alignment: .topLeading)
        .navigationTitle(model.projectName.map { "understudy — \($0)" } ?? "understudy")
        .modifier(MarkerTypesSheet(timeline: model.timeline))
        .background(Theme.ink)
        .foregroundStyle(Theme.paper)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showAssign) { AssignDecksView().environmentObject(model) }
        .sheet(isPresented: $showBackup) { BackupView(backup: model.backup).environmentObject(model) }
        .confirmationDialog(
            "Stop recording?",
            isPresented: Binding(get: { model.pendingMode != nil }, set: { if !$0 { model.pendingMode = nil } }),
            titleVisibility: .visible
        ) {
            Button(model.pendingMode == .playback ? "Stop recording and play to code" : "Stop recording", role: .destructive) {
                model.confirmPendingMode()
            }
            Button("Keep recording", role: .cancel) { model.pendingMode = nil }
        } message: {
            Text("This ends the take on every deck.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .understudyOpenBackup)) { _ in showBackup = true }
        .onReceive(NotificationCenter.default.publisher(for: .understudyOpenAssign)) { _ in showAssign = true }
        .onAppear { model.mainWindowOpened() }
    }
}

/// The Decks screen's Control section: the show code large, the deck state, the take and every
/// deck. Readable from across the room.
struct DeckControl: View {
    @EnvironmentObject private var model: AppModel
    let content: CGFloat
    let height: CGFloat
    let assign: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 22) {
                // The timecode blocks take the room that's left once all four decks fit.
                let byWidth = (content - 3 * Theme.gutter) / 4 / 1.4
                let byHeight = (height - 960) / 1.12
                Header(heroSize: min(130, byWidth, max(48, byHeight)))
                GridRow {
                    VStack(alignment: .leading, spacing: 10) {
                        RowLabel(index: 1, title: "Decks do")
                        ModeDescription()
                    }
                } content: {
                    ModeBar()
                }
                GridRow {
                    RowLabel(index: 2, title: "Take")
                } content: {
                    TakeBar()
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 14) {
                        RowLabel(index: 3, title: "Decks")
                        DeckSummary(assign: assign)
                    }
                } content: {
                    DeckRow(assign: assign)
                }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.automatic)
    }
}

extension Notification.Name {
    static let understudyOpenBackup = Notification.Name("understudy.openBackup")
    static let understudyOpenAssign = Notification.Name("understudy.openAssign")
}

// MARK: - Header

/// The wordmark in the label column; the show timecode, huge and flush left, across all four
/// columns; its state in a single line beneath, one item per column.
private struct Header: View {
    @EnvironmentObject private var model: AppModel
    let heroSize: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: Theme.gutter) {
            VStack(alignment: .leading, spacing: 6) {
                RowLabel(index: 0, title: model.showCodeFromTimeline ? "Show code (timeline)" : "Show code")
            }
            .frame(width: ShowGrid.labelWidth, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 10) {
                // Hours, minutes, seconds, frames: one labelled block per grid column, numeral set
                // bottom-right, after the Swiss clock posters.
                ClockDigits(readout: model.readout, size: heroSize, color: numeralColor, alarm: alarm)
                ColumnGrid {
                    Text(state)
                        .font(Theme.grotesk(22, .medium))
                        .foregroundStyle(color)
                        .animation(.easeInOut(duration: 0.25), value: state)
                    Text(rateText).font(Theme.mono(11)).tracking(1.2).foregroundStyle(Theme.grey)
                    Text(model.settings.separatePlaybackInput ? (model.inputRole == .playback ? "PLAYBACK CODE" : "SHOW CODE") : "")
                        .font(Theme.mono(11)).tracking(1.2).foregroundStyle(Theme.grey)
                    VStack(alignment: .leading, spacing: 6) {
                        if let warning = model.ltcWarning {
                            Text(warning).font(Theme.mono(10)).foregroundStyle(Theme.amber)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let resumed = model.resumedMode {
                            Text("RESUMED \(resumed == .record ? "RECORD" : resumed == .timeline ? "TIMELINE" : "PLAY TO CODE") AFTER A RESTART")
                                .font(Theme.mono(10)).tracking(1.2).foregroundStyle(Theme.amber)
                                .fixedSize(horizontal: false, vertical: true)
                            TextButton(title: "OK", color: Theme.amber) { model.resumedMode = nil }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var numeralColor: Color {
        model.hasShowCode ? color : Theme.quiet
    }

    private var alarm: Bool { model.clockAlarm }
    private var state: String { model.clockState }
    private var color: Color { model.clockColor }

    /// "30 · AUTO", or "29.97 DF · SET"; "RATE · DETECTING" until auto-detect has measured.
    private var rateText: String {
        if model.settings.ltcRateAuto, model.rateLabel.hasSuffix("DETECTING") { return "RATE · DETECTING" }
        return "\(model.ltcRate.rawValue) · \(model.settings.ltcRateAuto ? "AUTO" : "SET")"
    }
}

/// Hours, minutes, seconds, frames: one labelled block per grid column, numerals set bottom-right
/// after the Swiss clock posters. Watches only the readout, so the rest of the window doesn't
/// redraw every frame.
private struct ClockDigits: View {
    @ObservedObject var readout: Readout
    let size: CGFloat
    let color: Color
    let alarm: Bool

    var body: some View {
        ColumnGrid {
            ForEach(Array(zip(["hours", "minutes", "seconds", "frames"], parts).enumerated()), id: \.offset) { _, item in
                TimeBlock(label: item.0, value: item.1, size: size, color: color, alarm: alarm)
            }
        }
    }

    /// "01:10:44:17" (or ";" before frames when drop-frame) → ["01", "10", "44", "17"]; dashes with no code.
    private var parts: [String] {
        let p = readout.ltcText.split(whereSeparator: { $0 == ":" || $0 == ";" }).map(String.init)
        return p.count == 4 && !readout.ltcText.hasPrefix("--") ? p : ["––", "––", "––", "––"]
    }
}

/// The level of one input channel, watching only the readout.
struct LiveLevel<Content: View>: View {
    @ObservedObject var readout: Readout
    let channel: Int
    @ViewBuilder let content: (Float) -> Content

    var body: some View {
        content(readout.inputLevels.indices.contains(channel) ? readout.inputLevels[channel] : -60)
    }
}

/// One unit of the show timecode: a dark field, its name small at top left, the two digits
/// large at bottom right. Outlined red when code is missing during Record or Play.
private struct TimeBlock: View {
    let label: String
    let value: String
    let size: CGFloat
    let color: Color
    let alarm: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.fill)
            Text(label)
                .font(Theme.grotesk(14, .light))
                .foregroundStyle(Theme.grey)
                .padding(12)
            TimecodeText(text: value, size: size)
                .foregroundStyle(color)
                .padding(.trailing, size * 0.06)
                .padding(.bottom, -size * 0.08)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .frame(height: size * 1.12 + 26)
        .overlay(Rectangle().strokeBorder(alarm ? Theme.signal : .clear, lineWidth: 2))
        .clipped()
    }
}

// MARK: - Mode

/// Three fields on the first three columns; the active one is a solid colour field. The fourth
/// column says what the current mode does.
private struct ModeBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let continuous = model.settings.recordMode == .continuous
        ColumnGrid {
            ModeBlock(title: "Stop", key: "⇧⌘.", active: model.mode == .stop, fill: nil) { model.requestMode(.stop) }
            ModeBlock(title: continuous ? "Record" : "Record arm", key: "⇧⌘R", active: model.mode == .record, fill: Theme.signal) {
                model.requestMode(.record)
            }
            ModeBlock(title: "Play to code", key: "⇧⌘P", active: model.mode == .playback, fill: Theme.lock) {
                model.requestMode(.playback)
            }
            ModeBlock(title: "Follow Program", key: "⇧⌘F", active: model.mode == .timeline, fill: Theme.paper) {
                model.requestMode(.timeline)
            }
        }
        .frame(height: 76)
    }
}

/// One line on what the current mode does, under the Mode label.
private struct ModeDescription: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(Theme.grotesk(12, .light))
                .foregroundStyle(Theme.grey)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var text: String {
        switch model.mode {
        case .stop: return "Decks idle. The live feed passes through to disguise."
        case .record:
            return model.settings.recordMode == .continuous
                ? "Decks record until Stop. Show code is logged against the take." : "Decks record while show code runs."
        case .playback: return "Decks chase show timecode from the selected take."
        case .timeline: return "The decks follow Program: parked on the playhead, rolling with the timeline."
        }
    }
}

/// Record and Play fill with their colour when active; Stop, the quiet state, takes a heavy outline.
private struct ModeBlock: View {
    let title: String
    let key: String
    let active: Bool
    let fill: Color?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading) {
                Text(key).font(Theme.mono(10)).opacity(0.6)
                Spacer(minLength: 0)
                Text(title)
                    .font(Theme.grotesk(30, active ? .medium : .light))
                    .tracking(-0.5)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .foregroundStyle(active && fill != nil ? Theme.ink : Theme.paper)
            .background(active ? (fill ?? Theme.ink) : (hover ? Theme.fill : Theme.ink))
            .overlay(Rectangle().strokeBorder(active ? (fill == nil ? Theme.paper : .clear) : Theme.rule,
                                               lineWidth: active && fill == nil ? 3 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Take

/// The take across three columns; Follow latest in the fourth. Always in place (dimmed outside
/// Play) so the layout never jumps.
private struct TakeBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ColumnGrid {
            VStack(alignment: .leading, spacing: 6) {
                if model.takes.isEmpty {
                    Text("No takes on the decks yet.")
                        .font(Theme.grotesk(18, .light))
                        .foregroundStyle(Theme.grey)
                } else {
                    Menu {
                        ForEach(model.takes) { take in
                            Button(label(for: take)) { model.chooseTake(take.offset) }
                        }
                    } label: {
                        Text(current.map(label(for:)) ?? "Choose a take")
                            .font(Theme.grotesk(18, .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .menuStyle(.borderlessButton)
                    if let take = current {
                        Text(sync(take))
                            .font(Theme.mono(10))
                            .tracking(1.2)
                            .foregroundStyle(take.logged == false ? Theme.amber : Theme.grey)
                    }
                }
            }
            .span(3)
            Toggle("Follow latest", isOn: $model.settings.followLatestTake)
                .toggleStyle(.checkbox)
                .font(Theme.mono(10))
                .help("Play the newest take after each recording")
        }
        .opacity(model.isPlayingBack ? 1 : 0.5)
    }

    private var current: Take? { model.takes.first { $0.offset == model.selectedTake } }

    private func label(for take: Take) -> String {
        "\(take.offset == 0 ? "Latest — " : "")#\(take.clipID)  \(take.name)  \(take.duration.description)"
    }

    private func sync(_ take: Take) -> String {
        switch take.logged {
        case true?: return "SHOW CODE LOGGED"
        case false?: return "NO SHOW CODE LOGGED"
        case nil: return "CLIP TIMECODE"
        }
    }
}

// MARK: - Decks

/// In the label column under "Decks": what needs attention, then Assign.
private struct DeckSummary: View {
    @EnvironmentObject private var model: AppModel
    let assign: () -> Void

    var body: some View {
        let inUse = model.decks.filter { model.settings.decks[$0.id].enabled && !model.settings.decks[$0.id].host.isEmpty }
        let connected = inUse.filter(\.isConnected).count
        let lost = inUse.filter(\.isLost)
        VStack(alignment: .leading, spacing: 6) {
            Text("\(connected) of \(inUse.count) connected")
                .foregroundStyle(!inUse.isEmpty && lost.isEmpty && connected == inUse.count ? Theme.lock : Theme.grey)
            if !lost.isEmpty {
                Text("\(lost.map { String(format: "%02d", $0.id + 1) }.joined(separator: " ")) lost")
                    .foregroundStyle(Theme.signal)
            }
            if let low = model.lowestMedia, MediaTime.level(low.seconds) != .ok {
                Text("\(String(format: "%02d", low.deck + 1)) media \(MediaTime.text(low.seconds))")
                    .foregroundStyle(MediaTime.level(low.seconds) == .low ? Theme.amber : Theme.signal)
            }
            TextButton(title: "Assign decks", color: model.setupLocked ? Theme.quiet : Theme.paper, action: assign)
                .disabled(model.setupLocked)
                .help(model.setupLocked ? "Locked while recording" : "Addresses, names and decks found on the network")
                .padding(.top, 6)
        }
        .font(Theme.grotesk(13, .regular))
    }
}

/// The decks as full-width rows, one under another, divided by hairlines.
private struct DeckRow: View {
    @EnvironmentObject private var model: AppModel
    let assign: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.decks) { deck in
                if deck.id > 0 { Rule(color: Theme.rule) }
                DeckCard(deck: deck, config: model.settings.decks[deck.id], assign: assign)
            }
        }
    }
}

// MARK: - Footer

/// The LTC input on the grid: its label in the left column, device across two columns, the level
/// in the third, status and the shdwbx mark in the fourth.
private struct Footer: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var backup: TakeBackup
    let openBackup: () -> Void

    var body: some View {
        GridRow {
            Label8(text: model.showCodeFromTimeline ? "Show code" : model.settings.separatePlaybackInput
                   ? (model.inputRole == .playback ? "Playback LTC" : "Show LTC") : "LTC in")
        } content: {
            ColumnGrid {
                Group {
                    if model.showCodeFromTimeline {
                        Text("Song timeline · " + (model.danteStatus.isRouted ? "Dante out 1–3" : model.timecodeOutLabel ?? "LTC out off"))
                            .foregroundStyle(Theme.grey)
                            .lineLimit(1)
                    } else if let error = model.audioError {
                        Text(error).foregroundStyle(Theme.amber).lineLimit(2)
                    } else {
                        let channel = model.activeChannel
                        let name = model.inputChannelNames.indices.contains(channel) ? model.inputChannelNames[channel] : ""
                        Text("\(model.activeInputName) · Ch \(channel + 1)\(name.isEmpty || name == "\(channel + 1)" ? "" : " \(name)")")
                            .foregroundStyle(Theme.grey)
                            .lineLimit(1)
                    }
                }
                .span(2)
                LiveLevel(readout: model.readout, channel: model.activeChannel) { db in
                    HStack(spacing: 12) {
                        LevelMeter(db: db)
                        Text(LevelMeter.label(db)).foregroundStyle(Theme.grey).frame(width: 48, alignment: .leading)
                    }
                }
                HStack(spacing: 16) {
                    BackupStatus(backup: backup, open: openBackup)
                    if model.showMachine.keepingAwake {
                        Text("AWAKE").foregroundStyle(Theme.quiet).help("This Mac won't idle-sleep while Understudy is open")
                    }
                    Spacer(minLength: 0)
                    Text("shdwbx").font(Theme.grotesk(15, .medium)).tracking(-0.2)
                }
            }
            .font(Theme.mono(10))
        }
    }
}

/// One line: a button when idle, progress while copying, the outcome after.
private struct BackupStatus: View {
    @ObservedObject var backup: TakeBackup
    let open: () -> Void

    var body: some View {
        let failed = backup.jobs.filter { if case .failed = $0.state { return true } else { return false } }.count
        let total = backup.jobs.count
        if backup.isRunning {
            let fraction = backup.jobs.compactMap(\.fraction).reduce(0, +) / Double(max(1, total))
            TextButton(title: String(format: "Backing up %.0f%%", fraction * 100), color: Theme.paper, action: open)
        } else if failed > 0 {
            TextButton(title: "Backup: \(failed) failed", color: Theme.signal, action: open)
        } else if total > 0 {
            TextButton(title: "Backed up", color: Theme.lock, action: open)
        } else {
            TextButton(title: "Back up ⌘B", color: Theme.grey, action: open)
        }
    }
}

// MARK: - Clock state (shared by the big header and the Timeline bar)

extension AppModel {
    /// Code missing while recording or playing is a fault, not a calm state: only when the decks
    /// depend on incoming LTC.
    var clockAlarm: Bool { (mode == .record || mode == .playback) && !ltcRolling }

    /// LOCKED green, ACQUIRING off-white, FREEWHEEL amber, NO LTC grey (red in Record/Play).
    var clockState: String {
        if showCodeFromTimeline { return ltcRolling ? "Timeline" : "Timeline paused" }
        if !ltcRolling { return hasShowCode ? "No LTC" : "Waiting for code" }
        if ltcFreewheeling { return "Freewheel" }
        return ltcLocked ? "Locked" : "Acquiring"
    }

    var clockColor: Color {
        if !ltcRolling { return clockAlarm ? Theme.signal : Theme.quiet }
        if ltcFreewheeling { return Theme.amber }
        return ltcLocked ? Theme.lock : Theme.paper
    }
}

// MARK: - Top bar

/// One line on every screen: the name and project, the three screens, what the decks are doing,
/// and the show timecode with its state.
struct TopBar: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(alignment: .center, spacing: Theme.gutter) {
            VStack(alignment: .leading, spacing: 2) {
                Text("understudy").font(Theme.grotesk(22, .medium)).tracking(-0.4)
                Text(model.projectName ?? "No project").font(Theme.grotesk(12, .light)).foregroundStyle(Theme.grey).lineLimit(1)
            }
            .frame(width: ShowGrid.labelWidth, alignment: .leading)
            ScreenTabs()
            Spacer(minLength: Theme.gutter)
            if model.screen == .program {
                Button { openWindow(id: "timeline") } label: {
                    Text("Open in window ⌘T").font(Theme.grotesk(13, .light)).foregroundStyle(Theme.grey)
                }
                .buttonStyle(.plain)
                .help("Open the timeline in its own window")
            }
            DeckState()
            VStack(alignment: .trailing, spacing: 3) {
                CompactClock(readout: model.readout, color: model.hasShowCode ? model.clockColor : Theme.quiet)
                Text(model.clockState).font(Theme.grotesk(13, .light)).foregroundStyle(model.clockColor.opacity(0.85))
            }
        }
        .frame(height: 64)
    }
}

/// Program · View · Decks (⌘1–3): light Haas words, the current one in white with a fine underline.
struct ScreenTabs: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 30) {
            tab("Program", "⌘1", .program, "The timeline: songs, markers, transport. The decks follow it.")
            tab("View", "⌘2", .view, "The take's pictures, locked to the timeline, and NDI out")
            tab("Decks", "⌘3", .decks, "Record, play to code, and set up the decks, timecode and backup")
        }
        .fixedSize()
    }

    private func tab(_ title: String, _ key: String, _ screen: AppModel.Screen, _ help: String) -> some View {
        let active = model.screen == screen
        return Button { model.show(screen) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Theme.grotesk(19, active ? .regular : .light))
                    .tracking(-0.2)
                    .foregroundStyle(active ? Theme.paper : Theme.grey)
                Rectangle().fill(active ? Theme.paper : Color.clear).frame(height: 2)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(help) (\(key))")
    }
}

/// What the decks are doing, on every screen: a coloured square and a few words. Recording is
/// red, chasing LTC green, following Program white, stopped grey. Click to go to Decks.
struct DeckState: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let (text, color) = state
        Button { model.show(.decks) } label: {
            HStack(spacing: 8) {
                Rectangle().fill(color).frame(width: 9, height: 9)
                Text(text).font(Theme.grotesk(14, model.mode == .record ? .medium : .light)).foregroundStyle(color)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Rectangle().fill(model.mode == .record ? Theme.signal.opacity(0.14) : Theme.fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("What the decks are doing. Click for the Decks screen (⌘3).")
    }

    private var state: (String, Color) {
        let n = model.activeDecks.count
        let decks = n == 0 ? "no decks connected" : n == 1 ? "1 deck" : "\(n) decks"
        switch model.mode {
        case .record: return ("Recording · \(decks)", Theme.signal)
        case .playback: return ("Playing to code · \(decks)", Theme.lock)
        case .timeline: return ("Following Program · \(decks)", Theme.paper)
        case .stop: return ("Decks stopped", Theme.grey)
        }
    }
}

/// The show timecode on one line, in fixed cells, watching only the readout.
private struct CompactClock: View {
    @ObservedObject var readout: Readout
    let color: Color

    var body: some View {
        TimecodeText(text: readout.ltcText.hasPrefix("--") ? "--:--:--:--" : readout.ltcText, size: 34, weight: .light)
            .foregroundStyle(color)
    }
}
