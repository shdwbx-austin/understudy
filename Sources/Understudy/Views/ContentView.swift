import SwiftUI
import UnderstudyCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    sections
                }
                .padding(.trailing, Theme.marginTrailing)
            }
            .scrollIndicators(.automatic)
            Footer()
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
    }

    @ViewBuilder private var sections: some View {
            Header()
                .padding(.bottom, 28)
            SectionHead(index: 1, title: "Mode")
            ModeBar()
                .padding(.top, 14)
                .padding(.bottom, 30)
            if model.mode == .playback {
                SectionHead(index: 2, title: "Take")
                TakeBar()
                    .padding(.top, 12)
                    .padding(.bottom, 30)
            }
            SectionHead(index: model.mode == .playback ? 3 : 2, title: "Decks") {
                DeckCount()
            }
            DeckRow()
                .padding(.top, 14)
                .padding(.bottom, 30)
            NetworkSection(index: model.mode == .playback ? 4 : 3, discovery: model.discovery)
                .padding(.bottom, 30)
            BackupSection(index: model.mode == .playback ? 5 : 4, backup: model.backup)
                .padding(.bottom, 12)
    }
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
                    .font(Theme.grotesk(15, .light))
                    .foregroundStyle(Theme.grey)
                Text("SHDWBX — DESIGN AND CREATIVE SUPPORT")
                    .font(Theme.mono(9))
                    .tracking(1.4)
                    .foregroundStyle(Theme.quiet)
                    .padding(.top, 10)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                TimecodeText(text: model.ltcText, size: 68)
                    .foregroundStyle(clockColor)
                    .animation(.easeInOut(duration: 0.25), value: clockState)
                HStack(spacing: 18) {
                    HStack(spacing: 7) {
                        StatusDot(color: clockColor, filled: model.ltcRolling)
                        Text(clockState).foregroundStyle(clockColor)
                    }
                    .animation(.easeInOut(duration: 0.25), value: clockState)
                    if model.settings.separatePlaybackInput {
                        Text(model.inputRole == .playback ? "PLAYBACK CODE" : "SHOW CODE")
                            .foregroundStyle(model.inputRole == .playback ? Theme.amber : Theme.paper)
                    }
                    Text(model.rateLabel)
                    Text(model.ltcInfo).foregroundStyle(Theme.grey)
                }
                .font(Theme.mono(10))
                .tracking(1)
                if let warning = model.ltcWarning {
                    Text(warning).font(Theme.mono(10)).foregroundStyle(Theme.amber)
                }
                if let resumed = model.resumedMode {
                    HStack(spacing: 12) {
                        Text("RESUMED \(resumed == .record ? "RECORD" : "PLAY TO CODE") AFTER A RESTART")
                            .foregroundStyle(Theme.amber)
                        TextButton(title: "OK", color: Theme.amber) { model.resumedMode = nil }
                    }
                    .font(Theme.mono(10))
                    .tracking(1)
                }
            }
        }
    }

    /// Stopped (grey) → acquiring (off-white) → locked (green); freewheel (amber).
    private var clockState: String {
        if !model.ltcRolling { return "STOPPED" }
        if model.ltcFreewheeling { return "FREEWHEEL · NO LTC" }
        return model.ltcLocked ? "LOCKED" : "ACQUIRING"
    }

    private var clockColor: Color {
        if !model.ltcRolling { return Theme.quiet }
        if model.ltcFreewheeling { return Theme.amber }
        return model.ltcLocked ? Theme.lock : Theme.paper
    }
}

// MARK: - Mode

private struct ModeBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let continuous = model.settings.recordMode == .continuous
        HStack(spacing: 0) {
            ModeBlock(
                index: "A", title: "Stop", key: "⌘1",
                detail: "Decks idle. Live feed passes through.",
                tint: Theme.paper, active: model.mode == .stop
            ) { model.setMode(.stop) }
            VRule()
            ModeBlock(
                index: "B", title: continuous ? "Record" : "Record arm", key: "⌘2",
                detail: continuous ? "Decks record until Stop. Show code is logged." : "Decks record while show code runs.",
                tint: Theme.signal, active: model.mode == .record
            ) { model.setMode(.record) }
            VRule()
            ModeBlock(
                index: "C", title: "Play to code", key: "⌘3",
                detail: "Decks chase show LTC from the selected take.",
                tint: Theme.paper, active: model.mode == .playback
            ) { model.setMode(.playback) }
        }
        .frame(height: 104)
        .overlay(Rectangle().stroke(Theme.rule, lineWidth: 1))
    }
}

