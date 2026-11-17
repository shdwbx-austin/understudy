import SwiftUI
import UnderstudyCore

/// Export markers: which types and songs go, and where they land on grandMA3 (sequences, pages,
/// executors, timecode shows) and disguise (tracks by song name; notes, sections or CUE tags).
/// Saved with the project. A sheet, in the style of the backup sheet.
struct MarkerExportView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var timeline: TimelineModel
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable { case ma3 = "grandMA3", d3 = "disguise" }
    @State private var tab: Tab = .ma3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.gutter) {
                Text("Export markers").font(Theme.grotesk(26, .medium))
                HStack(spacing: 18) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Button { tab = t } label: {
                            Text(t.rawValue.uppercased())
                                .font(Theme.mono(11, bold: true)).tracking(1.4)
                                .foregroundStyle(tab == t ? Theme.paper : Theme.quiet)
                                .padding(.bottom, 4)
                                .overlay(alignment: .bottom) { Rectangle().fill(tab == t ? Theme.paper : .clear).frame(height: 1) }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 12)
                Spacer()
                TextButton(title: "Export CSV…", color: Theme.grey) { model.exportMarkersCSV() }
                    .disabled(timeline.markers.isEmpty)
                TextButton(title: "Done", color: Theme.lock) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 20)

            switch tab {
            case .ma3: MA3ExportPane(timeline: timeline)
            case .d3: D3ExportPane(timeline: timeline)
            }

            if let message = model.linkMessage {
                Rule().padding(.top, 14)
                HStack(spacing: 8) {
                    if model.linkBusy { ProgressView().controlSize(.small) }
                    Text(message).font(Theme.grotesk(12, .light)).foregroundStyle(Theme.grey).lineLimit(2)
                }
                .padding(.top, 10)
            }
        }
        .padding(28)
        .frame(width: 1180, height: 720, alignment: .topLeading)
        .background(Theme.ink)
        .foregroundStyle(Theme.paper)
        .preferredColorScheme(.dark)
    }
}

/// Presents the export sheet wherever the main window is.
struct MarkerExportSheet: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var timeline: TimelineModel

    func body(content: Content) -> some View {
        content.sheet(isPresented: $timeline.exportingMarkers) {
            MarkerExportView(timeline: timeline).environmentObject(model)
        }
    }
}

// MARK: - grandMA3

