import SwiftUI
import Cam4ProgCore

struct DeckCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var deck: DeckController
    @Binding var config: DeckConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StatusDot(color: connectionColor)
                TextField("Name", text: $config.name)
                    .textFieldStyle(.plain)
                    .font(Theme.display(18, weight: .semibold))
                    .frame(maxWidth: 120)
                Spacer()
                StatusPill(text: deck.transport.status.rawValue.uppercased(), color: statusColor)
                Toggle("", isOn: $config.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: config.enabled) { _ in model.applyHost(deck.id) }
            }

            HStack(spacing: 8) {
                TextField("HyperDeck IP", text: $config.host)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12))
                    .onSubmit { model.applyHost(deck.id) }
                Button("Connect") { model.applyHost(deck.id) }
                    .font(Theme.mono(11))
            }
            Text(connectionText)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)

            Rule()

            HStack(alignment: .firstTextBaseline) {
                Text(deck.transport.displayTimecode?.description ?? "--:--:--:--")
                    .font(Theme.mono(24, bold: true))
                    .monospacedDigit()
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(deck.transport.videoFormat ?? deck.transport.inputVideoFormat ?? "—")
                    Text(deck.transport.referenceLocked == true ? "REF LOCKED" : "REF —")
                        .foregroundStyle(deck.transport.referenceLocked == true ? Theme.live : Theme.caution)
                }
                .font(Theme.mono(10))
            }

            if model.mode == .playback {
                HStack {
                    Text(deck.chase.phase.label)
                        .font(Theme.mono(11, bold: true))
                        .foregroundStyle(phaseColor)
                    Spacer()
                    Text(errorText)
                        .font(Theme.mono(11))
                        .foregroundStyle(errorColor)
                }
                HStack(spacing: 8) {
                    Text("PLAY OFFSET").font(Theme.mono(10)).foregroundStyle(Theme.dim)
                    Stepper(value: $config.playOffsetFrames, in: -30...30, step: 0.5) {
                        Text(String(format: "%+.1f f", config.playOffsetFrames)).font(Theme.mono(11))
                    }
                    Spacer()
                    Button("Calibrate") { model.calibrate(deck.id) }
                        .font(Theme.mono(11))
                        .disabled(deck.smoothedError == nil)
                        .help("Fold the measured drift into the play offset")
                }
            }

            if let error = deck.lastError {
                Text(error)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.caution)
                    .lineLimit(2)
                    .onTapGesture { deck.lastError = nil }
            }
        }
        .padding(14)
        .background(Theme.panel)
        .overlay(Rectangle().stroke(deck.transport.status == .record ? Theme.record : Theme.rule, lineWidth: 1))
        .opacity(config.enabled ? 1 : 0.45)
    }

    private var connectionText: String {
        switch deck.connection {
        case .disconnected: return config.host.isEmpty ? "Enter an IP and press return" : "Disconnected"
        case .connecting: return "Connecting to \(config.host):9993…"
        case .connected: return deck.model ?? "Connected"
        case .failed(let reason): return "Retrying · \(reason)"
        }
    }

    private var connectionColor: Color {
        switch deck.connection {
        case .connected: return Theme.live
        case .connecting: return Theme.caution
        case .failed: return Theme.record
        case .disconnected: return Theme.dim
        }
    }

    private var statusColor: Color {
        switch deck.transport.status {
        case .record: return Theme.record
        case .play: return Theme.live
        case .preview: return Theme.paper
        default: return Theme.dim
        }
    }

    private var phaseColor: Color {
        switch deck.chase.phase {
        case .playing: return Theme.live
        case .cueing, .armed: return Theme.caution
        case .outOfRange: return Theme.record
        case .idle: return Theme.dim
        }
    }

    private var errorText: String {
        guard let error = deck.smoothedError else { return "Δ —" }
        return String(format: "Δ %+.1f f", error)
    }

    private var errorColor: Color {
        guard let error = deck.smoothedError else { return Theme.dim }
        return abs(error) <= model.settings.chase.toleranceFrames ? Theme.live : Theme.caution
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(Theme.mono(10, bold: true))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .overlay(Rectangle().stroke(color, lineWidth: 1))
    }
}