private struct ModeBlock: View {
    let index: String
    let title: String
    let key: String
    let detail: String
    let tint: Color
    let active: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(index).font(Theme.mono(10))
                    Spacer()
                    Text(key).font(Theme.mono(10))
                }
                .opacity(0.7)
                Spacer(minLength: 8)
                Text(title)
                    .font(Theme.grotesk(30, active ? .medium : .light))
                    .tracking(-0.4)
                Text(detail)
                    .font(Theme.grotesk(12, .regular))
                    .opacity(0.72)
                    .padding(.top, 4)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(active ? (tint == Theme.signal ? Theme.paper : Theme.ink) : Theme.paper)
            .background(active ? tint : (hover ? Theme.fill : Theme.ink))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Take

private struct TakeBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.gutter) {
            if model.takes.isEmpty {
                Text("No takes on the decks yet.")
                    .font(Theme.grotesk(14, .light))
                    .foregroundStyle(Theme.grey)
            } else {
                Picker("", selection: $model.selectedTake) {
                    ForEach(model.takes) { take in
                        Text(label(for: take)).tag(take.offset)
                    }
                }
                .labelsHidden()
                .fixedSize()
                if let take = model.takes.first(where: { $0.offset == model.selectedTake }) {
                    Text(sync(take))
                        .font(Theme.mono(10))
                        .tracking(1)
                        .foregroundStyle(take.logged == false ? Theme.amber : Theme.grey)
                }
            }
            Spacer()
            Toggle("Follow latest", isOn: $model.settings.followLatestTake)
                .toggleStyle(.checkbox)
                .font(Theme.mono(10))
            TextButton(title: "Refresh") { model.refreshTakes() }
        }
    }

    private func label(for take: Take) -> String {
        let latest = take.offset == 0 ? "Latest — " : ""
        return "\(latest)#\(take.clipID)  \(take.name)  \(take.duration.description)"
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

private struct DeckCount: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let connected = model.decks.filter(\.isConnected).count
        let lost = model.decks.filter(\.isLost)
        HStack(spacing: 18) {
            if let low = model.lowestMedia, MediaTime.level(low.seconds) != .ok {
                Text("\(String(format: "%02d", low.deck + 1)) MEDIA \(MediaTime.text(low.seconds).uppercased())")
                    .foregroundStyle(MediaTime.level(low.seconds) == .low ? Theme.amber : Theme.signal)
            }
            if !lost.isEmpty {
                Text("\(lost.map { String(format: "%02d", $0.id + 1) }.joined(separator: " ")) LOST")
                    .foregroundStyle(Theme.signal)
            }
            Text("\(connected) OF \(model.decks.count) CONNECTED")
                .foregroundStyle(lost.isEmpty && connected > 0 ? Theme.lock : Theme.quiet)
        }
        .font(Theme.mono(10))
        .tracking(1.2)
    }
}

private struct DeckRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(model.decks) { deck in
                if deck.id > 0 { VRule() }
                DeckCard(deck: deck, discovery: model.discovery, config: $model.settings.decks[deck.id])
                    .padding(.leading, deck.id == 0 ? 0 : 16)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Network

private struct NetworkSection: View {
    @EnvironmentObject private var model: AppModel
    let index: Int
    @ObservedObject var discovery: DeckDiscovery

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(index: index, title: "Network") {
                HStack(spacing: 18) {
                    InterfacePicker()
                    Text(scanSummary)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.quiet)
                    if !unassigned.isEmpty, model.settings.decks.contains(where: { $0.host.isEmpty }) {
                        TextButton(title: "Fill empty slots") { model.fillEmptySlots() }
                    }
                    TextButton(title: discovery.isScanning ? "Scanning…" : "Find decks") { discovery.scan() }
                        .disabled(discovery.isScanning)
                }
            }
            if discovery.found.isEmpty {
                Text(emptyText)
                    .font(Theme.grotesk(13, .light))
                    .foregroundStyle(Theme.grey)
                    .padding(.vertical, 12)
            } else {
                ForEach(discovery.found) { found in
                    FoundRow(found: found)
                    Rule(color: Theme.rule.opacity(0.6))
                }
            }
        }
    }

    private var unassigned: [FoundDeck] { discovery.found.filter { model.slot(for: $0.host) == nil } }

    private var scanSummary: String {
        guard let last = discovery.lastScanned else { return discovery.isScanning ? "" : "NOT SCANNED YET" }
        let nets = discovery.scannedNetworks.joined(separator: ", ")
        return "\(nets) · \(last.formatted(date: .omitted, time: .shortened))".uppercased()
    }

    private var emptyText: String {
        if discovery.isScanning { return "Looking for HyperDecks on the local network…" }
        if discovery.lastScanned == nil { return "Find decks scans the local network for HyperDecks." }
        return "No HyperDecks found. If macOS asked about local network access, allow it and scan again."
    }
}

