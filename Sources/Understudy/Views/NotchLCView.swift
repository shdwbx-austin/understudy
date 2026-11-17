import SwiftUI
import UnderstudyCore

/// Transcode a take to NotchLC test clips for a media server, through Adobe Media Encoder and
/// Notch's free NotchLC plugin. One action per take, plus where the files go.
struct NotchLCView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var transcoder: NotchLCTranscoder
    @Environment(\.dismiss) private var dismiss
    /// Its own choice of take: transcoding never changes what's playing.
    @State private var take = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Transcode to NotchLC").font(Theme.grotesk(26, .medium))
                Spacer()
                TextButton(title: "Done") { dismiss() }
            }
            .padding(.bottom, 20)

            SectionHead(index: 1, title: "Encoder") {
                if !transcoder.setup.ready {
                    TextButton(title: "Check again") { transcoder.refreshSetup() }
                }
            }
            encoder.padding(.vertical, 12)
            presetRow.padding(.bottom, 20)

            SectionHead(index: 2, title: "Destination") {
                if model.settings.notchLCFolder == nil {
                    TextButton(title: "Choose folder") { model.chooseNotchLCFolder() }
                } else {
                    TextButton(title: "Beside the media") { model.settings.notchLCFolder = nil }
                }
            }
            HStack {
                Text(destinationText)
                    .font(Theme.mono(11))
                    .lineLimit(2)
                    .truncationMode(.head)
                Spacer()
                if transcoder.lastFolder != nil, !transcoder.isRunning {
                    TextButton(title: "Show in Finder", color: Theme.grey) { transcoder.revealFolder() }
                }
            }
            .padding(.vertical, 12)
            .padding(.bottom, 12)

            SectionHead(index: 3, title: "Take")
            HStack(alignment: .firstTextBaseline, spacing: Theme.gutter) {
                if model.mode == .record {
                    Text("Stop recording to transcode: the files are still being written.")
                        .font(Theme.grotesk(14, .light)).foregroundStyle(Theme.amber)
                } else if model.takes.isEmpty {
                    Text("No takes yet.").font(Theme.grotesk(14, .light)).foregroundStyle(Theme.grey)
                } else {
                    Menu {
                        ForEach(model.takes) { t in
                            Button("\(t.offset == 0 ? "Latest — " : "")#\(t.clipID)  \(t.name)  \(t.duration.description)") { take = t.offset }
                        }
                    } label: {
                        Text(takeLabel).font(Theme.grotesk(16, .regular)).lineLimit(1).truncationMode(.middle)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 440, alignment: .leading)
                    .disabled(transcoder.isRunning)
                }
                Spacer()
                if transcoder.isRunning {
                    TextButton(title: "Cancel", color: Theme.paper) { transcoder.cancel() }
                } else {
                    TextButton(title: "Transcode", color: canStart ? Theme.paper : Theme.quiet) { model.transcodeTake(take) }
                        .disabled(!canStart)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.vertical, 12)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(transcoder.jobs) { job in
                        NotchLCJobRow(job: job)
                        Rule(color: Theme.rule.opacity(0.6))
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 820, height: 600, alignment: .topLeading)
        .background(Theme.ink)
        .foregroundStyle(Theme.paper)
        .preferredColorScheme(.dark)
        .onAppear {
            transcoder.refreshSetup()
            if !model.takes.indices.contains(take) { take = 0 }
        }
    }

    // MARK: Encoder

    @ViewBuilder private var encoder: some View {
        let setup = transcoder.setup
        if let name = setup.mediaEncoderName, setup.plugin {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(name) with Notch's NotchLC plugin").font(Theme.grotesk(14, .regular)).foregroundStyle(Theme.lock)
                Text("Understudy opens Media Encoder (or uses it if Understudy opened it) and leaves it open. Files are encoded one at a time.")
                    .font(Theme.grotesk(12, .light)).foregroundStyle(Theme.grey)
            }
        } else if setup.mediaEncoder == nil {
            VStack(alignment: .leading, spacing: 4) {
                Text("Adobe Media Encoder isn't installed.").font(Theme.grotesk(14, .regular)).foregroundStyle(Theme.amber)
                Text("NotchLC can only be encoded on a Mac through Adobe Media Encoder (Creative Cloud) with Notch's free NotchLC plugin.")
                    .font(Theme.grotesk(12, .light)).foregroundStyle(Theme.grey)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notch's NotchLC plugin isn't installed.").font(Theme.grotesk(14, .regular)).foregroundStyle(Theme.amber)
                Text("Get the free NotchLC plugin for Adobe (macOS installer) from Notch's downloads page and install it. Then quit Media Encoder if it's open, and check again.")
                    .font(Theme.grotesk(12, .light)).foregroundStyle(Theme.grey)
                    .fixedSize(horizontal: false, vertical: true)
                TextButton(title: "Open notch.one/downloads", color: Theme.paper) {
                    NSWorkspace.shared.open(NotchLCTranscoder.pluginDownloads)
                }
            }
        }
    }

    private var presetRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("PRESET").font(Theme.mono(10)).tracking(1.2).foregroundStyle(Theme.grey)
            Text(presetText).font(Theme.mono(11)).lineLimit(1).truncationMode(.head)
            Spacer()
            if model.settings.notchLCPreset != nil {
                TextButton(title: "Use defaults", color: Theme.grey) { model.settings.notchLCPreset = nil }
            }
            TextButton(title: "Choose…", color: Theme.grey) { model.chooseNotchLCPreset() }
        }
        .help("For a quality other than the plugin's default, save a preset in Media Encoder (Preset Browser → + → Create Encoding Preset, Format: NotchLC) and choose its .epr here.")
    }

    private var presetText: String {
        guard let path = model.settings.notchLCPreset else { return "NotchLC defaults (save a preset in Media Encoder to change quality)" }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Take and destination

    private var takeLabel: String {
        guard let t = model.takes.first(where: { $0.offset == take }) else { return "Choose a take" }
        return "\(t.offset == 0 ? "Latest — " : "")#\(t.clipID)  \(t.name)"
    }

    private var canStart: Bool {
        transcoder.setup.ready && model.mode != .record && !model.takes.isEmpty && !model.activeDecks.isEmpty
    }

    private var destinationText: String {
        if let path = model.settings.notchLCFolder {
            return (path as NSString).abbreviatingWithTildeInPath + "/<deck>/"
        }
        if let layout = model.projects.current {
            return (layout.objects(.video).path as NSString).abbreviatingWithTildeInPath + "/<deck>/NotchLC/"
        }
        return "A NotchLC folder beside each file (open a project to keep them with its media)"
    }
}