private struct MA3ExportPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var timeline: TimelineModel

    private var ma3: Binding<MA3ExportSettings> { $model.settings.markerExport.ma3 }
    private var s: MA3ExportSettings { model.settings.markerExport.ma3 }

    var body: some View {
        let plan = model.ma3Plan()
        HStack(alignment: .top, spacing: Theme.gutter * 1.5) {
            typesColumn.frame(width: 400)
            songsColumn(plan).frame(width: 300)
            optionsColumn(plan).frame(maxWidth: .infinity)
        }
    }

    // Types: include, executor, where the sequence comes from, merge or override.
    private var typesColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(index: 1, title: "Marker types") {
                HStack(spacing: 12) {
                    TextButton(title: "All", color: Theme.grey) { setAllTypes(true) }
                    TextButton(title: "None", color: Theme.grey) { setAllTypes(false) }
                }
            }
            ColumnLabels(labels: [("", 196), ("Exec", 52), ("Sequence", 70), ("Existing", 70)])
            ScrollView {
                VStack(spacing: 0) {
                    if s.sequences == .single {
                        TargetRow(dot: nil, name: "All markers", count: nil, include: nil, target: ma3.single,
                                  hasPages: s.pages != .none)
                        Rule(color: Theme.rule.opacity(0.6))
                    }
                    ForEach(timeline.markerTypes.types) { type in
                        TargetRow(dot: Color(hex: type.color), name: type.name, count: timeline.markerCount(type.id),
                                  include: includeBinding(type.id),
                                  target: s.sequences == .single ? nil : typeBinding(type.id), hasPages: s.pages != .none)
                        Rule(color: Theme.rule.opacity(0.6))
                    }
                }
            }
            Text(s.pages == .none
                 ? "Pick a page under Pages to assign executors."
                 : "Exec: the executor on the page. New: a sequence from the pool, assigned if the executor is empty. On exec: the sequence already there. Merge adds missing cues; Override backs the sequence up first.")
                .font(Theme.grotesk(11, .light)).foregroundStyle(Theme.grey)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }

    private func songsColumn(_ plan: MA3Plan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(index: 2, title: "Songs") {
                HStack(spacing: 12) {
                    TextButton(title: "All", color: Theme.grey) { setAllSongs(true) }
                    TextButton(title: "None", color: Theme.grey) { setAllSongs(false) }
                }
            }
            ColumnLabels(labels: [("", 196), ("Page", 52), ("TC", 40)])
            ScrollView {
                VStack(spacing: 0) {
                    if model.exportSongs.isEmpty {
                        Text("No songs on the set: every marker goes as one.")
                            .font(Theme.grotesk(13, .light)).foregroundStyle(Theme.grey).padding(.vertical, 10)
                    }
                    ForEach(model.exportSongs) { song in
                        HStack(spacing: 8) {
                            CheckBox(isOn: songInclude(song.id))
                            Text(song.name).font(Theme.grotesk(13)).lineLimit(1).truncationMode(.tail)
                                .foregroundStyle(s.song(song.id).include ? Theme.paper : Theme.quiet)
                                .frame(width: 168, alignment: .leading)
                            if s.pages == .perSong {
                                NumberField(value: songPage(song.id), placeholder: "\(s.page + song.index)")
                            } else {
                                Text(s.pages == .fixed ? "\(s.page)" : "–").font(Theme.mono(11)).foregroundStyle(Theme.quiet)
                                    .frame(width: 52, alignment: .leading)
                            }
                            Text(s.timecodes == .perSong ? "\(model.settings.ma3Timecode + song.index)" : "\(model.settings.ma3Timecode)")
                                .font(Theme.mono(11)).foregroundStyle(Theme.quiet).frame(width: 40, alignment: .leading)
                        }
                        .padding(.vertical, 6)
                        Rule(color: Theme.rule.opacity(0.6))
                    }
                }
            }
        }
    }

    private func optionsColumn(_ plan: MA3Plan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(index: 3, title: "Sequences, pages, timecode")
            VStack(alignment: .leading, spacing: 10) {
                OptionRow(label: "Sequences") {
                    ChoiceMenu(selection: ma3.sequences, options: MA3ExportSettings.Sequences.allCases, title: \.title)
                }
                OptionRow(label: "Pool start") {
                    NumberField(value: Binding(get: { model.settings.ma3Sequence }, set: { model.settings.ma3Sequence = max(1, $0) }), placeholder: "1001")
                    if s.sequences == .perSongAndType {
                        Label8(text: "Song offset")
                        NumberField(value: Binding(get: { s.songOffset }, set: { ma3.songOffset.wrappedValue = max(1, $0) }), placeholder: "20")
                    }
                }
                OptionRow(label: "Timecode") {
                    ChoiceMenu(selection: ma3.timecodes, options: MA3ExportSettings.Timecodes.allCases, title: \.title)
                    Label8(text: "From")
                    NumberField(value: Binding(get: { model.settings.ma3Timecode }, set: { model.settings.ma3Timecode = max(1, $0) }), placeholder: "101")
                }
                OptionRow(label: "Pages") {
                    ChoiceMenu(selection: ma3.pages, options: MA3ExportSettings.Pages.allCases, title: \.title)
                    if s.pages != .none {
                        Label8(text: s.pages == .fixed ? "Page" : "From")
                        NumberField(value: Binding(get: { s.page }, set: { ma3.page.wrappedValue = max(1, $0) }), placeholder: "1")
                    }
                }
                OptionRow(label: "Fire early") {
                    NumberField(value: Binding(get: { s.latencyFrames }, set: { ma3.latencyFrames.wrappedValue = max(0, $0) }), placeholder: "0")
                    Label8(text: "frames")
                }
            }
            .padding(.vertical, 12)

            SectionHead(index: 4, title: "What it makes")
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(plan.sequences.enumerated()), id: \.offset) { _, q in
                        Text(line(q)).font(Theme.mono(10.5)).foregroundStyle(Theme.paper).lineLimit(1).truncationMode(.middle)
                    }
                    ForEach(plan.timecodes, id: \.number) { t in
                        Text("Timecode \(t.number) “\(t.name)”: \(t.tracks.reduce(0) { $0 + $1.events.count }) Goto events on \(t.tracks.count) track\(t.tracks.count == 1 ? "" : "s")")
                            .font(Theme.mono(10.5)).foregroundStyle(Theme.grey).lineLimit(1).truncationMode(.middle)
                    }
                    ForEach(plan.warnings, id: \.self) { w in
                        Text(w).font(Theme.grotesk(12, .light)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            }
            Text("Adds to what's on the console: pages and executors are only used when empty, pool numbers and timecode shows only when Understudy made them. Clear the programmer first: cues are stored from it.")
                .font(Theme.grotesk(11, .light)).foregroundStyle(Theme.grey)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            HStack(spacing: Theme.gutter) {
                Spacer()
                TextButton(title: "Save plugin…", color: plan.markerCount > 0 ? Theme.paper : Theme.quiet) { model.exportMA3Plugin() }
                    .disabled(plan.markerCount == 0)
                TextButton(title: "Send to grandMA3", color: canSend(plan) ? Theme.lock : Theme.quiet) { model.deployMarkersToMA3() }
                    .disabled(!canSend(plan))
                    .help(model.settings.ma3Host.isEmpty ? "Set the console's IP in Settings › Show control" : "Send over OSC to \(model.settings.ma3Host)")
            }
        }
    }

    private func canSend(_ plan: MA3Plan) -> Bool { plan.markerCount > 0 && !model.settings.ma3Host.isEmpty && !model.linkBusy }

    private func line(_ q: MA3Plan.Sequence) -> String {
        let seq = q.source == .executor ? "Exec \(q.exec ?? 0)'s sequence (else \(q.pool))" : "Sequence \(q.pool)"
        let at = q.exec.map { e in " → " + q.pages.map { "\($0).\(e)" }.joined(separator: ", ") } ?? ""
        return "\(seq) “\(q.name)”: \(q.cues.count) cue\(q.cues.count == 1 ? "" : "s")\(at) · \(q.write.title.lowercased())"
    }

    // Bindings into the saved setup.
    private func includeBinding(_ kind: MarkerKind) -> Binding<Bool> {
        Binding(get: { s.target(kind).include }, set: { v in ma3.types.wrappedValue[kind.rawValue, default: .init()].include = v })
    }

    private func typeBinding(_ kind: MarkerKind) -> Binding<MA3ExportSettings.Target> {
        Binding(get: { s.target(kind) }, set: { ma3.types.wrappedValue[kind.rawValue] = $0 })
    }

    private func songInclude(_ id: UUID) -> Binding<Bool> {
        Binding(get: { s.song(id).include }, set: { v in ma3.songs.wrappedValue[id.uuidString, default: .init()].include = v })
    }

    private func songPage(_ id: UUID) -> Binding<Int?> {
        Binding(get: { s.song(id).page }, set: { v in ma3.songs.wrappedValue[id.uuidString, default: .init()].page = v })
    }

    private func setAllTypes(_ on: Bool) {
        for t in timeline.markerTypes.types { ma3.types.wrappedValue[t.id.rawValue, default: .init()].include = on }
    }

    private func setAllSongs(_ on: Bool) {
        for song in model.exportSongs { ma3.songs.wrappedValue[song.id.uuidString, default: .init()].include = on }
    }
}

