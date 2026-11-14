import SwiftUI
import UnderstudyCore

/// One deck's settings: media, recording, input and reference, and what Understudy manages.
struct DeckSetupView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var deck: DeckController
    @Environment(\.dismiss) private var dismiss

    @State private var busyKey: String?
    @State private var message: String?
    @State private var messageIsError = false
    @State private var pendingReboot: (key: String, value: String, all: Bool)?

    var body: some View {
        let config = model.settings.decks[deck.id]
        VStack(alignment: .leading, spacing: 0) {
            header(config.name, host: config.host)
                .padding(.bottom, 22)

            if model.setupLocked {
                Text("RECORDING — SETTINGS ARE LOCKED UNTIL STOP")
                    .font(Theme.mono(10, bold: true)).tracking(1.2)
                    .foregroundStyle(Theme.amber)
                    .padding(.bottom, 16)
            }
            if !deck.isConnected {
                Text("This deck isn't connected.")
                    .font(Theme.grotesk(14, .light)).foregroundStyle(Theme.grey)
                    .padding(.bottom, 16)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    media
                    playback
                    group(.recording)
                    group(.input)
                    group(.managed)
                }
                .padding(.trailing, 8)
            }

            if let message {
                Text(message)
                    .font(Theme.mono(10))
                    .foregroundStyle(messageIsError ? Theme.signal : Theme.lock)
                    .padding(.top, 12)
            }
        }
        .padding(28)
        .frame(width: 760, height: 780, alignment: .topLeading)
        .background(Theme.ink)
        .foregroundStyle(Theme.paper)
        .preferredColorScheme(.dark)
        .onAppear { deck.refreshSetup() }
        .alert("Restart the deck?", isPresented: Binding(
            get: { pendingReboot != nil }, set: { if !$0 { pendingReboot = nil } }
        )) {
            Button("Apply and restart", role: .destructive) {
                if let p = pendingReboot { commit(p.key, p.value, all: p.all) }
                pendingReboot = nil
            }
            Button("Cancel", role: .cancel) { pendingReboot = nil }
        } message: {
            Text("Changing this makes the deck\(pendingReboot?.all == true ? "s" : "") restart. Understudy reconnects on its own.")
        }
    }

    // MARK: Header

    private func header(_ name: String, host: String) -> some View {
        HStack(alignment: .top) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(String(format: "%02d", deck.id + 1))
                    .font(Theme.grotesk(44, .light)).tracking(-1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(Theme.grotesk(22, .medium))
                    Text([deck.deviceInfo?.model ?? deck.model, deck.deviceInfo?.softwareVersion.map { "Software \($0)" }, host]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.grotesk(12, .light)).foregroundStyle(Theme.grey)
                }
            }
            Spacer()
            HStack(spacing: 18) {
                TextButton(title: "Identify") { deck.identify() }
                    .help("Flash the deck's front-panel button")
                    .disabled(!deck.isConnected)
                TextButton(title: "Refresh") { deck.refreshSetup() }
                    .disabled(!deck.isConnected)
                TextButton(title: "Done") { dismiss() }
            }
        }
    }

    // MARK: Media

    private var media: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(index: 1, title: "Media")
            if deck.slots.isEmpty {
                Text(deck.isConnected ? "Reading media…" : "—")
                    .font(Theme.grotesk(13, .light)).foregroundStyle(Theme.grey)
                    .padding(.vertical, 10)
            }
            ForEach(deck.slots) { slot in
                HStack(alignment: .center, spacing: Theme.gutter) {
                    Text("SLOT \(slot.slotID)").font(Theme.mono(10)).foregroundStyle(Theme.quiet)
                        .frame(width: 60, alignment: .leading)
                    Text(slot.volumeName ?? slot.name ?? "—")
                        .font(Theme.grotesk(14, .regular))
                        .frame(width: 170, alignment: .leading)
                    Text(slot.status.uppercased()).font(Theme.mono(10)).tracking(1)
                        .foregroundStyle(slot.isMounted ? Theme.paper : (slot.status == "empty" ? Theme.quiet : Theme.amber))
                        .frame(width: 90, alignment: .leading)
                    if let used = slot.usedFraction {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Theme.rule)
                                Rectangle().fill(used > 0.9 ? Theme.amber : Theme.paper).frame(width: geo.size.width * used)
                            }
                        }
                        .frame(height: 4)
                    } else {
                        Spacer()
                    }
                    Text(slot.isMounted ? slot.recordingTimeText.map { "\($0) LEFT" } ?? "" : "")
                        .font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.grey)
                        .frame(width: 130, alignment: .trailing)
                }
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) { Rule(color: Theme.rule.opacity(0.6)) }
            }
        }
    }

    // MARK: Playback

    /// How early this deck is told to play, and folding its measured error into that.
    private var playback: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(index: 2, title: "Playback")
            HStack(alignment: .firstTextBaseline, spacing: Theme.gutter) {
                Text("Play offset").font(Theme.grotesk(14, .regular)).frame(width: 200, alignment: .leading)
                Stepper(value: $model.settings.decks[deck.id].playOffsetFrames, in: -30...30, step: 0.5) {
                    Text(String(format: "%+.1f frames", model.settings.decks[deck.id].playOffsetFrames)).font(Theme.mono(12))
                }
                Spacer()
                Text(deck.smoothedError.map { String(format: "MEASURED Δ %+.1f F", $0) } ?? "MEASURED Δ —")
                    .font(Theme.mono(10)).tracking(1.2).foregroundStyle(Theme.grey)
                TextButton(title: "Calibrate", color: deck.smoothedError == nil ? Theme.quiet : Theme.paper) {
                    model.calibrate(deck.id)
                }
                .disabled(deck.smoothedError == nil)
                .help("Fold the measured error into the play offset (while chasing)")
            }
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rule(color: Theme.rule.opacity(0.6)) }
            Text("Fires play this many frames early to cover the deck's start-up time. Calibrate while the deck is chasing.")
                .font(Theme.grotesk(11, .light)).foregroundStyle(Theme.grey)
                .padding(.top, 4)
        }
    }

    // MARK: Settings

    private func group(_ group: DeckParameter.Group) -> some View {
        let index = DeckParameter.Group.allCases.firstIndex(of: group)! + 3
        let mismatches = model.settingMismatches
        return VStack(alignment: .leading, spacing: 0) {
            SectionHead(index: index, title: group.rawValue)
            ForEach(DeckParameter.all.filter { $0.group == group }) { parameter in
                row(parameter, mismatch: mismatches[parameter.key])
            }
        }
    }

    private func row(_ p: DeckParameter, mismatch: [Int: String]?) -> some View {
        let current = deck.config[p.key]
        let others = (mismatch ?? [:]).filter { $0.key != deck.id && $0.value != current }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.gutter) {
                Text(p.label).font(Theme.grotesk(14, .regular))
                    .frame(width: 200, alignment: .leading)
                if p.isEditable {
                    Menu {
                        ForEach(choices(p, current: current), id: \.self) { value in
                            Button(p.label(for: value)) { request(p, value, all: false) }
                        }
                    } label: {
                        Text(current.map(p.label(for:)) ?? "—").font(Theme.mono(12))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(!canEdit)
                } else {
                    Text(current.map(p.label(for:)) ?? "—")
                        .font(Theme.mono(12))
                        .foregroundStyle(p.group == .managed ? Theme.grey : Theme.paper)
                }
                Spacer()
                if busyKey == p.key {
                    Text("APPLYING…").font(Theme.mono(9)).tracking(1).foregroundStyle(Theme.amber)
                } else if p.isEditable, let current, model.activeDecks.count > 1 {
                    TextButton(title: "All decks", color: canEdit ? Theme.grey : Theme.quiet) { request(p, current, all: true) }
                        .disabled(!canEdit)
                        .help("Set every connected deck to \(p.label(for: current))")
                }
            }
            if !others.isEmpty {
                Text("OTHER DECKS DIFFER: " + others.sorted { $0.key < $1.key }
                    .map { "\(String(format: "%02d", $0.key + 1)) \(p.label(for: $0.value))" }
                    .joined(separator: " · "))
                    .font(Theme.mono(9)).tracking(1).foregroundStyle(Theme.amber)
            }
            if let help = p.help {
                Text(help).font(Theme.grotesk(11, .light)).foregroundStyle(Theme.quiet)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rule(color: Theme.rule.opacity(0.6)) }
    }

    /// Documented values, plus whatever the deck reports if it isn't one of them.
    private func choices(_ p: DeckParameter, current: String?) -> [String] {
        guard let current, !p.values.contains(current) else { return p.values }
        return [current] + p.values
    }

    private var canEdit: Bool { deck.isConnected && !model.setupLocked && busyKey == nil }

    // MARK: Applying

    private func request(_ p: DeckParameter, _ value: String, all: Bool) {
        if p.rebootsDeck, all || deck.config[p.key] != value {
            pendingReboot = (p.key, value, all)
        } else {
            commit(p.key, value, all: all)
        }
    }

    private func commit(_ key: String, _ value: String, all: Bool) {
        guard !model.setupLocked else { return }
        let label = DeckParameter.named(key).map { "\($0.label): \($0.label(for: value))" } ?? "\(key): \(value)"
        busyKey = key
        message = nil
        if all {
            model.applyToAll(key, value) { problems in
                busyKey = nil
                messageIsError = !problems.isEmpty
                message = problems.isEmpty ? "\(label) on every deck." : problems.joined(separator: "  ·  ")
            }
        } else {
            deck.apply(key, value) { problem in
                busyKey = nil
                messageIsError = problem != nil
                message = problem ?? "\(label)."
            }
        }
    }
}
