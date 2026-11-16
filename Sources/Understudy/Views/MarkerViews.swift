import AppKit
import SwiftUI
import UnderstudyCore

extension MarkerKind {
    /// One colour per type, after CuePoints' cue colours, toned for the black UI.
    var color: Color {
        switch self {
        case .choreo: return Color(red: 0.95, green: 0.45, blue: 0.33)
        case .audio: return Color(red: 0.33, green: 0.68, blue: 0.92)
        case .video: return Color(red: 0.58, green: 0.45, blue: 0.95)
        case .notes: return Color(red: 0.40, green: 0.56, blue: 0.98)
        case .lighting: return Color(red: 0.95, green: 0.30, blue: 0.36)
        case .pyro: return Color(red: 0.36, green: 0.80, blue: 0.45)
        case .automation: return Color(red: 0.86, green: 0.40, blue: 0.86)
        }
    }
}

// MARK: - Bar

/// One chip per marker type: click (or press its number) to drop one at the playhead; right-click
/// to hide or show that type. M drops the last type again. The Markers menu exports and sends.
struct MarkerBar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var timeline: TimelineModel

    var body: some View {
        HStack(spacing: 8) {
            Text("MARKERS").font(Theme.mono(9)).tracking(1.2).foregroundStyle(Theme.grey)
            ForEach(MarkerKind.allCases, id: \.self) { kind in
                let hidden = timeline.hiddenMarkerKinds.contains(kind)
                Button { timeline.addMarker(kind) } label: {
                    HStack(spacing: 5) {
                        Text("\(kind.number)").font(Theme.mono(9, bold: true))
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(kind.color.opacity(hidden ? 0.3 : 1)))
                            .foregroundStyle(Theme.ink)
                        Text(kind.title).font(Theme.grotesk(12, .medium))
                            .foregroundStyle(hidden ? Theme.quiet : kind.color)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(kind.color.opacity(hidden ? 0.05 : 0.14)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(kind.number)")), modifiers: [])
                .help("Add a \(kind.title) marker at the playhead (\(kind.number)). Right-click to hide or show \(kind.title) markers.")
                .contextMenu {
                    Button(hidden ? "Show \(kind.title) Markers" : "Hide \(kind.title) Markers") {
                        if hidden { timeline.hiddenMarkerKinds.remove(kind) } else { timeline.hiddenMarkerKinds.insert(kind) }
                    }
                }
            }
            // M: another marker of the last type.
            Button("") { timeline.addMarker() }.keyboardShortcut("m", modifiers: []).opacity(0).frame(width: 0)
            Spacer()
            if model.linkBusy { ProgressView().controlSize(.small) }
            MarkerMenu(timeline: timeline)
        }
    }
}

/// Export and send: CSV, grandMA3 (plugin file or straight over OSC), disguise (over the network).
struct MarkerMenu: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var timeline: TimelineModel

    var body: some View {
        Menu {
            Button("Send to grandMA3") { model.deployMarkersToMA3() }
                .disabled(model.settings.ma3Host.isEmpty || timeline.markers.isEmpty)
            Button("Send to disguise") { model.pushMarkersToD3() }
                .disabled(model.settings.d3Host.isEmpty || timeline.markers.isEmpty)
            Divider()
            Button("Export CSV…") { model.exportMarkersCSV() }.disabled(timeline.markers.isEmpty)
            Button("Export grandMA3 Plugin…") { model.exportMA3Plugin() }.disabled(timeline.markers.isEmpty)
            Divider()
            Button("Next Marker") { timeline.nextMarker() }.keyboardShortcut("]", modifiers: [])
            Button("Previous Marker") { timeline.previousMarker() }.keyboardShortcut("[", modifiers: [])
            Divider()
            Button("Show All Types") { timeline.hiddenMarkerKinds = [] }.disabled(timeline.hiddenMarkerKinds.isEmpty)
            Button("Show Control Settings…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        } label: {
            Text("SEND / EXPORT").font(Theme.mono(10, bold: true)).tracking(1.2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Send markers to grandMA3 or disguise, or export them")
    }
}

// MARK: - On the tracks

/// Markers over the current song: a line, a handle to drag, and the label. Click to go there.
struct MarkerOverlay: View {
    @ObservedObject var timeline: TimelineModel
    /// Timeline time at x = 0, and points per second.
    let from: Double
    let scale: Double
    let width: CGFloat
    let height: CGFloat
    @State private var dragging: (id: UUID, dx: CGFloat)?

    /// Label lanes: a label drops to the next lane up when it would run into the one before.
    private func lanes(_ items: [(marker: Marker, time: Double)]) -> [UUID: Int] {
        var ends: [CGFloat] = []
        var out: [UUID: Int] = [:]
        for item in items {
            let x = CGFloat((item.time - from) * scale) + 6
            let w = CGFloat(item.marker.displayName.count) * 6.6 + 10
            let lane = ends.firstIndex { $0 <= x } ?? ends.count
            if lane == ends.count { ends.append(x + w) } else { ends[lane] = x + w }
            out[item.marker.id] = min(lane, 2)
        }
        return out
    }

    var body: some View {
        let items = timeline.placedMarkers
        let lane = lanes(items)
        ZStack(alignment: .topLeading) {
            ForEach(items, id: \.marker.id) { item in
                let m = item.marker
                let dx = dragging?.id == m.id ? dragging!.dx : 0
                let x = CGFloat((item.time - from) * scale) + dx
                if x >= -2, x <= width + 2 {
                    let selected = timeline.selectedMarkerID == m.id
                    Rectangle().fill(m.kind.color.opacity(selected ? 1 : 0.8))
                        .frame(width: selected ? 2 : 1, height: height - 22)
                        .offset(x: x - (selected ? 1 : 0.5), y: 22)
                        .allowsHitTesting(false)
                    Text(m.displayName)
                        .font(Theme.grotesk(11, .medium))
                        .foregroundStyle(m.kind.color)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 3)
                        .background(Theme.ink.opacity(0.7))
                        .offset(x: x + 6, y: height - 18 - CGFloat(lane[m.id] ?? 0) * 17)
                        .allowsHitTesting(false)
                    // Handle: drag to move (snaps to frames), click to go, right-click for more.
                    Circle().fill(m.kind.color)
                        .overlay(Circle().strokeBorder(Theme.paper, lineWidth: selected ? 1.5 : 0))
                        .frame(width: 11, height: 11)
                        .contentShape(Rectangle().inset(by: -4))
                        .offset(x: x - 5.5, y: 22)
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { v in dragging = (m.id, v.translation.width) }
                                .onEnded { v in
                                    dragging = nil
                                    let frames = Int((Double(v.translation.width) / scale * timeline.rate.exact).rounded())
                                    if frames != 0 { timeline.updateMarker(m.id, frame: m.frame + frames) }
                                }
                        )
                        .onTapGesture { timeline.go(to: m) }
                        .contextMenu { MarkerContextMenu(timeline: timeline, marker: m) }
                        .help("\(m.kind.title)\(m.label.isEmpty ? "" : ": \(m.label)") · \(m.timecode(rate: timeline.rate).description). Drag to move.")
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

/// Thin ticks for every marker across the whole set.
struct MarkerTicks: View {
    @ObservedObject var timeline: TimelineModel
    let scale: Double
    let height: CGFloat

    var body: some View {
        Canvas { context, size in
            for item in timeline.placedMarkers {
                let x = CGFloat(item.time * scale)
                context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: height)), with: .color(item.marker.kind.color.opacity(0.85)))
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

struct MarkerContextMenu: View {
    @ObservedObject var timeline: TimelineModel
    let marker: Marker

    var body: some View {
        Button("Go To Marker") { timeline.go(to: marker) }
        Button("Rename…") {
            if let name = promptForText("Marker label", value: marker.label) { timeline.updateMarker(marker.id, label: name) }
        }
        Menu("Type") {
            ForEach(MarkerKind.allCases, id: \.self) { kind in
                Button((kind == marker.kind ? "✓ " : "   ") + kind.title) { timeline.updateMarker(marker.id, kind: kind) }
            }
        }
        Divider()
        Button("Delete Marker") { timeline.removeMarker(marker.id) }
    }
}

/// A one-line text prompt.
@MainActor
func promptForText(_ title: String, value: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.stringValue = value
    alert.accessoryView = field
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
}

// MARK: - List

/// The markers, CuePoints style: time, type, label. Click a row to go there; double-click the
/// label to rename; Delete removes the selected one. Shows the current song's, or the whole set's.
struct MarkerList: View {
    @ObservedObject var timeline: TimelineModel
    @State private var wholeSet = false
    @State private var editing: UUID?
    @State private var draft = ""

    private var rows: [Marker] {
        let placed = timeline.placedMarkers
        guard !wholeSet, let i = timeline.currentIndex, timeline.layout.items.indices.contains(i) else {
            return placed.map(\.marker)
        }
        let item = timeline.layout.items[i]
        return placed.filter { $0.time >= item.timelineStart - timeline.gap && $0.time < item.timelineEnd }.map(\.marker)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(wholeSet ? "WHOLE SET" : "THIS SONG").font(Theme.mono(9)).tracking(1.2).foregroundStyle(Theme.grey)
                Text("· \(rows.count)").font(Theme.mono(9)).foregroundStyle(Theme.quiet)
                Spacer()
                Button(wholeSet ? "This song" : "Whole set") { wholeSet.toggle() }
                    .buttonStyle(.plain).font(Theme.mono(9, bold: true)).foregroundStyle(Theme.grey)
            }
            HStack(spacing: 8) {
                Text("TIME").frame(width: 82, alignment: .leading)
                Text("TYPE").frame(width: 62, alignment: .leading)
                Text("LABEL")
            }
            .font(Theme.mono(8)).tracking(1).foregroundStyle(Theme.quiet)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { m in row(m).id(m.id) }
                    }
                }
                .onChange(of: timeline.selectedMarkerID) { id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            if rows.isEmpty {
                Text("Press 1–7 (or click a type) to drop a marker at the playhead.")
                    .font(Theme.grotesk(11, .light)).foregroundStyle(Theme.grey)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(
            // Delete removes the selected marker (when no label is being edited).
            Button("") {
                if editing == nil, let id = timeline.selectedMarkerID { timeline.removeMarker(id) }
            }
            .keyboardShortcut(.delete, modifiers: []).opacity(0)
        )
    }

    @ViewBuilder private func row(_ m: Marker) -> some View {
        let selected = timeline.selectedMarkerID == m.id
        HStack(spacing: 8) {
            Text(m.timecode(rate: timeline.rate).display(dropFrame: timeline.rate.isDropFrame))
                .font(Theme.mono(11)).monospacedDigit().frame(width: 82, alignment: .leading)
            Text(m.kind.title).font(Theme.grotesk(12, .medium)).foregroundStyle(m.kind.color)
                .frame(width: 62, alignment: .leading)
            if editing == m.id {
                TextField("Label", text: $draft)
                    .textFieldStyle(.plain).font(Theme.grotesk(12))
                    .onSubmit { timeline.updateMarker(m.id, label: draft); editing = nil }
                    .onExitCommand { editing = nil }
            } else {
                Text(m.label.isEmpty ? "—" : m.label).font(Theme.grotesk(12))
                    .foregroundStyle(m.label.isEmpty ? Theme.quiet : Theme.paper).lineLimit(1)
                    .onTapGesture(count: 2) { draft = m.label; editing = m.id }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(selected ? Theme.fill : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { timeline.go(to: m) }
        .contextMenu { MarkerContextMenu(timeline: timeline, marker: m) }
    }
}