/// Which network interface discovery looks on.
private struct InterfacePicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let networks = DeckDiscovery.localNetworks()
        let chosen = model.settings.discoveryInterface
        Menu {
            Button("All interfaces") { choose(nil) }
            Divider()
            ForEach(networks) { net in
                Button("\(net.displayName) — \(net.address)  (\(net.cidr))") { choose(net.interface) }
            }
        } label: {
            Text("ON: \(label(chosen, networks))".uppercased())
                .font(Theme.mono(10, bold: true))
                .tracking(1.2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("Which network to look for HyperDecks on")
    }

    private func label(_ chosen: String?, _ networks: [DeckDiscovery.LocalNetwork]) -> String {
        guard let chosen else { return "All interfaces" }
        return networks.first { $0.interface == chosen }?.displayName ?? "\(chosen) (not connected)"
    }

    private func choose(_ interface: String?) {
        model.settings.discoveryInterface = interface
        model.discovery.clear()
        model.discovery.scan()
    }
}

private struct FoundRow: View {
    @EnvironmentObject private var model: AppModel
    let found: FoundDeck

    var body: some View {
        let slot = model.slot(for: found.host)
        HStack(alignment: .firstTextBaseline, spacing: Theme.gutter) {
            Text(found.host)
                .font(Theme.mono(12))
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(found.title).font(Theme.grotesk(14, .regular))
                if let model = found.model, found.name != nil {
                    Text(model).font(Theme.grotesk(12, .light)).foregroundStyle(Theme.grey)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(status(slot))
                .font(Theme.mono(10))
                .tracking(1)
                .foregroundStyle(found.busy && slot == nil ? Theme.amber : Theme.grey)
                .frame(width: 170, alignment: .leading)
            Menu {
                ForEach(model.decks) { deck in
                    let config = model.settings.decks[deck.id]
                    Button("\(String(format: "%02d", deck.id + 1))  \(config.name)\(config.host.isEmpty ? "" : " — replaces \(config.host)")") {
                        model.assign(found, to: deck.id)
                    }
                }
            } label: {
                Text(slot == nil ? "ASSIGN" : "MOVE")
                    .font(Theme.mono(10, bold: true))
                    .tracking(1.2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 10)
    }

    private func status(_ slot: Int?) -> String {
        if let slot { return "IN USE · \(String(format: "%02d", slot + 1))" }
        if found.busy { return "BUSY · OTHER CLIENT" }
        return "AVAILABLE"
    }
}

// MARK: - Footer

private struct Footer: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rule()
            HStack(alignment: .center, spacing: Theme.gutter) {
                if let error = model.audioError {
                    Text(error).foregroundStyle(Theme.amber)
                } else {
                    let name = model.activeInputName
                    let channel = model.activeChannel
                    let channelName = model.inputChannelNames.indices.contains(channel) ? model.inputChannelNames[channel] : ""
                    let db = model.inputLevels.indices.contains(channel) ? model.inputLevels[channel] : -60
                    Label8(text: model.settings.separatePlaybackInput
                           ? (model.inputRole == .playback ? "Playback LTC" : "Show LTC") : "LTC in")
                    Text("\(name) · Ch \(channel + 1)\(channelName.isEmpty ? "" : " \(channelName)")")
                        .foregroundStyle(Theme.grey)
                    LevelMeter(db: db).frame(width: 140)
                    Text(LevelMeter.label(db)).foregroundStyle(Theme.grey).frame(width: 48, alignment: .leading)
                }
                Spacer()
                if model.showMachine.keepingAwake {
                    Text("AWAKE").foregroundStyle(Theme.quiet).help("This Mac won't idle-sleep while Understudy is open")
                }
                Text("⌘,  SETTINGS").foregroundStyle(Theme.quiet)
                Text("shdwbx")
                    .font(Theme.grotesk(15, .medium))
                    .tracking(-0.2)
            }
            .font(Theme.mono(10))
        }
    }
}
