import SwiftUI
import UnderstudyCore

/// The show screen: mode, timecode and lock, the take, and deck health. Readable from across the
/// room. Setup lives in sheets (Assign decks, Backup, per-deck Setup) and Settings.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAssign = false
    @State private var showBackup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Header()
                        .padding(.bottom, 26)
                    SectionHead(index: 1, title: "Mode")
                    ModeBar()
                        .padding(.top, 14)
                        .padding(.bottom, 28)
                    SectionHead(index: 2, title: "Take")
                    TakeBar()
                        .padding(.top, 12)
                        .padding(.bottom, 28)
                    SectionHead(index: 3, title: "Decks") {
                        DeckSummary(assign: { showAssign = true })
                    }
                    DeckRow(assign: { showAssign = true })
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                }
                .padding(.trailing, Theme.marginTrailing)
            }
            .scrollIndicators(.automatic)
            Footer(backup: model.backup, openBackup: { showBackup = true })
                .padding(.trailing, Theme.marginTrailing)
                .padding(.top, 12)
        }
        .padding(.leading, Theme.marginLeading)
        .padding(.top, 30)
        .padding(.bottom, 20)
        .frame(minWidth: 1100, minHeight: 760, alignment: .topLeading)
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
    }
}

extension Notification.Name {
    static let understudyOpenBackup = Notification.Name("understudy.openBackup")
    static let understudyOpenAssign = Notification.Name("understudy.openAssign")
}

// MARK: - Header

private struct Header: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: Theme.gutter) {
            VStack(alignment: .leading, spacing: 6) {
                Text("understudy")
                    .font(Theme.grotesk(40, .medium))
                    .tracking(-0.8)
                Text("Stands in for the cameras between run-throughs.")
                    .font(Theme.grotesk(14, .light))
                    .foregroundStyle(Theme.grey)
                if let resumed = model.resumedMode {
                    HStack(spacing: 12) {
                        Text("RESUMED \(resumed == .record ? "RECORD" : "PLAY TO CODE") AFTER A RESTART")
                        TextButton(title: "OK", color: Theme.amber) { model.resumedMode = nil }
                    }
                    .font(Theme.mono(10))
                    .tracking(1.2)
                    .foregroundStyle(Theme.amber)
                    .padding(.top, 10)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if model.ltcText.hasPrefix("--") {
                    Text("NO LTC")
                        .font(Theme.grotesk(68, .light))
                        .foregroundStyle(alarm ? Theme.signal : Theme.quiet)
                } else {
                    TimecodeText(text: model.ltcText, size: 68)
                        .foregroundStyle(color)
                }
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    if model.settings.separatePlaybackInput {
                        Text(model.inputRole == .playback ? "PLAYBACK CODE" : "SHOW CODE")
                            .font(Theme.mono(10))
                            .tracking(1.2)
                            .foregroundStyle(Theme.grey)
                    }
                    Text(rateText)
                        .font(Theme.mono(10))
                        .tracking(1.2)
                        .foregroundStyle(Theme.grey)
                    if !model.ltcText.hasPrefix("--") {   // the big readout already says NO LTC
                        Text(state)
                            .font(Theme.grotesk(18, .medium))
                            .foregroundStyle(color)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: state)
                if let warning = model.ltcWarning {
                    Text(warning).font(Theme.mono(10)).foregroundStyle(Theme.amber)
                }
            }
        }
    }

    /// Code missing while recording or playing is a fault, not a calm state.
    private var alarm: Bool { model.mode != .stop && !model.ltcRolling }

    /// LOCKED green, ACQUIRING off-white, FREEWHEEL amber, NO LTC grey (red in Record/Play).
    private var state: String {
        if !model.ltcRolling { return "NO LTC" }
        if model.ltcFreewheeling { return "FREEWHEEL" }
        return model.ltcLocked ? "LOCKED" : "ACQUIRING"
    }

    private var color: Color {
        if !model.ltcRolling { return alarm ? Theme.signal : Theme.quiet }
        if model.ltcFreewheeling { return Theme.amber }
        return model.ltcLocked ? Theme.lock : Theme.paper
    }

    /// "30 · AUTO", or "29.97 DF · SET"; "RATE · DETECTING" until auto-detect has measured.
    private var rateText: String {
        if model.settings.ltcRateAuto, model.rateLabel.hasSuffix("DETECTING") { return "RATE · DETECTING" }
        return "\(model.ltcRate.rawValue) · \(model.settings.ltcRateAuto ? "AUTO" : "SET")"
    }
}

// MARK: - Mode

private struct ModeBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let continuous = model.settings.recordMode == .continuous
        HStack(spacing: 0) {
            ModeBlock(title: "Stop", key: "⌘1", active: model.mode == .stop, fill: nil,
                      help: "Decks idle. The live feed passes through to disguise.") { model.requestMode(.stop) }
            VRule()
            ModeBlock(title: continuous ? "Record" : "Record arm", key: "⌘2", active: model.mode == .record, fill: Theme.signal,
                      help: continuous ? "Decks record until Stop; show code is logged." : "Decks record while show code runs.") {
                model.requestMode(.record)
            }
            VRule()
            ModeBlock(title: "Play to code", key: "⌘3", active: model.mode == .playback, fill: Theme.lock,
                      help: "Decks chase show timecode from the selected take.") { model.requestMode(.playback) }
        }
        .frame(height: 84)
        .overlay(Rectangle().stroke(Theme.rule, lineWidth: 1))
    }
}

