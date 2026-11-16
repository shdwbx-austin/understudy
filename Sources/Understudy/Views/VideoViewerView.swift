import AVFoundation
import AppKit
import SwiftUI

/// The selected take's recordings, locked to the timeline: one deck large, or up to three side by
/// side, each also sent out as its own NDI stream when NDI is on.
struct VideoViewerView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var viewer: VideoViewer

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                Text("Video").font(Theme.grotesk(24, .medium))
                Text(takeLabel).font(Theme.grotesk(14, .light)).foregroundStyle(Theme.grey).lineLimit(1)
                Spacer()
                DeckPicker(viewer: viewer)
            }
            if model.mode != .timeline {
                Text("Plays while the decks follow Program (⌘1), locked to the timeline's timecode.")
                    .font(Theme.grotesk(13, .light)).foregroundStyle(Theme.amber)
            }
            panes
            HStack(spacing: 18) {
                Toggle("NDI out", isOn: $viewer.ndiEnabled).toggleStyle(.switch).controlSize(.small).tint(Theme.lock)
                Toggle("Full size", isOn: $viewer.ndiFullSize).toggleStyle(.checkbox).controlSize(.small)
                    .help("Send the files' own size over NDI (heavier); off sends 1080p")
                    .disabled(!viewer.ndiEnabled)
                Text(viewer.ndiStatus).font(Theme.grotesk(12, .light)).foregroundStyle(Theme.grey).lineLimit(1)
                Spacer()
                Button { model.loadViewerTake() } label: {
                    Text("Reload take").font(Theme.grotesk(13, .light)).foregroundStyle(Theme.grey)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 420)
        .background(Theme.ink)
        .foregroundStyle(Theme.paper)
        .preferredColorScheme(.dark)
        .onAppear { model.viewerAppeared() }
        .onDisappear { model.viewerDisappeared() }
    }

    private var takeLabel: String {
        guard let take = model.takes.first(where: { $0.offset == model.selectedTake }) else { return "No take selected" }
        return "Take #\(take.clipID) · \(take.name)"
    }

    @ViewBuilder private var panes: some View {
        let shown = viewer.slots.filter { viewer.solo == nil || $0.deckID == viewer.solo }
        if shown.isEmpty {
            Text("No decks with takes yet. Record a take, back it up (⌘B), and it plays here.")
                .font(Theme.grotesk(14, .light)).foregroundStyle(Theme.grey)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 12) {
                ForEach(shown) { slot in
                    VideoPane(slot: slot, player: viewer.players[slot.deckID])
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// ME 1 · ME 2 · AUX 1 · All, as light words (the current one underlined), like the mode tabs.
private struct DeckPicker: View {
    @ObservedObject var viewer: VideoViewer

    var body: some View {
        HStack(spacing: 20) {
            ForEach(viewer.slots) { slot in tab(slot.name, viewer.solo == slot.deckID) { viewer.solo = slot.deckID } }
            if viewer.slots.count > 1 { tab("All", viewer.solo == nil) { viewer.solo = nil } }
        }
    }

    private func tab(_ title: String, _ active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Theme.grotesk(16, active ? .regular : .light)).foregroundStyle(active ? Theme.paper : Theme.grey)
                Rectangle().fill(active ? Theme.paper : Color.clear).frame(height: 2)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct VideoPane: View {
    let slot: VideoViewer.Slot
    let player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(Theme.fill)
                if let player, slot.url != nil {
                    PlayerLayerView(player: player)
                } else {
                    Text(slot.status).font(Theme.grotesk(13, .light)).foregroundStyle(Theme.grey)
                        .multilineTextAlignment(.center).padding()
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            HStack(alignment: .firstTextBaseline) {
                Text(slot.name).font(Theme.grotesk(15, .medium))
                Text(slot.clipName ?? "").font(Theme.mono(10)).foregroundStyle(Theme.grey).lineLimit(1)
                Spacer()
                if slot.url != nil { Text(slot.status).font(Theme.grotesk(11, .light)).foregroundStyle(Theme.quiet) }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// An AVPlayerLayer, aspect-fit, on black.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}
