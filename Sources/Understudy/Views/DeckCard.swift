import SwiftUI
import UnderstudyCore

/// One deck as a grid column: index, name, address, then a label/value table.
struct DeckCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var deck: DeckController
    @ObservedObject var discovery: DeckDiscovery
    @Binding var config: DeckConfig
    @State private var showSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Index and status
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%02d", deck.id + 1))
                    .font(Theme.grotesk(44, .light))
                    .tracking(-1)
                    .foregroundStyle(deck.transport.status == .record ? Theme.signal : Theme.paper)
                Spacer()
                HStack(spacing: 6) {
                    StatusDot(color: connectionColor, filled: deck.isConnected)
                    Text(connectionWord)
                        .font(Theme.mono(9))
                        .tracking(1.2)
                        .foregroundStyle(connectionColor)
                }
                Toggle("", isOn: $config.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: config.enabled) { _ in model.applyHost(deck.id) }
            }

            TextField("Name", text: $config.name)
                .textFieldStyle(.plain)
                .font(Theme.grotesk(20, .medium))
                .padding(.top, 2)

            // Address
            HStack(spacing: 6) {
                TextField("IP address", text: $config.host)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .onSubmit { model.applyHost(deck.id) }
                if !discovery.found.isEmpty {
                    Menu {
                        ForEach(discovery.found) { found in
                            Button("\(found.host) — \(found.title)") { model.assign(found, to: deck.id) }
                        }
                    } label: {
                        Text("▾").font(Theme.mono(11))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Pick a HyperDeck found on the network")
                }
            }
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) { Rule() }
            .padding(.top, 8)

            HStack(alignment: .firstTextBaseline) {
                Text(deck.model ?? connectionDetail)
                    .font(Theme.grotesk(12, .light))
                    .foregroundStyle(Theme.grey)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if deck.isConnected {
                    TextButton(title: "Setup", color: Theme.grey) { showSetup = true }
                        .help("Codec, input, reference and media for this deck")
                }
            }
            .padding(.top, 6)

            if model.settings.confidenceEnabled {
                ConfidencePicture(deck: deck, monitor: model.confidence)
                    .padding(.top, 14)
            }

            // Readouts
            TimecodeText(text: deck.transport.displayTimecode?.description ?? "--:--:--:--", size: 26)
                .foregroundStyle(deck.isConnected ? Theme.paper : Theme.quiet)
                .padding(.top, 18)

            VStack(spacing: 0) {
                Row(label: "Transport", value: deck.transport.status.rawValue.uppercased(), color: statusColor)
                Row(label: "Input", value: inputText, color: inputColor)
                Row(label: "Format", value: deck.transport.videoFormat ?? "—")
                Row(label: "Reference", value: refText, color: refColor)
                if deck.isLoggingTake {
                    Row(label: "Show code",
                        value: model.ltcRolling ? loggedText : "WAITING FOR LTC",
                        color: model.ltcRolling ? Theme.paper : Theme.amber)
                }
                if model.mode == .playback {
                    Row(label: "Chase", value: deck.chase.phase.label, color: phaseColor)
                    Row(label: "Error Δ", value: errorText, color: errorColor)
                    HStack {
                        Label8(text: "Play offset")
                        Spacer()
                        Stepper(value: $config.playOffsetFrames, in: -30...30, step: 0.5) {
                            Text(String(format: "%+.1f f", config.playOffsetFrames)).font(Theme.mono(11))
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Rule(color: Theme.rule.opacity(0.6)) }
                    HStack {
                        Spacer()
                        TextButton(title: "Calibrate", color: deck.smoothedError == nil ? Theme.quiet : Theme.paper) {
                            model.calibrate(deck.id)
                        }
                        .disabled(deck.smoothedError == nil)
                        .help("Fold the measured error into the play offset")
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.top, 10)

            if let error = deck.lastError {
                Text(error)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.amber)
                    .lineLimit(3)
                    .padding(.top, 10)
                    .onTapGesture { deck.lastError = nil }
                    .help("Click to dismiss")
            }
        }
        .opacity(config.enabled ? 1 : 0.4)
        .sheet(isPresented: $showSetup) {
            DeckSetupView(deck: deck).environmentObject(model)
        }
    }

    /// What's arriving at the deck's input: its format, or NO SIGNAL.
    private var inputText: String {
        guard deck.isConnected else { return "—" }
        guard deck.transport.reportsInput else { return "—" }
        guard let input = deck.transport.inputVideoFormat else { return "NO SIGNAL" }
        return input
    }

    private var inputColor: Color {
        inputText == "NO SIGNAL" ? Theme.signal : Theme.paper
    }

    // MARK: Text and colour

    private var connectionWord: String {
        switch deck.connection {
        case .connected: return "ONLINE"
        case .connecting: return "CONNECTING"
        case .failed: return "RETRYING"
        case .disconnected: return config.host.isEmpty ? "EMPTY" : "OFFLINE"
        }
    }

    private var connectionDetail: String {
        switch deck.connection {
        case .disconnected: return config.host.isEmpty ? "Enter an address or pick one found below." : "Not connected."
        case .connecting: return "Connecting to \(config.host):9993…"
        case .connected: return "Connected"
        case .failed(let reason): return reason
        }
    }

    private var connectionColor: Color {
        switch deck.connection {
        case .connected: return Theme.paper
        case .connecting: return Theme.amber
        case .failed: return Theme.signal
        case .disconnected: return Theme.quiet
        }
    }

    private var statusColor: Color {
        switch deck.transport.status {
        case .record: return Theme.signal
        case .unknown: return Theme.quiet
        default: return Theme.paper
        }
    }

    private var refText: String {
        switch deck.transport.referenceLocked {
        case true?: return "LOCKED"
        case false?: return "NOT LOCKED"
        case nil: return "—"
        }
    }

    private var refColor: Color {
        deck.transport.referenceLocked == false ? Theme.signal : Theme.paper
    }

    private var loggedText: String {
        guard let s = deck.loggedSeconds else { return "LOGGING" }
        return String(format: "LOGGING · %.0f S", s)
    }

    private var phaseColor: Color {
        switch deck.chase.phase {
        case .playing: return Theme.paper
        case .cueing, .armed: return Theme.amber
        case .outOfRange: return Theme.signal
        case .idle: return Theme.grey
        }
    }

    private var errorText: String {
        guard let error = deck.smoothedError else { return "—" }
        return String(format: "%+.1f F", error)
    }

    private var errorColor: Color {
        guard let error = deck.smoothedError else { return Theme.grey }
        return abs(error) <= model.settings.chase.toleranceFrames ? Theme.paper : Theme.amber
    }
}