/// A marker type (or "All markers"): include, exec, sequence source, merge or override.
private struct TargetRow: View {
    let dot: Color?
    let name: String
    let count: Int?
    /// nil: always included (the one-sequence row).
    let include: Binding<Bool>?
    /// nil: only the checkbox (one sequence: the exec is on its own row).
    let target: Binding<MA3ExportSettings.Target>?
    let hasPages: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let include { CheckBox(isOn: include) } else { Color.clear.frame(width: 14, height: 14) }
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            Text(name).font(Theme.grotesk(13)).lineLimit(1)
                .foregroundStyle(include?.wrappedValue == false ? Theme.quiet : Theme.paper)
            Spacer(minLength: 4)
            if let count { Text("\(count)").font(Theme.mono(10)).foregroundStyle(Theme.quiet) }
            Group {
                if let target {
                    NumberField(value: Binding(get: { target.wrappedValue.exec }, set: { target.wrappedValue.exec = $0 }),
                                placeholder: "–")
                        .disabled(!hasPages)
                    ChoiceMenu(selection: Binding(get: { target.wrappedValue.source }, set: { target.wrappedValue.source = $0 }),
                               options: MA3ExportSettings.Source.allCases, title: \.title)
                        .frame(width: 70, alignment: .leading)
                        .disabled(!hasPages || target.wrappedValue.exec == nil)
                    ChoiceMenu(selection: Binding(get: { target.wrappedValue.write }, set: { target.wrappedValue.write = $0 }),
                               options: MA3ExportSettings.Write.allCases, title: \.title)
                        .frame(width: 70, alignment: .leading)
                } else {
                    Color.clear.frame(width: 52 + 70 + 70 + 16, height: 1)
                }
            }
            .opacity(include?.wrappedValue == false ? 0.35 : 1)
        }
        .frame(height: 30)
    }
}

