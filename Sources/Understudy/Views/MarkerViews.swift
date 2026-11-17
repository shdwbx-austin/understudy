import AppKit
import SwiftUI
import UnderstudyCore

extension Color {
    /// "#RRGGBB" (or "RRGGBB").
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        let v = UInt32(h, radix: 16) ?? 0x9A9A9A
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// "#RRGGBB" for storing.
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

extension MarkerTypes {
    func color(_ kind: MarkerKind) -> Color { Color(hex: type(kind).color) }
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
                .background(MarkerKeys(timeline: timeline))
            // Chips keep their full names; if there are more than fit, the row scrolls sideways.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(timeline.markerTypes.types.enumerated()), id: \.element.id) { index, type in
                        MarkerChip(timeline: timeline, type: type, number: index < MarkerTypes.keyed ? index + 1 : nil)
                            .fixedSize()
                    }
                    Button { timeline.editingMarkerTypes = true } label: {
                        Text("Edit types…").font(Theme.grotesk(13, .light)).foregroundStyle(Theme.grey)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Add, rename, recolour or reorder marker types (⌥⌘M)")
                }
            }
            Spacer()
            if model.linkBusy { ProgressView().controlSize(.small) }
            MarkerMenu(timeline: timeline)
        }
    }
}

/// One marker type: click (or press its number) to drop one; right-click to hide or show its markers.
private struct MarkerChip: View {
    @ObservedObject var timeline: TimelineModel
    let type: MarkerType
    let number: Int?

    var body: some View {
        let hidden = timeline.hiddenMarkerKinds.contains(type.id)
        let color = Color(hex: type.color)
        // A swatch, not a pill: a colour bar, the key in mono, the name in light type.
        // ⇧-click: select this type's markers in the song (⌘⇧ adds them); click: drop one.
        let chip = Button {
            let flags = NSEvent.modifierFlags
            if flags.contains(.shift) {
                timeline.selectMarkers(ofKind: type.id, adding: flags.contains(.command))
            } else {
                timeline.dropMarker(type.id)
            }
        } label: {
            HStack(spacing: 7) {
                Rectangle().fill(color.opacity(hidden ? 0.3 : 1)).frame(width: 3, height: 16)
                Text(number.map(String.init) ?? "·").font(Theme.mono(10)).foregroundStyle(Theme.grey)
                Text(type.name).font(Theme.grotesk(13, .light)).lineLimit(1)
                    .foregroundStyle(hidden ? Theme.quiet : color)
            }
            .padding(.trailing, 9).padding(.vertical, 4)
            .background(Rectangle().fill(hidden ? Color.clear : Theme.fill))
        }
        .buttonStyle(.plain)
        .help("Add a \(type.name) marker at the playhead\(number.map { " (\($0))" } ?? ""). ⇧-click selects every \(type.name) marker in the song. Right-click to hide or show them.")
        .contextMenu {
            Button(hidden ? "Show \(type.name) Markers" : "Hide \(type.name) Markers") {
                if hidden { timeline.hiddenMarkerKinds.remove(type.id) } else { timeline.hiddenMarkerKinds.insert(type.id) }
            }
            Divider()
            Button("Edit Marker Types…") { timeline.editingMarkerTypes = true }
        }
        chip
    }
}

