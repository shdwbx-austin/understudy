import SwiftUI
import UnderstudyCore

/// Copy a take off the decks (FTP) into a folder on this Mac, e.g. in Dropbox. A sheet, so the
/// show screen stays calm; the footer shows progress while it runs.
struct BackupView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var backup: TakeBackup
    @Environment(\.dismiss) private var dismiss
    /// Its own choice of take: backing up never changes what's playing.
    @State private var take = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Back up a take").font(Theme.grotesk(26, .medium))
                Spacer()
                TextButton(title: "Done") { dismiss() }
            }
            .padding(.bottom, 20)

            SectionHead(index: 1, title: "Destination") {
                TextButton(title: model.settings.backupFolder == nil ? "Choose folder" : "Change") { model.chooseBackupFolder() }
            }
            HStack {
                Text(folderText)
                    .font(Theme.mono(11))
                    .foregroundStyle(model.settings.backupFolder == nil ? Theme.amber : Theme.paper)
                    .lineLimit(2)
                    .truncationMode(.head)
                Spacer()
                if backup.lastFolder != nil, !backup.isRunning {
                    TextButton(title: "Show in Finder", color: Theme.grey) { backup.revealFolder() }
                }
            }
            .padding(.vertical, 12)
            Text("Files go into <folder>/<date>/<deck name>/. A folder inside Dropbox syncs them.")
                .font(Theme.grotesk(12, .light)).foregroundStyle(Theme.grey)
                .padding(.bottom, 24)

            SectionHead(index: 2, title: "Take")
            HStack(alignment: .firstTextBaseline, spacing: Theme.gutter) {
                if model.mode == .record {
                    Text("Stop recording to back up. Copying off a deck while it records isn't safe.")
                        .font(Theme.grotesk(14, .light)).foregroundStyle(Theme.amber)
                } else if model.takes.isEmpty {
                    Text("No takes on the decks yet.").font(Theme.grotesk(14, .light)).foregroundStyle(Theme.grey)
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
                    .disabled(backup.isRunning)
                    Text("FROM \(model.activeDecks.count) DECK\(model.activeDecks.count == 1 ? "" : "S")")
                        .font(Theme.mono(10)).tracking(1.2).foregroundStyle(Theme.grey)
                }
                Spacer()
                if backup.isRunning {
                    TextButton(title: "Cancel", color: Theme.paper) { backup.cancel() }
                } else {
                    TextButton(title: "Back up", color: canStart ? Theme.paper : Theme.quiet) { model.backUpTake(take) }
                        .disabled(!canStart)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.vertical, 12)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(backup.jobs) { job in
                        JobRow(job: job)
                        Rule(color: Theme.rule.opacity(0.6))
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 820, height: 520, alignment: .topLeading)
        .background(Theme.ink)
        .foregroundStyle(Theme.paper)
        .preferredColorScheme(.dark)
        .onAppear { if !model.takes.indices.contains(take) { take = 0 } }
    }

    private var takeLabel: String {
        guard let t = model.takes.first(where: { $0.offset == take }) else { return "Choose a take" }
        return "\(t.offset == 0 ? "Latest — " : "")#\(t.clipID)  \(t.name)"
    }

    private var canStart: Bool {
        model.mode != .record && !model.takes.isEmpty && model.settings.backupFolder != nil && !model.activeDecks.isEmpty
    }

    private var folderText: String {
        guard let path = model.settings.backupFolder else { return "No folder chosen" }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}

private struct JobRow: View {
    let job: TakeBackup.Job

    var body: some View {
        HStack(alignment: .center, spacing: Theme.gutter) {
            Text(job.item.deckName)
                .font(Theme.grotesk(13, .medium))
                .frame(width: 110, alignment: .leading)
            Text(job.item.fileName)
                .font(Theme.mono(11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            ProgressBar(fraction: job.fraction ?? (job.state == .done || job.state == .skipped ? 1 : 0), color: barColor)
                .frame(width: 200)
            Text(sizeText)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.grey)
                .frame(width: 150, alignment: .trailing)
            Text(stateText)
                .font(Theme.mono(10))
                .tracking(1)
                .foregroundStyle(stateColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 210, alignment: .leading)
        }
        .padding(.vertical, 8)
        .help(job.destination.path)
    }

    private var sizeText: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        guard let total = job.total else { return job.copied > 0 ? f.string(fromByteCount: job.copied) : "" }
        return "\(f.string(fromByteCount: job.copied)) / \(f.string(fromByteCount: total))"
    }

    private var stateText: String {
        switch job.state {
        case .waiting: return "WAITING"
        case .finding: return "FINDING ON DECK"
        case .copying: return job.fraction.map { String(format: "COPYING %.0f%%", $0 * 100) } ?? "COPYING"
        case .done: return "BACKED UP"
        case .skipped: return "ALREADY BACKED UP"
        case .failed(let why): return why.uppercased()
        }
    }

    private var stateColor: Color {
        switch job.state {
        case .failed: return Theme.signal
        case .done, .skipped: return Theme.lock
        default: return Theme.paper
        }
    }

    private var barColor: Color {
        switch job.state {
        case .failed: return Theme.signal
        case .done, .skipped: return Theme.lock
        default: return Theme.paper
        }
    }
}

private struct ProgressBar: View {
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