/// A label/value line in a deck column.
private struct Row: View {
    let label: String
    let value: String
    var color: Color = Theme.paper

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label8(text: label)
            Spacer(minLength: 8)
            Text(value)
                .font(Theme.mono(11))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rule(color: Theme.rule.opacity(0.6)) }
    }
}

/// The deck's picture from the confidence monitor, with a badge when something's wrong.
private struct ConfidencePicture: View {
    @ObservedObject var deck: DeckController
    @ObservedObject var monitor: ConfidenceMonitor

    var body: some View {
        let feed = monitor.feeds[deck.id]
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Theme.fill)
            if let image = feed?.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            if let badge = badge(feed?.state) {
                Text(badge.text)
                    .font(Theme.mono(9, bold: true))
                    .tracking(1.2)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(badge.color)
                    .padding(6)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipped()
        .overlay(Rectangle().stroke(borderColor(feed?.state), lineWidth: 1))
        .help(monitor.deviceName.map { "From \($0)" } ?? "Confidence monitor")
    }

    private func badge(_ state: PictureState?) -> (text: String, color: Color)? {
        guard monitor.isRunning else { return ("MONITOR OFF", Theme.quiet) }
        switch state {
        case nil, .noFeed?: return ("NO FEED", Theme.signal)
        case .black?: return ("BLACK", Theme.signal)
        // A still picture only matters when the deck should be moving.
        case .still?: return deck.transport.status == .play ? ("STILL", Theme.amber) : nil
        case .picture?: return nil
        }
    }

    private func borderColor(_ state: PictureState?) -> Color {
        guard let b = badge(state) else { return Theme.rule }
        return b.color
    }
}