/// Export and send: the export sheet (types, songs, pages, executors, tracks), and quick sends
/// with its saved setup: CSV, grandMA3 (plugin file or straight over OSC), disguise (over the network).
struct MarkerMenu: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var timeline: TimelineModel

    var body: some View {
        Menu {
            Button("Export Markers…") { timeline.exportingMarkers = true }
            Divider()
            Button("Send to grandMA3") { model.deployMarkersToMA3() }
                .disabled(model.settings.ma3Host.isEmpty || timeline.markers.isEmpty)
            Button("Send to disguise") { model.pushMarkersToD3() }
                .disabled(model.settings.d3Host.isEmpty || timeline.markers.isEmpty)
            Divider()
            Button("Export CSV…") { model.exportMarkersCSV() }.disabled(timeline.markers.isEmpty)
            Button("Export grandMA3 Plugin…") { model.exportMA3Plugin() }.disabled(timeline.markers.isEmpty)
            Divider()
            // ] and [ are handled by MarkerKeys; a pull-down only sometimes registers its shortcuts.
            Button("Next Marker   ]") { timeline.nextMarker() }
            Button("Previous Marker   [") { timeline.previousMarker() }
            Divider()
            Button("Show All Types") { timeline.hiddenMarkerKinds = [] }.disabled(timeline.hiddenMarkerKinds.isEmpty)
            Button("Edit Marker Types…") { timeline.editingMarkerTypes = true }
            Button("Show Control Settings…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        } label: {
            Text("Send / Export").font(Theme.grotesk(14, .light)).foregroundStyle(Theme.paper)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Send markers to grandMA3 or disguise, export them, or edit the marker types")

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
    /// Everything moving with the dragged marker (its selection, or its whole array).
    @State private var dragGroup: Set<UUID>?

    /// Label lanes. Lane 0 sits beside the marker's own tag, in the tag row, so it must clear
    /// the other tags as well as the label before it; lower lanes only have labels to clear.
    private func lanes(_ items: [(marker: Marker, time: Double)]) -> [UUID: Int] {
        let tags = items.map { CGFloat(($0.time - from) * scale) }
        var ends: [CGFloat] = []
        var out: [UUID: Int] = [:]
        for (i, item) in items.enumerated() {
            if item.marker.arrayID != nil { continue }   // arrayed hits draw no label
            let start = tags[i] + 10
            let end = start + CGFloat(item.marker.displayName(in: timeline.markerTypes).count) * 6.4 + 8
            let clearsTags = !tags.indices.contains { j in j != i && tags[j] + 7 > start && tags[j] - 7 < end }
            var lane = ends.firstIndex { $0 <= start } ?? ends.count
            if lane == 0 && !clearsTags { lane = ends.dropFirst().firstIndex { $0 <= start } ?? max(ends.count, 1) }
            while ends.count <= lane { ends.append(-.infinity) }
            ends[lane] = end + 6
            out[item.marker.id] = lane
        }
        return out
    }

    /// Arrayed hits get a tag only where it has room (12 pt from the last one shown); the rest
    /// are just their hairline, so a run of hits reads as a run, not a solid bar.
    private func arrayTags(_ items: [(marker: Marker, time: Double)]) -> Set<UUID> {
        var shown: Set<UUID> = []
        var last = -CGFloat.infinity
        for item in items where item.marker.arrayID != nil {
            let x = CGFloat((item.time - from) * scale)
            if x - last >= 12 || timeline.selectedMarkerIDs.contains(item.marker.id) && x - last >= 4 {
                shown.insert(item.marker.id)
                last = x
            }
        }
        return shown
    }

    var body: some View {
        let items = timeline.placedMarkers
        let lane = lanes(items)
        let roomy = arrayTags(items)
        ZStack(alignment: .topLeading) {
            ForEach(items, id: \.marker.id) { item in
                let m = item.marker
                // Dragging a selected marker moves the whole selection.
                let dx: CGFloat = {
                    guard let d = dragging else { return 0 }
                    if d.id == m.id { return d.dx }
                    return dragGroup?.contains(m.id) == true ? d.dx : 0
                }()
                let x = CGFloat((item.time - from) * scale) + dx
                if x >= -2, x <= width + 2 {
                    let selected = timeline.selectedMarkerIDs.contains(m.id)
                    let color = timeline.markerTypes.color(m.kind)
                    let key = timeline.markerTypes.number(m.kind).map(String.init) ?? ""
                    let arrayed = m.arrayID != nil
                    Rectangle().fill(color.opacity(selected ? 1 : arrayed ? 0.4 : 0.7))
                        .frame(width: 1, height: height - 22)
                        .offset(x: x - 0.5, y: 22)
                        .allowsHitTesting(false)
                    // Label beside the tag, in small mono capitals; crowded ones stack downward.
                    // Arrayed hits have none: a run of them would be a wall of text.
                    // Past four lanes a label would land on another: it's left off (the marker
                    // list has it), unless the marker is selected.
                    if !arrayed, (lane[m.id] ?? 0) <= 3 || selected {
                    Text(m.displayName(in: timeline.markerTypes).uppercased())
                        .font(Theme.mono(9, bold: selected))
                        .tracking(0.8)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 3)
                        .background(Theme.ink.opacity(selected ? 1 : 0.75))
                        .zIndex(selected ? 1 : 0)
                        .offset(x: x + 10, y: 24 + CGFloat(min(lane[m.id] ?? 0, 3)) * 15)
                        .allowsHitTesting(false)
                    }
                    // Tag: a square in the type's colour with its key. Drag to move, click to go.
                    // Arrayed hits get a small square without the key, just under the tag row.
                    if !arrayed || roomy.contains(m.id) {
                    Text(arrayed ? "" : key)
                        .font(Theme.mono(8, bold: true))
                        .foregroundStyle(Theme.ink)
                        .frame(width: arrayed ? 7 : 13, height: arrayed ? 7 : 13)
                        .background(Rectangle().fill(color.opacity(arrayed && !selected ? 0.75 : 1)))
                        .overlay(Rectangle().strokeBorder(Theme.paper, lineWidth: selected ? (arrayed ? 1 : 1.5) : 0))
                        .contentShape(Rectangle().inset(by: arrayed ? -3 : -4))
                        .offset(x: x - (arrayed ? 3.5 : 6.5), y: arrayed ? 25 : 22)
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { v in
                                    if dragging?.id != m.id { dragGroup = timeline.dragGroup(for: m.id) }
                                    dragging = (m.id, v.translation.width)
                                }
                                .onEnded { v in
                                    dragging = nil
                                    dragGroup = nil
                                    let frames = Int((Double(v.translation.width) / scale * timeline.rate.exact).rounded())
                                    guard frames != 0 else { return }
                                    // Snapped to the grid when Snap is on; a selection moves together.
                                    timeline.drop(m.id, at: m.frame + frames)
                                }
                        )
                        .onTapGesture { MarkerClick.handle(m, timeline: timeline, order: items.map(\.marker.id)) }
                        .contextMenu { MarkerContextMenu(timeline: timeline, marker: m) }
                        .help(arrayed ? "\(timeline.markerTypes.name(m.kind)) hit, every \(m.arrayStep ?? "beat") · \(m.timecode(rate: timeline.rate).description). Right-click › Clear This Array." : "\(timeline.markerTypes.name(m.kind))\(m.label.isEmpty ? "" : ": \(m.label)") · \(m.timecode(rate: timeline.rate).description). Drag to move; ⌘-click or ⇧-click to select several.")
                    }
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
                context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: height)), with: .color(timeline.markerTypes.color(item.marker.kind).opacity(0.85)))
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

/// A click on a marker: plain goes there (and selects just it); ⌘ adds or removes it from the
/// selection; ⇧ selects the run from the last one chosen. ⌘ and ⇧ don't move the playhead.
@MainActor
enum MarkerClick {
    static func handle(_ m: Marker, timeline: TimelineModel, order: [UUID]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            timeline.select(m.id, toggle: true)
        } else if flags.contains(.shift) {
            timeline.select(m.id, extendIn: order)
        } else {
            timeline.go(to: m)
        }
    }
}

struct MarkerContextMenu: View {
    @ObservedObject var timeline: TimelineModel
    let marker: Marker

    var body: some View {
        let group = timeline.selectedMarkerIDs
        if group.count > 1, group.contains(marker.id) {
            MarkerGroupActions(timeline: timeline, ids: group)
        } else {
            single
        }
    }

    @ViewBuilder private var single: some View {
        Button("Go To Marker") { timeline.go(to: marker) }
        Button("Copy   ⌘C") { timeline.copyMarkers([marker.id]) }
        Button("Paste at Playhead   ⌘V") { timeline.pasteMarkers() }.disabled(timeline.clipboard.isEmpty)
        Button("Rename…") {
            if let name = promptForText("Marker label", value: marker.label) { timeline.updateMarker(marker.id, label: name) }
        }
        Menu("Type") {
            ForEach(timeline.markerTypes.types) { type in
                Button((type.id == marker.kind ? "✓ " : "   ") + type.name) { timeline.updateMarker(marker.id, kind: type.id) }
            }
        }
        QuantizeMenu(timeline: timeline, ids: [marker.id], title: "Snap to Grid")
        Divider()
        Button("Array From Here…") { ArrayPrompt.ask(timeline: timeline, anchor: marker) }
        if let array = marker.arrayID {
            let n = timeline.markers.filter { $0.arrayID == array }.count
            Button("Select This Array (\(n))") { timeline.selectMarkers(timeline.markers.filter { $0.arrayID == array }.map(\.id)) }
            MoveMenu(timeline: timeline, ids: timeline.arrayMembers(array))
            Button("Clear This Array (\(n))") { timeline.clearArray(array) }
        }
        Divider()
        Button("Delete Marker") { timeline.removeMarker(marker.id) }
    }
}

/// What can be done to several markers at once: type, label, move, loop, delete.
struct MarkerGroupActions: View {
    @ObservedObject var timeline: TimelineModel
    let ids: Set<UUID>

    var body: some View {
        Text("\(ids.count) Markers Selected")
        Menu("Type") {
            ForEach(timeline.markerTypes.types) { type in
                Button(type.name) { timeline.updateMarkers(ids, kind: type.id) }
            }
        }
        Button("Label All…") {
            if let name = promptForText("Label for \(ids.count) markers", value: commonLabel) { timeline.updateMarkers(ids, label: name) }
        }
        Button("Clear Labels") { timeline.updateMarkers(ids, label: "") }
        Button("Copy   ⌘C") { timeline.copyMarkers(ids) }
        Button("Cut   ⌘X") { timeline.selectMarkers(Array(ids)); timeline.cutMarkers() }
        MoveMenu(timeline: timeline, ids: ids)
        QuantizeMenu(timeline: timeline, ids: ids)
        Button("Loop Between Them") {
            timeline.loopSelectedMarkers()
        }
        let arrays = Set(timeline.markers.filter { ids.contains($0.id) }.compactMap(\.arrayID))
        if !arrays.isEmpty {
            Button(arrays.count == 1 ? "Clear Their Array" : "Clear Their \(arrays.count) Arrays") { arrays.forEach(timeline.clearArray) }
        }
        Divider()
        Button("Delete \(ids.count) Markers") { timeline.removeMarkers(ids) }
    }

    /// The label they share, if they all have the same one.
    private var commonLabel: String {
        let labels = Set(timeline.markers.filter { ids.contains($0.id) }.map(\.label))
        return labels.count == 1 ? labels.first! : ""
    }

    /// "12" frames, "-3", "1.5s" or "-2 s" seconds.
    static func frames(_ text: String, fps: Double) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix("s"), let s = Double(t.dropLast().trimmingCharacters(in: .whitespaces)) { return Int((s * fps).rounded()) }
        return Int(t)
    }
}