// MARK: - disguise

private struct D3ExportPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var timeline: TimelineModel
    @State private var tracks: [String]?
    @State private var problem: String?

    private var d3: Binding<D3ExportSettings> { $model.settings.markerExport.d3 }
    private var s: D3ExportSettings { model.settings.markerExport.d3 }

    var body: some View {
        let (rows, outside) = model.d3Rows()
        HStack(alignment: .top, spacing: Theme.gutter * 1.5) {
            typesColumn.frame(width: 330)
            songsColumn.frame(width: 420)
            optionsColumn(rows, outside).frame(maxWidth: .infinity)
        }
    }

    private var typesColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(index: 1, title: "Marker types")
            ColumnLabels(labels: [("", 180), ("Write as", 120)])
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(timeline.markerTypes.types) { type in
                        let place = s.placement(type.id, fallback: model.settings.d3Style)
                        HStack(spacing: 8) {
                            Circle().fill(Color(hex: type.color)).frame(width: 8, height: 8)
                            Text(type.name).font(Theme.grotesk(13)).lineLimit(1)
                                .foregroundStyle(place == .off ? Theme.quiet : Theme.paper)
                            Spacer(minLength: 4)
                            Text("\(timeline.markerCount(type.id))").font(Theme.mono(10)).foregroundStyle(Theme.quiet)
                            ChoiceMenu(selection: Binding(get: { place }, set: { d3.types.wrappedValue[type.id.rawValue] = $0 }),
                                       options: D3ExportSettings.Placement.allCases, title: \.title)
                                .frame(width: 120, alignment: .leading)
                        }
                        .frame(height: 30)
                        Rule(color: Theme.rule.opacity(0.6))
                    }
                }
            }
            Text("Notes and CUE tags never replace what's on the track: a note already at that beat is kept, and a CUE tag only goes where there's none. Sections only split.")
                .font(Theme.grotesk(11, .light)).foregroundStyle(Theme.grey)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }

    private var songsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(index: 2, title: s.target == .trackPerSong ? "Songs → tracks" : "Songs") {
                TextButton(title: "Fetch tracks", color: model.settings.d3Host.isEmpty ? Theme.quiet : Theme.grey) { fetch() }
                    .disabled(model.settings.d3Host.isEmpty)
            }
            ColumnLabels(labels: [("", 196), ("disguise track", 180)])
            ScrollView {
                VStack(spacing: 0) {
                    if model.exportSongs.isEmpty {
                        Text("No songs on the set: every marker goes on one track.")
                            .font(Theme.grotesk(13, .light)).foregroundStyle(Theme.grey).padding(.vertical, 10)
                    }
                    ForEach(model.exportSongs) { song in
                        songRow(song)
                        Rule(color: Theme.rule.opacity(0.6))
                    }
                }
            }
            if let problem {
                Text(problem).font(Theme.grotesk(11, .light)).foregroundStyle(Theme.amber).padding(.top, 8)
            } else if let tracks {
                Text("\(tracks.count) track\(tracks.count == 1 ? "" : "s") in Designer. Amber: no track by that name.")
                    .font(Theme.grotesk(11, .light)).foregroundStyle(Theme.grey).padding(.top, 8)
            }
        }
    }

    private func songRow(_ song: ExportSong) -> some View {
        let include = s.song(song.id).include
        let name = s.trackName(for: song)
        let missing = tracks.map { !$0.contains(name) } ?? false
        return HStack(spacing: 8) {
            CheckBox(isOn: Binding(get: { include }, set: { v in d3.songs.wrappedValue[song.id.uuidString, default: .init()].include = v }))
                .disabled(s.target == .single)
            Text(song.name).font(Theme.grotesk(13)).lineLimit(1)
                .foregroundStyle(include || s.target == .single ? Theme.paper : Theme.quiet)
                .frame(width: 168, alignment: .leading)
            if s.target == .trackPerSong {
                TextField("", text: Binding(get: { s.song(song.id).track ?? "" },
                                            set: { v in d3.songs.wrappedValue[song.id.uuidString, default: .init()].track = v.isEmpty ? nil : v }),
                          prompt: Text(song.name).foregroundColor(Theme.quiet))
                    .textFieldStyle(.plain).font(Theme.mono(11))
                    .foregroundStyle(missing && include ? Theme.amber : Theme.paper)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Theme.fill)
                    .frame(width: 180)
                if let tracks, !tracks.isEmpty {
                    Menu {
                        ForEach(tracks, id: \.self) { t in
                            Button(t) { d3.songs.wrappedValue[song.id.uuidString, default: .init()].track = t == song.name ? nil : t }
                        }
                    } label: { Text("▾").font(Theme.mono(10)) }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            } else {
                Text(model.settings.d3Track.isEmpty ? "selected track" : model.settings.d3Track)
                    .font(Theme.mono(11)).foregroundStyle(Theme.quiet)
            }
        }
        .padding(.vertical, 5)
    }

    private func optionsColumn(_ rows: [D3Row], _ outside: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(index: 3, title: "Tracks")
            VStack(alignment: .leading, spacing: 10) {
                OptionRow(label: "Write to") {
                    ChoiceMenu(selection: d3.target, options: D3ExportSettings.Target.allCases, title: \.title)
                }
                if s.target == .single {
                    OptionRow(label: "Track") {
                        TextField("", text: $model.settings.d3Track, prompt: Text("the selected track").foregroundColor(Theme.quiet))
                            .textFieldStyle(.plain).font(Theme.mono(11))
                            .padding(.horizontal, 6).padding(.vertical, 3).background(Theme.fill).frame(width: 180)
                    }
                    OptionRow(label: "Track start") {
                        TextField("", text: $model.settings.d3TrackStart)
                            .textFieldStyle(.plain).font(Theme.mono(11))
                            .padding(.horizontal, 6).padding(.vertical, 3).background(Theme.fill).frame(width: 110)
                    }
                }
            }
            .padding(.vertical, 12)
            Text(s.target == .trackPerSong
                 ? "Each song's markers go on the disguise track with its name (or the name you give it). Times follow the track's TC tags, else the track starts at the song's first frame."
                 : "Every marker goes on one track. Times follow its TC tags, else the track start above.")
                .font(Theme.grotesk(11, .light)).foregroundStyle(Theme.grey)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)

            SectionHead(index: 4, title: "What it writes")
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(summary(rows), id: \.track) { t in
                        Text("“\(t.track)”: \(t.counts)").font(Theme.mono(10.5)).lineLimit(1).truncationMode(.middle)
                    }
                    if outside > 0 {
                        Text("\(outside) marker\(outside == 1 ? " isn't" : "s aren't") on a song in the set: left out.")
                            .font(Theme.grotesk(12, .light)).foregroundStyle(Theme.amber)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            }
            HStack {
                Spacer()
                let can = !rows.isEmpty && !model.settings.d3Host.isEmpty && !model.linkBusy
                TextButton(title: "Send to disguise", color: can ? Theme.lock : Theme.quiet) { model.pushMarkersToD3() }
                    .disabled(!can)
                    .help(model.settings.d3Host.isEmpty ? "Set the Designer IP in Settings › Show control" : "Send to Designer at \(model.settings.d3Host)")
            }
        }
    }

    private struct TrackSummary { var track: String; var counts: String }

    private func summary(_ rows: [D3Row]) -> [TrackSummary] {
        var order: [String] = []
        var by: [String: [D3ExportSettings.Placement: Int]] = [:]
        for r in rows {
            let t = r.track ?? "selected track"
            if by[t] == nil { order.append(t) }
            by[t, default: [:]][r.placement, default: 0] += 1
        }
        return order.map { t in
            let parts = D3ExportSettings.Placement.allCases.compactMap { p in by[t]?[p].map { "\($0) \(p.title.lowercased())" } }
            return TrackSummary(track: t, counts: parts.joined(separator: ", "))
        }
    }

    private func fetch() {
        let host = model.settings.d3Host
        problem = nil
        Task { @MainActor in
            do {
                let list = try await D3Client.tracks(host: host)
                tracks = list
                if list.isEmpty { problem = "Designer has no tracks." }
            } catch {
                tracks = nil
                problem = error.localizedDescription
            }
        }
    }
}

