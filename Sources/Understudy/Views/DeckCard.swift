import SwiftUI
import UnderstudyCore

/// One deck as a full-width row, after Calendario: health dots and the status word on the left,
/// a compact data table in the middle, the deck number huge on the right. A lost deck inverts to
/// a solid red row so it can't be missed. Editing lives in Assign decks and Setup.
struct DeckCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var deck: DeckController
    let config: DeckConfig
    let assign: () -> Void
    @State private var showSetup = false

    private var assigned: Bool { config.enabled && config.isAssigned }
    /// The inverted state: everything on the row is drawn in ink on red.
    private var inverted: Bool { deck.isLost }
    private var ink: Color { inverted ? Theme.ink : Theme.paper }
    private var soft: Color { inverted ? Theme.ink.opacity(0.7) : Theme.grey }

    var body: some View {
        ColumnGrid {
            identity
            middle
            table
            number
        }
        .padding(.vertical, 10)
        .padding(.horizontal, inverted ? 12 : 0)
        .frame(minHeight: 104)
        .background(inverted ? Theme.signal : .clear)
        .animation(.easeInOut(duration: 0.2), value: inverted)
        .sheet(isPresented: $showSetup) {
            DeckSetupView(deck: deck).environmentObject(model)
        }
    }

    // MARK: Columns

    /// Column 1: connection bar, health dots, status word, name and address.
    private var identity: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(inverted ? Theme.ink : connectionColor)
                .frame(width: assigned ? 4 : 1)
            VStack(alignment: .leading, spacing: 0) {
                if assigned {
                    HStack(spacing: 6) {
                        ForEach(Array(dots.enumerated()), id: \.offset) { _, dot in
                            Circle().fill(inverted ? Theme.ink : dot.color).frame(width: 7, height: 7).help(dot.help)
                        }
                    }
                    Text(status.text)
                        .font(Theme.grotesk(22, .medium))
                        .foregroundStyle(inverted ? Theme.ink : status.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.top, 6)
                    Spacer(minLength: 8)
                    Text(config.name).font(Theme.grotesk(16, .regular)).foregroundStyle(ink).lineLimit(1)
                    Text(subtitle)
                        .font(Theme.mono(10)).foregroundStyle(soft).lineLimit(1)
                        .help(deck.isRecorder ? "" : "Control via \(deck.route.summary)")
                    if let twin = sharedAddress {
                        Text("SAME ADDRESS AS \(String(format: "%02d", twin + 1))")
                            .font(Theme.mono(9, bold: true)).tracking(1.2).foregroundStyle(inverted ? Theme.ink : Theme.amber)
                            .padding(.top, 3)
                    }
                } else {
                    Text(!config.isAssigned ? "Not assigned" : "Switched off")
                        .font(Theme.grotesk(18, .light)).foregroundStyle(Theme.grey)
                    Spacer(minLength: 8)
                    if !model.setupLocked {
                        TextButton(title: "Assign", color: Theme.grey, action: assign)
                    }
                }
            }
        }
    }

    /// Column 2: the confidence picture when it's on, otherwise the deck's own timecode.
    @ViewBuilder private var middle: some View {
        if assigned, model.settings.confidenceEnabled {
            ConfidencePicture(deck: deck, monitor: model.confidence)
        } else if assigned {
            VStack(alignment: .leading, spacing: 4) {
                Text("DECK TIMECODE").font(Theme.mono(10)).tracking(1.2).foregroundStyle(soft)
                TimecodeText(text: deck.transport.displayTimecode?.description ?? "--:--:--:--", size: 26)
                    .foregroundStyle(deck.isConnected ? ink : (inverted ? Theme.ink.opacity(0.6) : Theme.quiet))
            }
        } else {
            Color.clear
        }
    }

    /// Column 3: a compact table on hairlines, after the UTS poster.
    @ViewBuilder private var table: some View {
        if assigned {
            VStack(spacing: 0) {
                if model.settings.confidenceEnabled {
                    MetaRow(label: "Timecode", value: deck.transport.displayTimecode?.description ?? "—", color: ink, inverted: inverted)
                }
                MetaRow(label: "Input", value: inputText, color: inputColor, inverted: inverted)
                if let health = recorderHealth {
                    MetaRow(label: "Data rate", value: health.recording ? RecorderHealth.rateText(health.bytesPerSecond) : "—",
                            color: ink, inverted: inverted)
                    MetaRow(label: "Dropped", value: health.recording || health.droppedFrames > 0 ? "\(health.droppedFrames)" : "—",
                            color: health.droppedFrames > 0 ? Theme.signal : ink, inverted: inverted)
                    MetaRow(label: "Disk left", value: deck.isConnected ? MediaTime.text(deck.mediaSecondsLeft) : "—",
                            color: mediaColor, inverted: inverted)
                } else {
                    MetaRow(label: "Reference", value: refText, color: refColor, inverted: inverted)
                    MetaRow(label: "Media left", value: deck.isConnected ? MediaTime.text(deck.mediaSecondsLeft) : "—",
                            color: mediaColor, inverted: inverted)
                }
                if model.isPlayingBack {
                    MetaRow(label: "Error Δ", value: errorText, color: errorColor, inverted: inverted)
                }
            }
            if let health = recorderHealth {
                ForEach(Array(health.warnings.enumerated()), id: \.offset) { _, w in
                    Text(w.text)
                        .font(Theme.mono(9, bold: true)).tracking(1.2)
                        .foregroundStyle(inverted ? Theme.ink : warningColor(w.level))
                        .padding(.top, 4)
                }
            }
            if let error = deck.lastError {
                Text(error)
                    .font(Theme.mono(10)).foregroundStyle(inverted ? Theme.ink : Theme.amber)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .onTapGesture { deck.lastError = nil }
                    .help("Click to dismiss")
            }
        } else {
            Color.clear
        }
    }

    /// Column 4: the deck number, huge and set right; Setup above it.
    private var number: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if deck.isConnected, !config.isRecorder {
                TextButton(title: "Setup", color: soft) { showSetup = true }
                    .help("Codec, input, reference, media and play offset for this deck")
            }
            Spacer(minLength: 0)
            Text(String(format: "%02d", deck.id + 1))
                .font(Theme.grotesk(80, .light))
                .tracking(-3)
                .foregroundStyle(inverted ? Theme.ink : (assigned ? connectionColor : Theme.quiet))
                .padding(.bottom, -15)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: Status

    /// The one word that matters most right now.
    private var status: (text: String, color: Color) { DeckStatus.word(deck, model: model) }

    /// Health at a glance: connection, input signal, reference, media.
    private var dots: [(color: Color, help: String)] {
        guard deck.isConnected else { return [(connectionColor, "Not connected (via \(deck.route.summary))")] }
        let input: Color = !deck.transport.reportsInput ? Theme.quiet : (deck.transport.inputVideoFormat == nil ? Theme.signal : Theme.lock)
        let ref: Color = deck.transport.referenceLocked == nil ? Theme.quiet : (deck.transport.referenceLocked == true ? Theme.lock : Theme.signal)
        let media: Color = {
            switch MediaTime.level(deck.mediaSecondsLeft) {
            case .ok: return deck.mediaSecondsLeft == nil ? Theme.quiet : Theme.lock
            case .low: return Theme.amber
            case .critical, .none: return Theme.signal
            }
        }()
        return [(Theme.lock, "Connected via \(deck.route.summary)"), (input, "Input signal"), (ref, "Reference"), (media, "Media left")]
    }

    /// Another slot with the same address (two slots driving one deck).
    private var sharedAddress: Int? {
        guard let host = config.networkHost else { return nil }
        return model.settings.decks.firstIndex { $0.id != deck.id && $0.enabled && $0.networkHost == host }
    }

    /// Address and model for a HyperDeck; source and codec for the recorder.
    private var subtitle: String {
        if config.isRecorder {
            return ["Recorder", config.recorder.source?.label, config.recorder.codec.label].compactMap { $0 }.joined(separator: " · ")
        }
        return [config.host, deck.model].compactMap { $0 }.joined(separator: " · ")
    }

    /// The recorder's health while it's connected (nil for a HyperDeck).
    private var recorderHealth: RecorderHealth? {
        guard config.isRecorder, deck.isConnected else { return nil }
        return deck.recorderStatus?.health
    }

    private func warningColor(_ level: RecorderWarning.Level) -> Color {
        switch level {
        case .alarm: return Theme.signal
        case .caution: return Theme.amber
        case .note: return Theme.grey
        }
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

/// A label/value line in a deck row's table.
private struct MetaRow: View {
    let label: String
    let value: String
    var color: Color = Theme.paper
    var inverted = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label.uppercased())
                .font(Theme.mono(10)).tracking(1.2)
                .foregroundStyle(inverted ? Theme.ink.opacity(0.7) : Theme.grey)
            Spacer(minLength: 8)
            Text(value)
                .font(Theme.mono(12))
                .foregroundStyle(inverted ? Theme.ink : color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(inverted ? Theme.ink.opacity(0.35) : Theme.rule.opacity(0.6)).frame(height: 1) }
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

/// A deck's state in one word, shared by the deck rows and the timeline's deck chips.
@MainActor
enum DeckStatus {
    static func word(_ deck: DeckController, model: AppModel) -> (text: String, color: Color) {
        if deck.isLost { return ("Lost", Theme.signal) }
        guard deck.isConnected else {
            switch deck.connection {
            case .connecting, .failed: return ("Connecting", Theme.amber)
            default: return ("Offline", Theme.quiet)
            }
        }
        if deck.transport.status == .record { return ("● Rec", Theme.signal) }
        if model.isPlayingBack {
            switch deck.chase.phase {
            case .playing: return ("Chasing", Theme.lock)
            case .cueing, .armed, .starting: return ("Cueing", Theme.paper)
            case .outOfRange: return ("No media at TC", Theme.amber)
            case .idle:
                if model.mode == .timeline { return (model.ltcRolling ? "Waiting" : "Parked", Theme.grey) }
                return (model.ltcRolling ? "Waiting" : "Waiting for LTC", Theme.grey)
            }
        }
        switch deck.transport.status {
        case .preview: return ("Live", Theme.paper)
        case .play: return ("Playing", Theme.paper)
        case .stopped: return ("Stopped", Theme.grey)
        case .unknown: return ("—", Theme.quiet)
        default: return (deck.transport.status.rawValue.capitalized, Theme.paper)
        }
    }
}