/// A song's tempo: BPM and beats per bar (or none). Offers what was heard in its audio (with
/// half, double and the runner-up tempos one click away) and the BPM in its file name.
@MainActor
enum TempoPrompt {
    static let choices = [2, 3, 4, 5, 6, 7]

    static func ask(timeline: TimelineModel, song: Song) {
        let (alert, bpm, meter, setter) = make(timeline: timeline, song: song)
        let answer = alert.runModal()
        withExtendedLifetime(setter) {}
        switch answer {
        case .alertFirstButtonReturn:
            guard let value = SongTempo.parse(bpm.stringValue) else {
                ArrayPrompt.complain("“\(bpm.stringValue)” isn't a tempo.", "Type the BPM as a number between 20 and 400, e.g. 120.")
                return ask(timeline: timeline, song: song)
            }
            // Confirming the heard tempo (or half/double of it) keeps its beat positions.
            timeline.setTempo(song.id, bpm: value, beatsPerBar: choices[max(0, meter.indexOfSelectedItem)])
            timeline.showGrid = true
        case .alertThirdButtonReturn:
            timeline.setTempo(song.id, bpm: nil)
        default: break
        }
    }

    /// The dialog, built but not shown.
    static func make(timeline: TimelineModel, song: Song) -> (NSAlert, NSTextField, NSPopUpButton, FieldSetter) {
        let alert = NSAlert()
        alert.messageText = "Tempo for “\(song.name)”"
        let heard = timeline.heardTempo(song)
        var info = "For the beat grid and arraying markers. Quarter notes per minute."
        if let heard {
            info += "\n\nHeard in the audio: ≈ \(TimelineModel.bpmText(heard.bpm)) BPM"
                + (heard.isConfident ? "." : " (not sure: the beat isn't clear).")
                + (heard.channel.map { " From channel \($0 + 1)." } ?? "")
            info += " Beat one is a guess: Set Downbeat at Playhead moves it."
        } else if song.audioPath != nil {
            info += "\n\nNo clear beat heard in the audio yet."
        }
        alert.informativeText = info
        let bpm = NSTextField(frame: NSRect(x: 0, y: 34, width: 90, height: 24))
        bpm.placeholderString = "BPM"
        bpm.stringValue = timeline.suggestedBPM(song).map(TimelineModel.bpmText) ?? ""
        let meter = NSPopUpButton(frame: NSRect(x: 100, y: 33, width: 150, height: 26))
        meter.addItems(withTitles: choices.map { "\($0) beats a bar" })
        meter.selectItem(at: choices.firstIndex(of: song.beatsPerBar ?? 4) ?? 2)
        // One-click changes to the field: half, double, and the other tempos it might be.
        let setter = FieldSetter(field: bpm)
        var quick: [(String, (Double) -> Double?)] = [("÷2", { $0 / 2 }), ("×2", { $0 * 2 })]
        for alt in heard?.alternatives ?? [] { quick.append((TimelineModel.bpmText(alt), { _ in alt })) }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 64))
        view.addSubview(bpm)
        view.addSubview(meter)
        var x: CGFloat = 0
        for (title, change) in quick {
            let button = NSButton(title: title, target: setter, action: #selector(FieldSetter.apply(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.sizeToFit()
            button.frame.origin = NSPoint(x: x, y: 2)
            button.tag = setter.add(change)
            button.toolTip = title.hasPrefix("÷") || title.hasPrefix("×") ? "\(title) the tempo in the box" : "Use \(title) BPM (another tempo it could be)"
            view.addSubview(button)
            x += button.frame.width + 6
        }
        alert.accessoryView = view
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        if song.bpm != nil { alert.addButton(withTitle: "No Tempo") }
        alert.window.initialFirstResponder = bpm
        return (alert, bpm, meter, setter)
    }
}

