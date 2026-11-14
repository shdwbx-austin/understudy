import SwiftUI
import UnderstudyCore

/// One deck as a read-only grid column, built to be read from across the room: connection bar
/// and number, one large status word, then health rows. Editing lives in Assign decks and Setup.
struct DeckCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var deck: DeckController
    let config: DeckConfig
    let assign: () -> Void
    @State private var showSetup = false

    private var assigned: Bool { config.enabled && !config.host.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Connection bar: green connected, red lost, amber connecting, grey empty/off.
            Rectangle()
                .fill(connectionColor)
                .frame(height: deck.isConnected || deck.isLost ? 4 : 1)
                .padding(.bottom, 10)
                .animation(.easeInOut(duration: 0.2), value: status.text)

            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%02d", deck.id + 1))
                    .font(Theme.grotesk(44, .light))
                    .tracking(-1)
                    .foregroundStyle(assigned ? connectionColor : Theme.quiet)
                Spacer()
                if deck.isConnected {
                    TextButton(title: "Setup", color: Theme.grey) { showSetup = true }
                        .help("Codec, input, reference, media and play offset for this deck")
                }
            }

            if assigned {
                Text(status.text)
                    .font(Theme.grotesk(24, .medium))
                    .foregroundStyle(status.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 2)
                Text(config.name)
                    .font(Theme.grotesk(16, .regular))
                    .lineLimit(1)
                    .padding(.top, 8)
                Text([config.host, deck.model].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.grey)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 2)
                if let twin = sharedAddress {
                    Text("SAME ADDRESS AS \(String(format: "%02d", twin + 1))")
                        .font(Theme.mono(9, bold: true)).tracking(1.2)
                        .foregroundStyle(Theme.amber)
                        .padding(.top, 4)
                }

                if model.settings.confidenceEnabled {
                    ConfidencePicture(deck: deck, monitor: model.confidence)
                        .padding(.top, 14)
                }

                TimecodeText(text: deck.transport.displayTimecode?.description ?? "--:--:--:--", size: 24)
                    .foregroundStyle(deck.isConnected ? Theme.paper : Theme.quiet)
                    .padding(.top, 14)

                VStack(spacing: 0) {
                    Row(label: "Input", value: inputText, color: inputColor)
                    Row(label: "Reference", value: refText, color: refColor)
                    Row(label: "Media left", value: deck.isConnected ? MediaTime.text(deck.mediaSecondsLeft) : "—", color: mediaColor)
                    if model.mode == .playback {
                        Row(label: "Error Δ", value: errorText, color: errorColor)
                    }
                }
                .padding(.top, 10)

                if let error = deck.lastError {
                    Text(error)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.amber)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                        .onTapGesture { deck.lastError = nil }
                        .help("Click to dismiss")
                }
            } else {
                Text(config.host.isEmpty ? "Not assigned" : "Switched off")
                    .font(Theme.grotesk(16, .light))
                    .foregroundStyle(Theme.grey)
                    .padding(.top, 6)
                if !model.setupLocked {
                    TextButton(title: "Assign", color: Theme.grey, action: assign)
                        .padding(.top, 8)
                }
            }
        }
        .sheet(isPresented: $showSetup) {
            DeckSetupView(deck: deck).environmentObject(model)
        }
    }

    // MARK: Status

    /// The one word that matters most right now.
    private var status: (text: String, color: Color) {
        if deck.isLost { return ("LOST", Theme.signal) }
        guard deck.isConnected else {
            switch deck.connection {
            case .connecting, .failed: return ("CONNECTING", Theme.amber)
            default: return ("OFFLINE", Theme.quiet)
            }
        }
        if deck.transport.status == .record { return ("● REC", Theme.signal) }
        if model.mode == .playback {
            switch deck.chase.phase {
            case .playing: return ("CHASING", Theme.lock)
            case .cueing, .armed: return ("CUEING", Theme.paper)
            case .outOfRange: return ("NO MEDIA AT TC", Theme.amber)
            case .idle: return (model.ltcRolling ? "WAITING" : "WAITING FOR LTC", Theme.grey)
            }
        }
        switch deck.transport.status {
        case .preview: return ("LIVE", Theme.paper)
        case .play: return ("PLAYING", Theme.paper)
        case .stopped: return ("STOPPED", Theme.grey)
        case .unknown: return ("—", Theme.quiet)
        default: return (deck.transport.status.rawValue.uppercased(), Theme.paper)
        }
    }

    /// Another slot with the same address (two slots driving one deck).
    private var sharedAddress: Int? {
        let host = config.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        return model.settings.decks.firstIndex { $0.id != deck.id && $0.enabled && $0.host.trimmingCharacters(in: .whitespaces) == host }
    }

    // MARK: Text and colour

    /// Green connected, red lost after having connected, amber while connecting, grey otherwise.
    private var connectionColor: Color {
        if deck.isConnected { return Theme.lock }
        if deck.isLost { return Theme.signal }
        switch deck.connection {
        case .connecting, .failed: return Theme.amber
        default: return Theme.quiet
        }
    }

    /// What's arriving at the deck's input: its format, or NO SIGNAL. Format shown only if different.
    private var inputText: String {
        guard deck.isConnected, deck.transport.reportsInput else { return "—" }
        guard let input = deck.transport.inputVideoFormat else { return "NO SIGNAL" }
        if let format = deck.transport.videoFormat, format != input { return "\(input) → \(format)" }
        return input
    }

    private var inputColor: Color {
        guard deck.isConnected else { return Theme.quiet }
        return inputText == "NO SIGNAL" ? Theme.signal : Theme.paper
    }

    private var refText: String {
        guard deck.isConnected else { return "—" }
        switch deck.transport.referenceLocked {
        case true?: return "LOCKED"
        case false?: return "NOT LOCKED"
        case nil: return "—"
        }
    }

    private var refColor: Color {
        guard deck.isConnected else { return Theme.quiet }
        return deck.transport.referenceLocked == false ? Theme.signal : Theme.paper
    }

    private var mediaColor: Color {
        guard deck.isConnected else { return Theme.quiet }
        switch MediaTime.level(deck.mediaSecondsLeft) {
        case .ok: return Theme.paper
        case .low: return Theme.amber
        case .critical, .none: return Theme.signal
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
                .font(Theme.mono(12))
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
