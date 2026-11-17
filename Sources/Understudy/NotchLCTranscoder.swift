import AppKit
import Foundation
import UnderstudyCore

/// Transcodes a take's files to NotchLC test clips, one file at a time, through Adobe Media
/// Encoder and Notch's NotchLC plugin (see `MediaEncoder`, docs/NOTCHLC.md).
///
/// Each file: Media Encoder encodes it to a short temporary path, then `NotchLCFinish` copies that
/// into the destination with the source's timecode. Sources are only ever read. A file already at
/// the destination is skipped (files only appear there once complete).
@MainActor
final class NotchLCTranscoder: ObservableObject {
    struct Item: Sendable {
        var deckName: String
        /// nil: the take isn't on this Mac yet; `missing` says why.
        var source: URL?
        var destination: URL?
        var missing: String?
    }

    struct Job: Identifiable {
        enum State: Equatable {
            case waiting, starting, encoding, finishing, done, skipped
            case failed(String)
        }

        let id = UUID()
        let item: Item
        var state: State = .waiting
        /// 0…1 over the whole job (encode, then the copy that adds timecode).
        var fraction: Double = 0

        var isActive: Bool { [.waiting, .starting, .encoding, .finishing].contains(state) }
    }

    /// What's installed: Media Encoder and Notch's plugin.
    struct Setup: Equatable {
        var mediaEncoder: URL?
        var plugin: Bool

        var ready: Bool { mediaEncoder != nil && plugin }
        var mediaEncoderName: String? { mediaEncoder?.deletingPathExtension().lastPathComponent }
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var isRunning = false
    @Published private(set) var setup = Setup(mediaEncoder: nil, plugin: false)
    @Published private(set) var lastFolder: URL?

    private let flag = CancelFlag()
    private var current: MediaEncoder.Job?

    /// Where Notch's free plugin comes from.
    static let pluginDownloads = URL(string: "https://notch.one/downloads")!

    init() { refreshSetup() }

    func refreshSetup() {
        setup = Setup(mediaEncoder: MediaEncoder.newest(), plugin: MediaEncoder.pluginInstalled)
    }

    // MARK: Running

    func start(_ items: [Item], preset: String?) {
        refreshSetup()
        guard !isRunning, !items.isEmpty, let app = setup.mediaEncoder, setup.plugin else { return }
        jobs = items.map { item in
            var job = Job(item: item)
            if let missing = item.missing { job.state = .failed(missing) }
            return job
        }
        lastFolder = items.compactMap(\.destination).first?.deletingLastPathComponent()
        isRunning = true
        flag.reset()
        let ame = MediaEncoder(app: app, workFolder: TimelineModel.storeDirectory.appendingPathComponent("MediaEncoder", isDirectory: true))
        let ids = jobs.filter { $0.state == .waiting }.map(\.id)
        Task {
            for id in ids {
                guard !flag.isSet else { break }
                await run(id, ame: ame, preset: preset ?? "")
            }
            isRunning = false
            current = nil
        }
    }

    func cancel() {
        flag.set()
        current?.cancel()   // the watcher stops Media Encoder's queue
        for i in jobs.indices where jobs[i].isActive {
            jobs[i].state = .failed("Cancelled")
        }
    }

    func revealFolder() {
        guard let lastFolder else { return }
        if FileManager.default.fileExists(atPath: lastFolder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([lastFolder])
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].isActive else { return }
        change(&jobs[i])
    }

    private func run(_ id: UUID, ame: MediaEncoder, preset: String) async {
        guard let job = jobs.first(where: { $0.id == id }), let source = job.item.source, let destination = job.item.destination else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            update(id) { $0.state = .skipped; $0.fraction = 1 }
            return
        }
        guard fm.isReadableFile(atPath: source.path) else {
            update(id) { $0.state = .failed("Can't read \(source.lastPathComponent)") }
            return
        }

        // Media Encoder open and listening.
        update(id) { $0.state = .starting }
        let flag = self.flag
        do {
            try await Task.detached { try ame.ensureWatching(cancelled: { flag.isSet }) }.value
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
            return
        }
        guard !flag.isSet else { return }

        // Encode to a short temporary path (the plugin crashes Media Encoder on long ones).
        let encoded = MediaEncoder.encodePath()
        defer { if let file = MediaEncoder.produced(encoded) { try? fm.removeItem(at: file) } }
        let submitted: MediaEncoder.Job
        do {
            submitted = try ame.submit(source: source, output: encoded, preset: preset)
        } catch {
            update(id) { $0.state = .failed("Couldn't queue it: \(error.localizedDescription)") }
            return
        }
        current = submitted
        defer { ame.cleanUp(submitted) }
        update(id) { $0.state = .encoding }

        var lastBeat = Date()
        var cancelledAt: Date?
        var status = NotchLC.Status.starting
        while !status.isFinal {
            try? await Task.sleep(nanoseconds: 300_000_000)
            status = submitted.status
            if case .encoding(let f) = status { update(id) { $0.fraction = 0.9 * f } }
            if ame.isWatching { lastBeat = Date() }
            if Date().timeIntervalSince(lastBeat) > 15 {
                status = .failed("\(ame.name) quit or crashed")
            }
            if flag.isSet {
                // The watcher writes "stopped" within a second; don't wait for ever if it can't.
                cancelledAt = cancelledAt ?? Date()
                if let at = cancelledAt, Date().timeIntervalSince(at) > 5 { break }
            }
        }
        current = nil
        switch status {
        case .done:
            break
        case .stopped:
            update(id) { $0.state = .failed("Cancelled") }
            return
        case .failed(let why):
            update(id) { $0.state = .failed(why) }
            return
        default:
            return
        }
        guard !flag.isSet else { return }
        guard let file = MediaEncoder.produced(encoded) else {
            update(id) { $0.state = .failed("\(ame.name) finished but wrote no file") }
            return
        }

        // Copy into place with the source's timecode.
        update(id) { $0.state = .finishing; $0.fraction = 0.9 }
        do {
            try await Task.detached {
                let info = await NotchLCFinish.source(source)
                try await NotchLCFinish.finish(encoded: file, source: info, to: destination,
                                               progress: { f in Task { @MainActor in self.update(id) { $0.fraction = 0.9 + 0.1 * f } } },
                                               cancelled: { flag.isSet })
            }.value
            update(id) { $0.state = .done; $0.fraction = 1 }
        } catch is CancellationError {
            update(id) { $0.state = .failed("Cancelled") }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    // MARK: Folders

    /// Asks for a folder for transcodes; returns its path.
    static func chooseFolder(startingAt current: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Transcode here"
        panel.message = "Choose where NotchLC transcodes go. Each deck gets a folder inside it."
        panel.directoryURL = current.map { URL(fileURLWithPath: $0) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Asks for a Media Encoder preset (.epr) saved with the NotchLC format.
    static func choosePreset(startingAt current: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "epr") ?? .data]
        panel.prompt = "Use preset"
        panel.message = "Choose a NotchLC preset saved from Media Encoder (Preset Browser → Create Encoding Preset, Format: NotchLC)."
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Adobe/Adobe Media Encoder", isDirectory: true)
        panel.directoryURL = current.map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? documents
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

/// Set from the main actor, read from the background work.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
    func reset() { lock.lock(); value = false; lock.unlock() }
}