/// Target for the Tempo dialog's quick buttons: each changes the BPM field.
@MainActor
final class FieldSetter: NSObject {
    let field: NSTextField
    private var changes: [(Double) -> Double?] = []

    init(field: NSTextField) { self.field = field }

    func add(_ change: @escaping (Double) -> Double?) -> Int {
        changes.append(change)
        return changes.count - 1
    }

    @objc func apply(_ sender: NSButton) {
        guard changes.indices.contains(sender.tag) else { return }
        let current = SongTempo.parse(field.stringValue) ?? 0
        if let value = changes[sender.tag](current), value > 0 {
            field.stringValue = TimelineModel.bpmText((value * 100).rounded() / 100)
        }
    }
}

/// "Array from here": hits every 1/4 (or other value) after a marker, until the next marker, the
/// song's end, the loop's end, or a count.
@MainActor
enum ArrayPrompt {
    static func ask(timeline: TimelineModel, anchor: Marker) {
        guard let item = timeline.song(of: anchor) else { return }
        let song = timeline.songs.first { $0.id == item.song.id } ?? item.song
        let alert = NSAlert()
        alert.messageText = "Array \(timeline.markerTypes.name(anchor.kind)) markers from here"
        alert.informativeText = "Adds a \(timeline.markerTypes.name(anchor.kind)) marker on every beat value after this one. They're kept together, so they clear in one go (right-click any of them › Clear Array)."
        let bpm = NSTextField(frame: NSRect(x: 0, y: 64, width: 80, height: 24))
        bpm.placeholderString = "BPM"
        bpm.stringValue = timeline.suggestedBPM(song).map(TimelineModel.bpmText) ?? ""
        let bpmLabel = NSTextField(labelWithString: "BPM")
        bpmLabel.frame = NSRect(x: 86, y: 68, width: 40, height: 16)
        let note = NSPopUpButton(frame: NSRect(x: 130, y: 63, width: 150, height: 26))
        note.addItems(withTitles: NoteValue.allCases.map(\.title))
        note.selectItem(at: NoteValue.allCases.firstIndex(of: .quarter) ?? 2)
        let until = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 200, height: 26))
        var extents: [(String, TimelineModel.ArrayExtent)] = [("Until the next marker", .nextMarker), ("To the end of the song", .songEnd)]
        if timeline.loopRange != nil { extents.append(("To the end of the loop", .loopEnd)) }
        extents.append(("This many:", .count(16)))
        until.addItems(withTitles: extents.map(\.0))
        let count = NSTextField(frame: NSRect(x: 208, y: 31, width: 60, height: 24))
        count.stringValue = "16"
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 92))
        [bpm, bpmLabel, note, until, count].forEach(view.addSubview)
        alert.accessoryView = view
        alert.addButton(withTitle: "Add Markers")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = bpm
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let tempo = SongTempo.parse(bpm.stringValue) else {
            complain(bpm.stringValue.isEmpty ? "What's the tempo?" : "“\(bpm.stringValue)” isn't a tempo.",
                     "Type the song's BPM as a number between 20 and 400, e.g. 120. It's saved with the song for next time.")
            return ask(timeline: timeline, anchor: anchor)
        }
        var extent = extents[max(0, until.indexOfSelectedItem)].1
        if case .count = extent { extent = .count(max(1, Int(count.stringValue.trimmingCharacters(in: .whitespaces)) ?? 16)) }
        let added = timeline.arrayMarkers(from: anchor, bpm: tempo, note: NoteValue.allCases[max(0, note.indexOfSelectedItem)], extent: extent)
        if added == 0 {
            complain("No markers added", (timeline.message ?? "There's no room for a hit there.") + " Try “To the end of the song” or a count.")
        }
    }

    static func complain(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// Move ▸ by a beat or bar of the song's grid (when it has a tempo), a frame, a second, or any amount.
struct MoveMenu: View {
    @ObservedObject var timeline: TimelineModel
    let ids: Set<UUID>

    var body: some View {
        Menu("Move") {
            if let beat = timeline.gridStepFrames(for: ids), let bar = timeline.gridStepFrames(for: ids, bars: true) {
                Button("Back 1 Bar") { timeline.updateMarkers(ids, moveFrames: -bar) }
                Button("Back 1 Beat") { timeline.updateMarkers(ids, moveFrames: -beat) }
                Button("Forward 1 Beat") { timeline.updateMarkers(ids, moveFrames: beat) }
                Button("Forward 1 Bar") { timeline.updateMarkers(ids, moveFrames: bar) }
                Divider()
            }
            let fps = Int(timeline.rate.exact.rounded())
            Button("Back 1 Second") { timeline.updateMarkers(ids, moveFrames: -fps) }
            Button("Back 1 Frame") { timeline.updateMarkers(ids, moveFrames: -1) }
            Button("Forward 1 Frame") { timeline.updateMarkers(ids, moveFrames: 1) }
            Button("Forward 1 Second") { timeline.updateMarkers(ids, moveFrames: fps) }
            Divider()
            Button("By…") {
                if let text = promptForText("Move \(ids.count) marker\(ids.count == 1 ? "" : "s") by frames (negative = earlier), or seconds with s (e.g. -1.5s)", value: "0"),
                   let frames = MarkerGroupActions.frames(text, fps: timeline.rate.exact), frames != 0 {
                    timeline.updateMarkers(ids, moveFrames: frames)
                }
            }
        }
    }
}

/// Quantize ▸ to the snap value (Q), any other grid value, or halfway there.
struct QuantizeMenu: View {
    @ObservedObject var timeline: TimelineModel
    let ids: Set<UUID>
    var title = "Quantize"

    var body: some View {
        Menu(title) {
            Button("To \(timeline.snapNote.short)   Q") { timeline.quantize(ids) }
            Button("Halfway to \(timeline.snapNote.short) (50%)") { timeline.quantize(ids, strength: 0.5) }
            Divider()
            ForEach(NoteValue.allCases, id: \.self) { note in
                if note != timeline.snapNote { Button("To \(note.title)") { timeline.quantize(ids, note: note) } }
            }
        }
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

/// The markers: time, type, label. Click a row to go there; ⌘-click or ⇧-click to select several
/// and change them together; double-click the label to rename; Delete removes the selection.
/// Shows the current song's, or the whole set's.
struct MarkerList: View {
    @ObservedObject var timeline: TimelineModel
    @State private var wholeSet = false
    /// The row the playhead has just passed (the "now" marker), kept in view as it plays.
    @State private var nowID: UUID?
    @FocusState private var labelFocused: Bool
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

    /// A row: one marker, or a whole array of hits as one line.
    private enum Entry: Identifiable {
        case marker(Marker)
        case array(UUID, [Marker])
        var id: UUID {
            switch self {
            case .marker(let m): return m.id
            case .array(let id, _): return id
            }
        }
    }

    /// Each row's timeline time (an array's is its first hit), in order.
    private var entryTimes: [(id: UUID, time: Double)] {
        let times = Dictionary(timeline.placedMarkers.map { ($0.marker.id, $0.time) }, uniquingKeysWith: { a, _ in a })
        return entries.compactMap { entry in
            switch entry {
            case .marker(let m): return times[m.id].map { (m.id, $0) }
            case .array(let id, let hits): return times[hits[0].id].map { (id, $0) }
            }
        }
    }

    private var entries: [Entry] {
        let list = rows
        let groups = Dictionary(grouping: list.filter { $0.arrayID != nil }, by: { $0.arrayID! })
        var seen: Set<UUID> = []
        var out: [Entry] = []
        for m in list {
            if let id = m.arrayID {
                if seen.insert(id).inserted { out.append(.array(id, groups[id] ?? [m])) }
            } else {
                out.append(.marker(m))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(wholeSet ? "WHOLE SET" : "THIS SONG").font(Theme.mono(9)).tracking(1.2).foregroundStyle(Theme.grey)
                Text("· \(rows.count)").font(Theme.mono(9)).foregroundStyle(Theme.quiet)
                Spacer()
                if rows.contains(where: { $0.arrayID != nil }) {
                    Button("Clear arrays") {
                        let arrays = Set(rows.compactMap(\.arrayID))
                        arrays.forEach(timeline.clearArray)
                    }
                    .buttonStyle(.plain).font(Theme.mono(9, bold: true)).foregroundStyle(Theme.grey)
                    .help("Remove every arrayed run of hits in this list; markers placed by hand stay")
                }
                Button("Select all") { timeline.selectMarkers(rows.map(\.id)) }
                    .buttonStyle(.plain).font(Theme.mono(9, bold: true)).foregroundStyle(Theme.grey)
                    .disabled(rows.isEmpty)
                    .help("Select every marker in the list, to change them together")
                Button(wholeSet ? "This song" : "Whole set") { wholeSet.toggle() }
                    .buttonStyle(.plain).font(Theme.mono(9, bold: true)).foregroundStyle(Theme.grey)
            }
            if timeline.selectedMarkerIDs.count > 1 {
                SelectionBar(timeline: timeline)
            }
            HStack(spacing: 8) {
                Text("TIME").frame(width: 82, alignment: .leading)
                Text("TYPE").frame(width: 92, alignment: .leading)
                Text("LABEL")
            }
            .font(Theme.mono(8)).tracking(1).foregroundStyle(Theme.quiet)
            ScrollViewReader { proxy in
                ScrollView {
                    // Watches the playhead on its own; the list only redraws when the row changes.
                    MarkerFollower(head: timeline.head, times: entryTimes, editing: editing != nil, nowID: $nowID) { id in
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            switch entry {
                            case .marker(let m): row(m).id(m.id)
                            case .array(let id, let hits): arrayRow(id, hits).id(id)
                            }
                        }
                    }
                }
                .onChange(of: timeline.selectedMarkerID) { id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
                }
                // A marker just dropped (or Return on the selected one): its label opens for typing.
                .onChange(of: timeline.namingMarkerID) { id in
                    guard let id, let m = timeline.markers.first(where: { $0.id == id }) else { return }
                    if !rows.contains(where: { $0.id == id }) { wholeSet = true }
                    draft = m.label
                    editing = id
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            if rows.isEmpty {
                Text("Press 1–9 (or click a type) to drop a marker at the playhead.")
                    .font(Theme.grotesk(11, .light)).foregroundStyle(Theme.grey)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Done typing a label: back to the timeline's keys.
    private func finishNaming() {
        editing = nil
        labelFocused = false
        timeline.namingMarkerID = nil
    }

    /// A run of arrayed hits on one line: where it starts, how many, how often. Click goes to the
    /// first; ⌘-click selects them all (then drag one on the timeline to move the lot).
    @ViewBuilder private func arrayRow(_ id: UUID, _ hits: [Marker]) -> some View {
        let first = hits[0]
        let selected = hits.allSatisfy { timeline.selectedMarkerIDs.contains($0.id) }
        let color = timeline.markerTypes.color(first.kind)
        HStack(spacing: 8) {
            Text(first.timecode(rate: timeline.rate).display(dropFrame: timeline.rate.isDropFrame))
                .font(Theme.mono(11)).monospacedDigit().frame(width: 82, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in Rectangle().fill(color).frame(width: 4, height: 4) }
                Text(timeline.markerTypes.name(first.kind)).font(Theme.grotesk(12, .light)).foregroundStyle(color)
                    .lineLimit(1).minimumScaleFactor(0.8).padding(.leading, 3)
            }
            .frame(width: 92, alignment: .leading)
            Text("\(hits.count) × \(first.arrayStep ?? "beat")" + (first.label.isEmpty ? "" : "  ·  \(first.label)"))
                .font(Theme.mono(11)).foregroundStyle(Theme.grey).lineLimit(1)
            Spacer(minLength: 0)
            Button { timeline.clearArray(id) } label: {
                Text("×").font(Theme.grotesk(14)).foregroundStyle(Theme.grey).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Clear these \(hits.count) hits")
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(selected ? Theme.fill : Color.clear)
        .overlay(alignment: .leading) {
            if nowID == id { Rectangle().fill(Theme.signal).frame(width: 3) } else if selected { Rectangle().fill(Theme.paper).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                let ids = hits.map(\.id)
                if selected { ids.forEach { timeline.select($0, toggle: true) } } else { timeline.selectedMarkerIDs.formUnion(ids) }
            } else {
                timeline.go(to: first)
            }
        }
        .contextMenu {
            Button("Go To First") { timeline.go(to: first) }
            Button("Select All \(hits.count)") { timeline.selectMarkers(hits.map(\.id)) }
            MoveMenu(timeline: timeline, ids: Set(hits.map(\.id)))
            QuantizeMenu(timeline: timeline, ids: Set(hits.map(\.id)))
            Button("Copy Array") { timeline.copyMarkers(Set(hits.map(\.id))) }
            Divider()
            Button("Clear This Array (\(hits.count))") { timeline.clearArray(id) }
        }
        .help("\(hits.count) \(timeline.markerTypes.name(first.kind)) hits every \(first.arrayStep ?? "beat"), arrayed. ⌘-click to select them all.")
    }

    @ViewBuilder private func row(_ m: Marker) -> some View {
        let selected = timeline.selectedMarkerIDs.contains(m.id)
        HStack(spacing: 8) {
            Text(m.timecode(rate: timeline.rate).display(dropFrame: timeline.rate.isDropFrame))
                .font(Theme.mono(11)).monospacedDigit().frame(width: 82, alignment: .leading)
            HStack(spacing: 6) {
                Rectangle().fill(timeline.markerTypes.color(m.kind)).frame(width: 7, height: 7)
                Text(timeline.markerTypes.name(m.kind)).font(Theme.grotesk(12, .light)).foregroundStyle(timeline.markerTypes.color(m.kind))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 92, alignment: .leading)
            if editing == m.id {
                TextField("Name it, then Return (Esc to skip)", text: $draft)
                    .textFieldStyle(.plain).font(Theme.grotesk(12))
                    .focused($labelFocused)
                    .onAppear { labelFocused = true }
                    .onSubmit { timeline.updateMarker(m.id, label: draft); finishNaming() }
                    .onExitCommand { finishNaming() }
            } else {
                Text(m.label.isEmpty ? "—" : m.label).font(Theme.grotesk(12))
                    .foregroundStyle(m.label.isEmpty ? Theme.quiet : Theme.paper).lineLimit(1)
                    .onTapGesture(count: 2) { draft = m.label; editing = m.id }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(selected ? Theme.fill : Color.clear)
        .overlay(alignment: .leading) {
            if nowID == m.id {
                Rectangle().fill(Theme.signal).frame(width: 3)
            } else if selected, timeline.selectedMarkerIDs.count > 1 {
                Rectangle().fill(Theme.paper).frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { MarkerClick.handle(m, timeline: timeline, order: rows.map(\.id)) }
        .contextMenu { MarkerContextMenu(timeline: timeline, marker: m) }
    }
}

/// Follows the playhead through the marker list: the row it has just passed becomes "now" and is
/// scrolled into view, while playing or scrubbing. Leaves the list alone while a label is edited.
private struct MarkerFollower: View {
    @ObservedObject var head: PlayheadClock
    let times: [(id: UUID, time: Double)]
    let editing: Bool
    @Binding var nowID: UUID?
    let scroll: (UUID) -> Void

    var body: some View {
        Color.clear.frame(height: 0)
            .onChange(of: head.position) { p in follow(p) }
            .onAppear { follow(head.position) }
    }

    private func follow(_ p: Double) {
        // The last row at or before the playhead (a hair of slack for landing on a marker).
        let current = times.last { $0.time <= p + 0.02 }?.id
        guard current != nowID else { return }
        nowID = current
        if let current, !editing { scroll(current) }
    }
}

/// Above the list while several markers are selected: how many, and what to do to all of them.
private struct SelectionBar: View {
    @ObservedObject var timeline: TimelineModel

    var body: some View {
        let ids = timeline.selectedMarkerIDs
        HStack(spacing: 12) {
            Text("\(ids.count) SELECTED").font(Theme.mono(9, bold: true)).tracking(1.2)
            Menu { MarkerGroupActions(timeline: timeline, ids: ids) } label: {
                Text("Edit").font(Theme.grotesk(12, .regular))
            }
            .menuStyle(.borderlessButton).fixedSize()
            Button("Delete") { timeline.removeMarkers(ids) }
                .buttonStyle(.plain).font(Theme.grotesk(12, .light)).foregroundStyle(Theme.signal)
            Spacer()
            Button("Done") { timeline.clearMarkerSelection() }
                .buttonStyle(.plain).font(Theme.grotesk(12, .light)).foregroundStyle(Theme.grey)
                .help("Back to one marker (Esc)")
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(Rectangle().fill(Theme.fill))
    }
}

// MARK: - Editing types

/// The project's marker types: name, colour, order (the first nine get keys 1–9). Drag to reorder.
struct MarkerTypesEditor: View {
    @ObservedObject var timeline: TimelineModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Marker types").font(Theme.grotesk(24, .medium))
                Spacer()
                TextButton(title: "Done", color: Theme.lock) { dismiss() }
            }
            Text("Saved with the project. Drag to reorder: the first nine are keys 1–9 and OSC numbers /marker/1–9; OSC also takes the name.")
                .font(Theme.grotesk(12, .light)).foregroundStyle(Theme.grey)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(Array(timeline.markerTypes.types.enumerated()), id: \.element.id) { index, type in
                    TypeRow(timeline: timeline, index: index, type: type)
                }
                .onMove { from, to in timeline.markerTypes.types.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 300)
            HStack {
                TextButton(title: "+ Add type", color: timeline.markerTypes.types.count < MarkerTypes.maxTypes ? Theme.paper : Theme.quiet) {
                    let n = timeline.markerTypes.types.count
                    let color = MarkerTypes.palette[n % MarkerTypes.palette.count]
                    timeline.markerTypes.add(name: "Type \(n + 1)", color: color)
                }
                .disabled(timeline.markerTypes.types.count >= MarkerTypes.maxTypes)
                Spacer()
                TextButton(title: "Reset to defaults", color: Theme.grey) { resetDefaults() }
            }
        }
        .padding(24)
        .frame(width: 560, height: 520)
        .background(Theme.ink)
        .foregroundStyle(Theme.paper)
        .preferredColorScheme(.dark)
    }

    /// Back to the seven built-in types; markers of other types move to the first.
    private func resetDefaults() {
        let custom = timeline.markerTypes.types.filter { t in !MarkerTypes.defaults.types.contains { $0.id == t.id } }
        let inUse = custom.reduce(0) { $0 + timeline.markerCount($1.id) }
        if inUse > 0 {
            let alert = NSAlert()
            alert.messageText = "Reset marker types?"
            alert.informativeText = "\(inUse) marker\(inUse == 1 ? "" : "s") of your own types will become \(MarkerTypes.defaults.types[0].name)."
            alert.addButton(withTitle: "Reset")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for t in custom { timeline.removeMarkerType(t.id, moveTo: MarkerTypes.defaults.types[0].id) }
        timeline.markerTypes = .defaults
    }
}

private struct TypeRow: View {
    @ObservedObject var timeline: TimelineModel
    let index: Int
    let type: MarkerType

    var body: some View {
        HStack(spacing: 12) {
            Text(index < MarkerTypes.keyed ? "\(index + 1)" : "·")
                .font(Theme.mono(11, bold: true)).frame(width: 18)
                .foregroundStyle(Theme.grey)
            ColorPicker("", selection: Binding(
                get: { Color(hex: type.color) },
                set: { c in update { $0.color = c.hexString } }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 44)
            TextField("Name", text: Binding(get: { type.name }, set: { v in update { $0.name = v } }))
                .textFieldStyle(.plain).font(Theme.grotesk(15, .medium))
                .foregroundStyle(Color(hex: type.color))
            Spacer()
            let count = timeline.markerCount(type.id)
            Text(count == 0 ? "unused" : "\(count) marker\(count == 1 ? "" : "s")")
                .font(Theme.mono(10)).foregroundStyle(Theme.grey)
            Button { remove() } label: { Text("×").font(Theme.grotesk(18)) }
                .buttonStyle(.plain).foregroundStyle(Theme.grey)
                .disabled(timeline.markerTypes.types.count <= 1)
                .help("Remove this type")
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
    }

    private func update(_ change: (inout MarkerType) -> Void) {
        guard let i = timeline.markerTypes.types.firstIndex(where: { $0.id == type.id }) else { return }
        change(&timeline.markerTypes.types[i])
    }

    /// Unused: just goes. In use: move its markers to another type, or delete them with it.
    private func remove() {
        let count = timeline.markerCount(type.id)
        guard count > 0 else { timeline.removeMarkerType(type.id, moveTo: nil); return }
        let others = timeline.markerTypes.types.filter { $0.id != type.id }
        let alert = NSAlert()
        alert.messageText = "Remove “\(type.name)”?"
        alert.informativeText = "\(count) marker\(count == 1 ? " uses" : "s use") it."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        picker.addItems(withTitles: others.map { "Move them to \($0.name)" })
        alert.accessoryView = picker
        alert.addButton(withTitle: "Move and Remove")
        alert.addButton(withTitle: "Delete Them Too")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: timeline.removeMarkerType(type.id, moveTo: others[max(0, picker.indexOfSelectedItem)].id)
        case .alertSecondButtonReturn: timeline.removeMarkerType(type.id, moveTo: nil)
        default: break
        }
    }
}

/// Presents the marker type editor wherever the main window is (any mode).
struct MarkerTypesSheet: ViewModifier {
    @ObservedObject var timeline: TimelineModel

    func body(content: Content) -> some View {
        content.sheet(isPresented: $timeline.editingMarkerTypes) { MarkerTypesEditor(timeline: timeline) }
    }
}

// MARK: - Keys

/// The timeline's single-key commands: 1–9 drop a marker of that type, M another of the last
/// type, ] and [ step to the next and previous marker, I and O set a loop section, L loops on and
/// off, Esc drops a multiple selection. Read straight off the window's key events
/// rather than as SwiftUI shortcuts, which only sometimes register (never reliably inside a
/// pull-down menu), and left alone while a text field is being typed in, so a label or an
/// address can still contain digits and brackets.
struct MarkerKeys: NSViewRepresentable {
    let timeline: TimelineModel

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.timeline = timeline
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) { view.timeline = timeline }

    enum Key: Equatable { case next, previous, again, type(Int), loopIn, loopOut, loop, clearLoop, clear, quantize, name,
                          copy, cut, paste, selectAll, delete }

    /// What a key press means, or nil to let it through. Layout-independent for [ and ]: their
    /// key positions (ANSI 33 and 30) count even where the layout puts other characters there.
    static func key(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Key? {
        // Delete / forward delete (fn-Delete), alone or with ⌘ as in the Finder.
        if keyCode == 51 || keyCode == 117,
           modifiers.intersection([.control, .option, .shift]).isEmpty {
            return .delete
        }
        // ⌘C / ⌘X / ⌘V / ⌘A act on markers (text fields keep their own: they're skipped above).
        if modifiers.contains(.command), modifiers.intersection([.control, .option, .shift]).isEmpty {
            switch characters?.lowercased() ?? "" {
            case "c": return .copy
            case "x": return .cut
            case "v": return .paste
            case "a": return .selectAll
            default: return nil
            }
        }
        guard modifiers.intersection([.command, .control, .option, .function]).isEmpty else { return nil }
        switch characters?.lowercased() ?? "" {
        case "]": return .next
        case "[": return .previous
        case "m": return .again
        case "q": return .quantize
        case "i": return .loopIn
        case "o": return .loopOut
        case "l": return modifiers.contains(.shift) ? .clearLoop : .loop
        case "\u{1b}": return .clear
        case let c where c.count == 1 && ("1"..."9").contains(c): return .type(Int(c)!)
        case "\r": return .name
        default:
            if keyCode == 36 || keyCode == 76 { return .name }   // Return, Enter
            if keyCode == 30 { return .next }
            if keyCode == 33 { return .previous }
            return nil
        }
    }

    final class Catcher: NSView {
        weak var timeline: TimelineModel?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !(window.firstResponder is NSText),
                      let timeline = self.timeline,
                      let key = MarkerKeys.key(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                                               modifiers: event.modifierFlags)
                else { return event }
                switch key {
                case .next: timeline.nextMarker()
                case .previous: timeline.previousMarker()
                case .again: if !event.isARepeat { timeline.dropMarker() }
                case .name:
                    guard timeline.selectedMarkerID != nil else { return event }
                    timeline.nameSelectedMarker()
                case .loopIn: if !event.isARepeat { timeline.setLoopIn() }
                case .loopOut: if !event.isARepeat { timeline.setLoopOut() }
                case .loop: if !event.isARepeat { timeline.toggleLoop() }
                case .clearLoop: if !event.isARepeat { timeline.clearLoop() }
                case .quantize: if !event.isARepeat { timeline.quantizeSelection() }
                case .copy: timeline.copyMarkers()
                case .cut: timeline.cutMarkers()
                case .paste: timeline.pasteMarkers()
                case .selectAll: timeline.selectSongMarkers()
                case .delete:
                    guard timeline.deleteSelectedMarkers() else { return event }
                case .clear:
                    guard timeline.selectedMarkerIDs.count > 1 else { return event }
                    timeline.clearMarkerSelection()
                case .type(let n):
                    let types = timeline.markerTypes.types
                    guard n - 1 < min(types.count, MarkerTypes.keyed) else { return event }
                    if !event.isARepeat { timeline.dropMarker(types[n - 1].id) }
                }
                return nil
            }
        }

        /// Never takes clicks; the monitor is removed when the view leaves its window.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
