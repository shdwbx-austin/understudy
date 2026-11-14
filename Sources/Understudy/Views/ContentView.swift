import SwiftUI
import UnderstudyCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header()
            Rule()
            ModeBar()
            if model.mode == .playback { TakeBar() }
            SectionTitle(text: "Decks")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(model.decks) { deck in
                    DeckCard(deck: deck, config: $model.settings.decks[deck.id])
                }
            }
            Spacer(minLength: 0)
            Footer()
        }
        // House format: wide left margin, tight right.
        .padding(.leading, 40)
        .padding(.trailing, 20)
        .padding(.vertical, 22)
        .frame(minWidth: 940, minHeight: 700, alignment: .topLeading)
        .background(Theme.background)
        .foregroundStyle(Theme.paper)
        .preferredColorScheme(.dark)
    }
}

private struct Header: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Understudy")
                    .font(Theme.display(30, weight: .semibold))
                Text("Stands in for the cameras between run-throughs")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(model.ltcText)
                    .font(Theme.mono(46, bold: true))
                    .monospacedDigit()
                    .foregroundStyle(model.ltcRolling ? (model.ltcFreewheeling ? Theme.caution : Theme.paper) : Theme.dim)
                HStack(spacing: 8) {
                    StatusDot(color: clockColor)
                    Text(clockState)
                        .foregroundStyle(model.ltcFreewheeling ? Theme.caution : Theme.paper)
                    Text("·").foregroundStyle(Theme.dim)
                    Text(model.ltcInfo)
                    Text("·").foregroundStyle(Theme.dim)
                    Text(model.rateLabel)
                }
                .font(Theme.mono(11))
                if let warning = model.ltcWarning {
                    Text(warning).font(Theme.mono(11)).foregroundStyle(Theme.caution)
                }
            }
        }
    }
}

extension Header {
    private var clockState: String {
        if !model.ltcRolling { return "STOPPED" }
        return model.ltcFreewheeling ? "FREEWHEEL · NO LTC" : "ROLLING"
    }

    private var clockColor: Color {
        if !model.ltcRolling { return Theme.dim }
        return model.ltcFreewheeling ? Theme.caution : Theme.live
    }
}

private struct ModeBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let continuous = model.settings.recordMode == .continuous
        HStack(spacing: 12) {
            ModeButton(title: "STOP", detail: "Decks idle · live feed passes through", key: "⌘1",
                       tint: Theme.paper, active: model.mode == .stop) { model.setMode(.stop) }
            ModeButton(title: continuous ? "REC" : "REC ARM",
                       detail: continuous ? "Decks record until STOP · show code is logged" : "Decks record whenever show code runs",
                       key: "⌘2", tint: Theme.record, active: model.mode == .record) { model.setMode(.record) }
            ModeButton(title: "PLAY TC", detail: "Decks chase show LTC from the selected take", key: "⌘3",
                       tint: Theme.live, active: model.mode == .playback) { model.setMode(.playback) }
        }
    }
}

private struct ModeButton: View {
    let title: String
    let detail: String
    let key: String
    let tint: Color
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(Theme.mono(20, bold: true))
                    Spacer()
                    Text(key).font(Theme.mono(11)).opacity(0.6)
                }
                Text(detail).font(Theme.mono(11)).opacity(0.75)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(active ? Color.black : tint)
            .background(active ? tint : Theme.panel)
            .overlay(Rectangle().stroke(active ? tint : Theme.rule, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TakeBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Text("TAKE").font(Theme.mono(11, bold: true)).foregroundStyle(Theme.dim)
            if model.takes.isEmpty {
                Text("No clips on the decks yet").font(Theme.mono(12)).foregroundStyle(Theme.dim)
            } else {
                Picker("", selection: $model.selectedTake) {
                    ForEach(model.takes) { take in
                        Text(label(for: take)).tag(take.offset)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 520)
            }
            Toggle("Follow latest", isOn: $model.settings.followLatestTake)
                .toggleStyle(.checkbox)
                .font(Theme.mono(11))
            Spacer()
            Button("Refresh") { model.refreshTakes() }
                .font(Theme.mono(11))
        }
    }

    private func label(for take: Take) -> String {
        let latest = take.offset == 0 ? "LATEST · " : ""
        let sync: String
        switch take.logged {
        case true?: sync = "SHOW CODE LOGGED"
        case false?: sync = "NO SHOW CODE LOGGED"
        case nil: sync = "CLIP TC"
        }
        return "\(latest)#\(take.clipID)  +\(take.duration.description)  \(take.name)  · \(sync)"
    }
}

private struct Footer: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rule()
            HStack {
                if let error = model.audioError {
                    Text(error).foregroundStyle(Theme.caution)
                } else {
                    let name = model.audioDevices.first { $0.uid == model.settings.audioDeviceUID }?.name ?? "System default input"
                    let channel = model.settings.audioChannel
                    let channelName = model.inputChannelNames.indices.contains(channel) ? model.inputChannelNames[channel] : ""
                    let db = model.inputLevels.indices.contains(channel) ? model.inputLevels[channel] : -60
                    Text("LTC IN  \(name) · ch \(channel + 1)\(channelName.isEmpty ? "" : " \(channelName)")")
                        .foregroundStyle(Theme.dim)
                    LevelMeter(db: db).frame(width: 120)
                    Text(LevelMeter.label(db)).foregroundStyle(Theme.dim).frame(width: 48, alignment: .trailing)
                }
                Spacer()
                Text("⌘, settings").foregroundStyle(Theme.dim)
            }
            .font(Theme.mono(11))
        }
    }
}
