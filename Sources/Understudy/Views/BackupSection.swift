import SwiftUI
import UnderstudyCore

/// Copy a take off the decks (FTP) into a folder on this Mac, e.g. in Dropbox.
struct BackupSection: View {
    @EnvironmentObject private var model: AppModel
    let index: Int
    @ObservedObject var backup: TakeBackup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(index: index, title: "Backup") {
                HStack(spacing: 18) {
                    Text(folderText)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.quiet)
                        .lineLimit(1)
                        .truncationMode(.head)
                    TextButton(title: model.settings.backupFolder == nil ? "Choose folder" : "Change") {
                        model.chooseBackupFolder()
                    }
                    if backup.lastFolder != nil, !backup.isRunning {
                        TextButton(title: "Show") { backup.revealFolder() }
                    }
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: Theme.gutter) {
                if model.mode == .record {
                    Text("Stop recording to back up. Copying off a deck while it records isn't safe.")
                        .font(Theme.grotesk(13, .light))
                        .foregroundStyle(Theme.grey)
                } else if model.takes.isEmpty {
                    Text("No takes on the decks yet.")
                        .font(Theme.grotesk(13, .light))
                        .foregroundStyle(Theme.grey)
                } else {
                    Picker("", selection: $model.selectedTake) {
                        ForEach(model.takes) { take in
                            Text("\(take.offset == 0 ? "Latest — " : "")#\(take.clipID)  \(take.name)").tag(take.offset)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(backup.isRunning)
                    Text("FROM \(model.activeDecks.count) DECK\(model.activeDecks.count == 1 ? "" : "S")")
                        .font(Theme.mono(10))
                        .tracking(1)
                        .foregroundStyle(Theme.quiet)
                }
                Spacer()
                if backup.isRunning {
                    TextButton(title: "Cancel", color: Theme.amber) { backup.cancel() }
                } else {
                    TextButton(title: "Back up take", color: canStart ? Theme.paper : Theme.quiet) {
                        model.backUpSelectedTake()
                    }
                    .disabled(!canStart)
                }
            }
            .padding(.vertical, 12)

            ForEach(backup.jobs) { job in
                JobRow(job: job)
                Rule(color: Theme.rule.opacity(0.6))
            }
        }
    }

    private var canStart: Bool {
        model.mode != .record && !model.takes.isEmpty && model.settings.backupFolder != nil && !model.activeDecks.isEmpty
    }

    private var folderText: String {
        guard let path = model.settings.backupFolder else { return "NO FOLDER CHOSEN" }
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
                .lineLimit(1)
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