private struct NotchLCJobRow: View {
    let job: NotchLCTranscoder.Job

    var body: some View {
        HStack(alignment: .center, spacing: Theme.gutter) {
            Text(job.item.deckName)
                .font(Theme.grotesk(13, .medium))
                .frame(width: 110, alignment: .leading)
            Text(job.item.destination?.lastPathComponent ?? job.item.source?.lastPathComponent ?? "")
                .font(Theme.mono(11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            NotchLCProgress(fraction: job.fraction, color: color)
                .frame(width: 200)
            Text(stateText)
                .font(Theme.mono(10))
                .tracking(1)
                .foregroundStyle(color == Theme.paper ? Theme.paper : color)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
        }
        .padding(.vertical, 8)
        .help(job.item.destination?.path ?? "")
    }

    private var stateText: String {
        switch job.state {
        case .waiting: return "WAITING"
        case .starting: return "OPENING MEDIA ENCODER"
        case .encoding: return String(format: "ENCODING %.0f%%", job.fraction / 0.9 * 100)
        case .finishing: return "ADDING TIMECODE"
        case .done: return "DONE"
        case .skipped: return "ALREADY TRANSCODED"
        case .failed(let why): return why.uppercased()
        }
    }

    private var color: Color {
        switch job.state {
        case .failed: return Theme.signal
        case .done, .skipped: return Theme.lock
        default: return Theme.paper
        }
    }
}

private struct NotchLCProgress: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.rule)
                Rectangle().fill(color).frame(width: geo.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: 4)
    }
}
