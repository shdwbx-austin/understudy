import SwiftUI
import UnderstudyCore

/// Which HyperDeck is in which slot. Edits are a draft: nothing changes on the decks until Apply,
/// so a half-typed address is never mistaken for the live one. Locked while recording.
struct AssignDecksView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [DeckConfig] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Assign decks").font(Theme.grotesk(26, .medium))
                Spacer()
                TextButton(title: "Cancel", color: Theme.grey) { dismiss() }
                TextButton(title: "Apply", color: canApply ? Theme.lock : Theme.quiet) { apply() }
                    .disabled(!canApply)
                    .keyboardShortcut(.defaultAction)
                    .padding(.leading, 18)
            }
            .padding(.bottom, 8)
            if model.setupLocked {
                Text("RECORDING — DECK ASSIGNMENT IS LOCKED UNTIL STOP")
                    .font(Theme.mono(10, bold: true)).tracking(1.2).foregroundStyle(Theme.amber)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHead(index: 1, title: "Slots")
                        .padding(.top, 16)
                    ForEach(draft.indices, id: \.self) { i in
                        SlotRow(config: $draft[i], number: i + 1, duplicate: duplicate(i), found: model.discovery.found,
                                sources: model.recorderSources,
                                remove: draft.count > 1 ? { draft.remove(at: i) } : nil)
                        Rule(color: Theme.rule.opacity(0.6))
                    }
                    HStack(spacing: 16) {
                        TextButton(title: "+ Add deck", color: draft.count < AppSettings.maxDecks ? Theme.paper : Theme.quiet) {
                            let next = (draft.map(\.id).max() ?? -1) + 1
                            draft.append(DeckConfig(id: max(next, model.settings.decks.count), name: "ME \(draft.count + 1)", host: ""))
                        }
                        .disabled(draft.count >= AppSettings.maxDecks)
                        Text("\(draft.count) OF \(AppSettings.maxDecks) DECKS · SAVED WITH THE PROJECT")
                            .font(Theme.mono(9)).tracking(1.2).foregroundStyle(Theme.grey)
                    }
                    .padding(.top, 12)
                    NetworkList(discovery: model.discovery, draft: $draft)
                        .padding(.top, 28)
                }
                .padding(.trailing, 8)
            }
            .disabled(model.setupLocked)
        }
        .padding(28)
        .frame(width: 860, height: 700, alignment: .topLeading)
        .background(Theme.ink)
        .foregroundStyle(Theme.paper)
        .preferredColorScheme(.dark)
        .onAppear {
            draft = model.settings.decks
            model.discovery.startBrowsing()
            model.recorderSources.refresh()
        }
        .onDisappear { model.discovery.stopBrowsing() }
    }

    private var canApply: Bool { !model.setupLocked && draft != model.settings.decks }

    /// Another slot already using this slot's address (or, for the recorder, its capture device:
    /// a device can only be opened once).
    private func duplicate(_ i: Int) -> Int? {
        func key(_ c: DeckConfig) -> String? {
            if let host = c.networkHost { return "host:\(host)" }
            if c.isRecorder, let source = c.recorder.source, source.kind == .capture { return "capture:\(source.id)" }
            return nil
        }
        guard let mine = key(draft[i]) else { return nil }
        return draft.indices.first { $0 != i && draft[$0].enabled && key(draft[$0]) == mine }
    }

    private func apply() {
        guard !model.setupLocked else { return }
        model.applyDeckDraft(draft)
        dismiss()
    }
}