/// Record and Play fill when active; Stop, the quiet state, takes a heavy outline instead.
private struct ModeBlock: View {
    let title: String
    let key: String
    let active: Bool
    let fill: Color?
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .lastTextBaseline) {
                Text(title)
                    .font(Theme.grotesk(30, active ? .medium : .light))
                    .tracking(-0.4)
                Spacer()
                Text(key).font(Theme.mono(10)).opacity(0.7)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .foregroundStyle(active && fill != nil ? Theme.ink : Theme.paper)
            .background(active ? (fill ?? Theme.ink) : (hover ? Theme.fill : Theme.ink))
            .overlay(Rectangle().strokeBorder(active && fill == nil ? Theme.paper : .clear, lineWidth: 3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Take

/// Always in place (dimmed outside Play), so the layout never jumps.
private struct TakeBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.gutter) {
            if model.takes.isEmpty {
                Text("No takes on the decks yet.")
                    .font(Theme.grotesk(14, .light))
                    .foregroundStyle(Theme.grey)
            } else {
                Menu {
                    ForEach(model.takes) { take in
                        Button(label(for: take)) { model.chooseTake(take.offset) }
                    }
                } label: {
                    Text(current.map(label(for:)) ?? "Choose a take")
                        .font(Theme.grotesk(16, .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 560, alignment: .leading)
                if let take = current {
                    Text(sync(take))
                        .font(Theme.mono(10))
                        .tracking(1.2)
                        .foregroundStyle(take.logged == false ? Theme.amber : Theme.grey)
                }
            }
            Spacer()
            Toggle("Follow latest", isOn: $model.settings.followLatestTake)
                .toggleStyle(.checkbox)
                .font(Theme.mono(10))
                .help("Play the newest take after each recording")
        }
        .opacity(model.mode == .playback ? 1 : 0.55)
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

private struct DeckSummary: View {
    @EnvironmentObject private var model: AppModel
    let assign: () -> Void

    var body: some View {
        let inUse = model.decks.filter { model.settings.decks[$0.id].enabled && !model.settings.decks[$0.id].host.isEmpty }
        let connected = inUse.filter(\.isConnected).count
        let lost = inUse.filter(\.isLost)
        HStack(spacing: 18) {
            if let low = model.lowestMedia, MediaTime.level(low.seconds) != .ok {
                Text("\(String(format: "%02d", low.deck + 1)) MEDIA \(MediaTime.text(low.seconds).uppercased())")
                    .foregroundStyle(MediaTime.level(low.seconds) == .low ? Theme.amber : Theme.signal)
            }
            if !lost.isEmpty {
                Text("\(lost.map { String(format: "%02d", $0.id + 1) }.joined(separator: " ")) LOST")
                    .foregroundStyle(Theme.signal)
            }
            Text("\(connected) OF \(inUse.count) CONNECTED")
                .foregroundStyle(!inUse.isEmpty && lost.isEmpty && connected == inUse.count ? Theme.lock : Theme.grey)
            TextButton(title: "Assign decks", color: model.setupLocked ? Theme.quiet : Theme.paper, action: assign)
                .disabled(model.setupLocked)
                .help(model.setupLocked ? "Locked while recording" : "Addresses, names and decks found on the network")
        }
        .font(Theme.mono(10))
        .tracking(1.2)
    }
}

/// Four equal columns with hairlines between, the first aligned to the left margin.
private struct DeckRow: View {
    @EnvironmentObject private var model: AppModel
    let assign: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(model.decks) { deck in
                if deck.id > 0 {
                    VRule().padding(.horizontal, Theme.gutter / 2)
                }
                DeckCard(deck: deck, config: model.settings.decks[deck.id], assign: assign)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Footer

private struct Footer: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var backup: TakeBackup
    let openBackup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rule()
            HStack(alignment: .center, spacing: Theme.gutter) {
                if let error = model.audioError {
                    Text(error).foregroundStyle(Theme.amber)
                } else {
                    let channel = model.activeChannel
                    let name = model.inputChannelNames.indices.contains(channel) ? model.inputChannelNames[channel] : ""
                    let db = model.inputLevels.indices.contains(channel) ? model.inputLevels[channel] : -60
                    Label8(text: model.settings.separatePlaybackInput
                           ? (model.inputRole == .playback ? "Playback LTC" : "Show LTC") : "LTC in")
                    Text("\(model.activeInputName) · Ch \(channel + 1)\(name.isEmpty || name == "\(channel + 1)" ? "" : " \(name)")")
                        .foregroundStyle(Theme.grey)
                        .lineLimit(1)
                    LevelMeter(db: db).frame(width: 120)
                    Text(LevelMeter.label(db)).foregroundStyle(Theme.grey).frame(width: 48, alignment: .leading)
                }
                Spacer()
                BackupStatus(backup: backup, open: openBackup)
                if model.showMachine.keepingAwake {
                    Text("AWAKE").foregroundStyle(Theme.quiet).help("This Mac won't idle-sleep while Understudy is open")
                }
                Text("shdwbx")
                    .font(Theme.grotesk(15, .medium))
                    .tracking(-0.2)
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