// MARK: - Small parts

/// Uppercase column labels over a list, at fixed widths.
private struct ColumnLabels: View {
    let labels: [(String, CGFloat)]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, l in
                Label8(text: l.0).frame(width: l.1, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.vertical, 6)
    }
}

private struct OptionRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(Theme.grotesk(13, .light)).foregroundStyle(Theme.grey).frame(width: 90, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

/// A square check in the house style.
private struct CheckBox: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack {
                Rectangle().stroke(isOn ? Theme.paper : Theme.quiet, lineWidth: 1)
                if isOn { Rectangle().fill(Theme.paper).padding(3) }
            }
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A pop-up of choices, shown as plain text.
private struct ChoiceMenu<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let title: KeyPath<T, String>
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { o in Button(o[keyPath: title]) { selection = o } }
        } label: {
            Text(selection[keyPath: title]).font(Theme.grotesk(13))
                .foregroundStyle(enabled ? Theme.paper : Theme.quiet)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// A small number box; empty = nil.
private struct NumberField: View {
    @Binding var value: Int?
    var placeholder = ""
    @Environment(\.isEnabled) private var enabled

    init(value: Binding<Int?>, placeholder: String = "") {
        _value = value
        self.placeholder = placeholder
    }

    init(value: Binding<Int>, placeholder: String = "") {
        _value = Binding(get: { value.wrappedValue }, set: { if let v = $0 { value.wrappedValue = v } })
        self.placeholder = placeholder
    }

    var body: some View {
        TextField("", value: $value, format: .number.grouping(.never), prompt: Text(placeholder).foregroundColor(Theme.quiet))
            .textFieldStyle(.plain)
            .font(Theme.mono(11))
            .foregroundStyle(enabled ? Theme.paper : Theme.quiet)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Theme.fill)
            .frame(width: 52)
    }
}