/// One slot: number, name, address (with the found decks), on/off.
private struct SlotRow: View {
    @Binding var config: DeckConfig
    let number: Int
    let duplicate: Int?
    let found: [FoundDeck]
    @ObservedObject var sources: RecorderSources
    let remove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.gutter) {
                Text(String(format: "%02d", number))
                    .font(Theme.grotesk(26, .light))
                    .foregroundStyle(config.enabled ? Theme.paper : Theme.quiet)
                    .frame(width: 44, alignment: .leading)
                TextField("Name", text: $config.name)
                    .textFieldStyle(.plain)
                    .font(Theme.grotesk(16, .medium))
                    .frame(width: 200)
                kindMenu
                if config.isRecorder {
                    recorderFields
                } else {
                    addressField
                }
                Toggle("In use", isOn: $config.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.lock)
                    .font(Theme.mono(10))
                if let remove {
                    Button(action: remove) { Text("×").font(Theme.grotesk(18)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.grey)
                        .help("Remove this deck (the ones after it move up)")
                }
            }
            if let duplicate {
                Text(config.isRecorder
                     ? "SAME CAPTURE DEVICE AS \(String(format: "%02d", duplicate + 1)) — IT CAN ONLY BE OPENED ONCE"
                     : "SAME ADDRESS AS \(String(format: "%02d", duplicate + 1)) — ONE DECK CAN'T FILL TWO SLOTS")
                    .font(Theme.mono(9, bold: true)).tracking(1.2).foregroundStyle(Theme.amber)
                    .padding(.leading, 44 + Theme.gutter)
            }
            if config.isRecorder, let source = config.recorder.source, source.kind == .ndi, NDIFinder.isOwnOutput(source.id) {
                Text("THAT'S UNDERSTUDY'S OWN NDI OUTPUT (DECK FOOTAGE THROUGH THE PLAYBACK LUT) — CHOOSE THE SOURCE ITSELF")
                    .font(Theme.mono(9, bold: true)).tracking(1.2).foregroundStyle(Theme.amber)
                    .padding(.leading, 44 + Theme.gutter)
            }
            if config.isRecorder {
                Text("RECORDS ON THIS MAC — A STAND-IN FOR A HYPERDECK: USES CPU, GPU AND DISK WHILE THE SHOW RUNS")
                    .font(Theme.mono(9)).tracking(1.2).foregroundStyle(Theme.grey)
                    .padding(.leading, 44 + Theme.gutter)
            }
        }
        .padding(.vertical, 10)
    }

    /// A HyperDeck's address, with the decks found on the network.
    private var addressField: some View {
        HStack(spacing: 6) {
            TextField("IP address", text: $config.host)
                .textFieldStyle(.plain)
                .font(Theme.mono(13))
            if !found.isEmpty {
                Menu {
                    ForEach(found) { f in
                        Button("\(f.host) — \(f.title)") { config.host = f.host; config.enabled = true }
                    }
                    Divider()
                    Button("Clear") { config.host = "" }
                } label: { Text("▾").font(Theme.mono(12)) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rule() }
        .frame(maxWidth: .infinity)
    }

    /// HyperDeck or the Understudy recorder.
    private var kindMenu: some View {
        Menu {
            ForEach(DeckKind.allCases) { kind in
                Button(kind.label) { config.kind = kind }
            }
        } label: {
            Text((config.isRecorder ? "RECORDER" : "HYPERDECK") + " ▾")
                .font(Theme.mono(10, bold: true)).tracking(1.2)
                .foregroundStyle(config.isRecorder ? Theme.amber : Theme.grey)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("A HyperDeck on the network, or the Understudy recorder recording on this Mac")
    }

    /// The recorder's source and codec.
    private var recorderFields: some View {
        HStack(spacing: 14) {
            Menu {
                if !sources.capture.isEmpty {
                    Section("Capture devices") {
                        ForEach(sources.capture, id: \.self) { s in Button(s.name) { pick(s) } }
                    }
                }
                Section(sources.searchingNDI ? "NDI (looking…)" : "NDI") {
                    if !sources.ndiAvailable {
                        Text("NDI isn't installed on this Mac")
                    } else if sources.ndi.isEmpty {
                        Text(sources.searchingNDI ? "Looking for sources…" : "No NDI sources found")
                    }
                    ForEach(sources.ndi, id: \.self) { s in Button(s.name) { pick(s) } }
                }
                Section {
                    Button("Test pattern") { pick(.testPattern) }
                }
                Divider()
                Button("Look again") { sources.refresh() }
            } label: {
                Text((config.recorder.source?.label ?? "Choose a source") + " ▾")
                    .font(Theme.mono(13))
                    .foregroundStyle(config.recorder.source == nil ? Theme.grey : Theme.paper)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                ForEach(RecorderCodec.allCases) { c in
                    Button(c.label + (TakeWriter.hasHardwareEncoder(c) ? "" : " (software)")) { config.recorder.codec = c }
                }
            } label: {
                Text(config.recorder.codec.label + " ▾").font(Theme.mono(11)).foregroundStyle(Theme.grey)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("H.264 and H.265 use the Mac's hardware encoder; ProRes uses the ProRes engine where the Mac has one")
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rule() }
        .frame(maxWidth: .infinity)
    }

    private func pick(_ source: RecorderSource) {
        config.recorder.source = source
        config.enabled = true
    }
}

/// HyperDecks found on the network, the interface to look on, and quick assignment.
private struct NetworkList: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var discovery: DeckDiscovery
    @Binding var draft: [DeckConfig]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(index: 2, title: "On the network") {
                HStack(spacing: 18) {
                    InterfacePicker()
                    if unassigned.contains(where: { !$0.busy }), draft.contains(where: { !$0.isAssigned }) {
                        TextButton(title: "Fill empty slots") { fillEmpty() }
                    }
                    TextButton(title: discovery.isScanning ? "Scanning…" : "Find decks") { discovery.scan() }
                        .disabled(discovery.isScanning)
                }
            }
            Text(summary)
                .font(Theme.mono(10)).foregroundStyle(Theme.grey)
                .padding(.top, 8)
            ForEach(discovery.found) { f in
                HStack(alignment: .firstTextBaseline, spacing: Theme.gutter) {
                    Text(f.host).font(Theme.mono(12)).frame(width: 150, alignment: .leading)
                    Text(f.title).font(Theme.grotesk(14, .regular)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(status(f)).font(Theme.mono(10)).tracking(1.2)
                        .foregroundStyle(f.busy && slot(of: f) == nil ? Theme.amber : Theme.grey)
                    Menu {
                        ForEach(draft.indices, id: \.self) { i in
                            Button("\(String(format: "%02d", i + 1))  \(draft[i].name)\(replaces(draft[i]))") {
                                assign(f, to: i)
                            }
                        }
                    } label: {
                        Text(slot(of: f) == nil ? "ASSIGN" : "MOVE").font(Theme.mono(10, bold: true)).tracking(1.2)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) { Rule(color: Theme.rule.opacity(0.6)) }
            }
        }
    }

    private var unassigned: [FoundDeck] { discovery.found.filter { slot(of: $0) == nil } }

    private func slot(of f: FoundDeck) -> Int? {
        draft.firstIndex { $0.networkHost == f.host }
    }

    private func replaces(_ c: DeckConfig) -> String {
        if c.isRecorder, let source = c.recorder.source { return " — replaces the recorder (\(source.label))" }
        return c.host.isEmpty ? "" : " — replaces \(c.host)"
    }

    private func status(_ f: FoundDeck) -> String {
        if let s = slot(of: f) { return "SLOT \(String(format: "%02d", s + 1))" }
        return f.busy ? "BUSY · OTHER CLIENT" : "AVAILABLE"
    }

    private func assign(_ f: FoundDeck, to i: Int) {
        if let old = slot(of: f), old != i { draft[old].host = "" }
        draft[i].host = f.host
        draft[i].kind = .hyperdeck
        draft[i].enabled = true
    }

    private func fillEmpty() {
        // Busy decks belong to another controller (e.g. another department): never auto-assign them.
        for f in unassigned where !f.busy {
            guard let empty = draft.firstIndex(where: { !$0.isAssigned }) else { return }
            assign(f, to: empty)
        }
    }

    private var summary: String {
        if discovery.isScanning { return "LOOKING FOR HYPERDECKS…" }
        guard let last = discovery.lastScanned else {
            return discovery.found.isEmpty ? "FIND DECKS SCANS THE LOCAL NETWORK FOR HYPERDECKS." : ""
        }
        let nets = discovery.scannedNetworks.joined(separator: ", ")
        let none = discovery.found.isEmpty ? " · NONE FOUND. IF MACOS ASKED ABOUT LOCAL NETWORK ACCESS, ALLOW IT AND SCAN AGAIN." : ""
        return "\(nets) · \(last.formatted(date: .omitted, time: .shortened))\(none)".uppercased()
    }
}

/// Which network interface discovery looks on.
private struct InterfacePicker: View {
    @EnvironmentObject private var model: AppModel
    /// Read when the sheet opens, not on every redraw (it queries the system's interfaces).
    @State private var networks: [DeckDiscovery.LocalNetwork] = []

    var body: some View {
        Menu {
            Button("All interfaces") { choose(nil) }
            Divider()
            ForEach(networks) { net in
                Button("\(net.displayName) — \(net.address)  (\(net.cidr))") { choose(net.interface) }
            }
        } label: {
            Text("ON: \(label(networks))".uppercased()).font(Theme.mono(10, bold: true)).tracking(1.2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which network to look for HyperDecks on")
        .onAppear { networks = DeckDiscovery.localNetworks() }
    }

    private func label(_ networks: [DeckDiscovery.LocalNetwork]) -> String {
        guard let chosen = model.settings.discoveryInterface else { return "All interfaces" }
        return networks.first { $0.interface == chosen }?.displayName ?? "\(chosen) (not connected)"
    }

    private func choose(_ interface: String?) {
        model.settings.discoveryInterface = interface
        model.discovery.clear()
        model.discovery.scan()
    }
}
