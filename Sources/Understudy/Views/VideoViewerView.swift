import AVFoundation
import AppKit
import SwiftUI
import UnderstudyCore
import UniformTypeIdentifiers

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
                    .help("Send every file at its own size over NDI (heavier); off scales files over 1080 lines down to 1080, keeping their shape")
                    .disabled(!viewer.ndiEnabled)
                PlaybackLUTMenus(viewer: viewer)
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
                    VideoPane(slot: slot, viewer: viewer)
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
    @ObservedObject var viewer: VideoViewer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(Theme.fill)
                if let problem = viewer.playProblems[slot.deckID] {
                    Text(problem).font(Theme.grotesk(13, .light)).foregroundStyle(Theme.amber)
                        .multilineTextAlignment(.center).padding()
                } else if slot.url != nil {
                    FrameLayerView(viewer: viewer, deckID: slot.deckID)
                } else {
                    Text(slot.status).font(Theme.grotesk(13, .light)).foregroundStyle(Theme.grey)
                        .multilineTextAlignment(.center).padding()
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(alignment: .topLeading) { lutBadge }
            HStack(alignment: .firstTextBaseline) {
                Text(slot.name).font(Theme.grotesk(15, .medium))
                Text(slot.clipName ?? "").font(Theme.mono(10)).foregroundStyle(Theme.grey).lineLimit(1)
                Spacer()
                if slot.url != nil { Text(slot.status).font(Theme.grotesk(11, .light)).foregroundStyle(Theme.quiet) }
            }
            if let problem = viewer.gradeProblems[slot.deckID] {
                Text("Playback LUT not applied: \(problem)")
                    .font(Theme.grotesk(11, .light)).foregroundStyle(Theme.amber)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// "LUT · <name>" while a Playback LUT is on, "LUT MISSING · as recorded" (amber) when it
    /// can't be applied: plain to see on the picture, not only in a tooltip.
    @ViewBuilder private var lutBadge: some View {
        if let lut = viewer.transforms[slot.deckID] {
            let missing = viewer.gradeProblems[slot.deckID] != nil
            Text(missing ? "LUT MISSING · as recorded" : "LUT · \(lut.title)")
                .font(Theme.mono(10, bold: true))
                .foregroundStyle(missing ? Color.black : Theme.paper)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(missing ? Theme.amber : Color.black.opacity(0.6))
                .padding(8)
                .help(viewer.gradeProblems[slot.deckID] ?? PlaybackLUTMenus.scope)
        }
    }
}

/// A deck's picture: the very BGRA frames its NDI feed sends (Playback LUT and all), aspect-fit on
/// black, so what's on screen is exactly what goes out.
struct FrameLayerView: NSViewRepresentable {
    let viewer: VideoViewer
    let deckID: Int

    final class Coordinator {
        var deckID: Int?
        weak var viewer: VideoViewer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        viewer.attachDisplay(layer, deck: deckID)
        context.coordinator.deckID = deckID
        context.coordinator.viewer = viewer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.deckID != deckID, let layer = view.layer as? AVSampleBufferDisplayLayer else { return }
        viewer.detachDisplay(layer)
        viewer.attachDisplay(layer, deck: deckID)
        context.coordinator.deckID = deckID
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        guard let layer = view.layer as? AVSampleBufferDisplayLayer else { return }
        MainActor.assumeIsolated { coordinator.viewer?.detachDisplay(layer) }
    }
}

/// "Playback LUT", then one menu per deck in the viewer: None (as recorded, the default) or a
/// .cube LUT. A playback setting: it changes Understudy's viewer and NDI out only, never the deck,
/// its outputs or its recordings. Saved in the project's playback settings.
struct PlaybackLUTMenus: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var viewer: VideoViewer

    static let scope = "Applies only to Understudy's viewer and NDI out. The deck, its outputs and its recordings are never changed."

    var body: some View {
        HStack(spacing: 12) {
            if !viewer.slots.isEmpty {
                Text("Playback LUT").font(Theme.grotesk(12, .light)).foregroundStyle(Theme.grey)
                    .help(Self.scope)
            }
            ForEach(viewer.slots) { slot in menu(for: slot) }
        }
    }

    private func menu(for slot: VideoViewer.Slot) -> some View {
        let current = model.playbackLUT(deck: slot.deckID)
        let problem = viewer.gradeProblems[slot.deckID]
        return Menu {
            Section("Playback LUT for \(slot.name): viewer and NDI out only") {
                choice(.none, current, deck: slot.deckID)
                let luts = model.projectLUTs
                if let path = current.lutPath, !luts.contains(path) { choice(current, current, deck: slot.deckID) }
                ForEach(luts, id: \.self) { choice(.lut(path: $0), current, deck: slot.deckID) }
                Button("Load LUT…") { loadLUT(deck: slot.deckID, name: slot.name) }
            }
            Divider()
            Text("The deck, its outputs and its recordings are never changed.")
            Text("The LUT sees the file's own values (wide-gamut and HDR files as recorded).")
        } label: {
            HStack(spacing: 4) {
                if problem != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber) }
                Text("\(slot.name) · \(current.title)").lineLimit(1)
            }
            .font(Theme.grotesk(12, .light))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(current == .none ? Theme.grey : Theme.paper)
        .help(problem ?? "Playback LUT for \(slot.name): \(current.title). " + Self.scope)
    }

    private func choice(_ transform: InputTransform, _ current: InputTransform, deck: Int) -> some View {
        Button { model.setPlaybackLUT(transform, deck: deck) } label: {
            if transform == current { Label(transform.title, systemImage: "checkmark") } else { Text(transform.title) }
        }
    }

    private func loadLUT(deck: Int, name: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.message = "Choose a .cube Playback LUT for \(name) (viewer and NDI out only; the deck is never changed)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let problem = model.useLUT(url, deck: deck) {
            let alert = NSAlert()
            alert.messageText = "Couldn't use that Playback LUT"
            alert.informativeText = problem
            alert.runModal()
        }
    }
}
