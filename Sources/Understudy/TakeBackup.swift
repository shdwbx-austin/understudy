import AppKit
import Foundation
import UnderstudyCore

/// Copies a take's clips off the HyperDecks over FTP into a folder on this Mac (e.g. in Dropbox,
/// which then syncs them).
///
/// HyperDecks serve their media by FTP on port 21 with no login. For each deck, the clip file is
/// found by walking the deck's folders (media slots, cache, USB), then downloaded with the system
/// `curl` into `<folder>/<date>/<deck name>/`. Decks copy in parallel, one file each. A file
/// already there at full size is skipped; an interrupted copy resumes.
@MainActor
final class TakeBackup: ObservableObject {
    struct Item: Sendable {
        var deckName: String
        var host: String
        var fileName: String
    }

    struct Job: Identifiable {
        enum State: Equatable {
            case waiting, finding, copying, done, skipped
            case failed(String)
        }

        let id = UUID()
        let item: Item
        var destination: URL
        var total: Int64?
        var copied: Int64 = 0
        var state: State = .waiting

        var fraction: Double? {
            guard let total, total > 0 else { return nil }
            return min(1, Double(copied) / Double(total))
        }
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastFolder: URL?

    private var processes: [ProcessBox] = []
    private var cancelled = false

    /// FTP port; 21 on HyperDecks. Overridable for testing (`defaults write … understudy.ftpPort`).
    static var port: Int {
        let p = UserDefaults.standard.integer(forKey: "understudy.ftpPort")
        return p > 0 ? p : 21
    }

    // MARK: Running

    func start(_ items: [Item], into folder: URL, date: Date = Date()) {
        guard !isRunning, !items.isEmpty else { return }
        let day = date.formatted(.iso8601.year().month().day())
        let dayFolder = folder.appendingPathComponent(day, isDirectory: true)
        lastFolder = dayFolder
        jobs = items.map { item in
            Job(item: item, destination: dayFolder
                .appendingPathComponent(FTPPaths.safeFolderName(item.deckName), isDirectory: true)
                .appendingPathComponent(item.fileName))
        }
        isRunning = true
        cancelled = false
        let ids = jobs.map(\.id)
        Task {
            await withTaskGroup(of: Void.self) { group in
                for id in ids { group.addTask { await self.run(id) } }
            }
            self.isRunning = false
            self.processes.removeAll()
        }
    }

    func cancel() {
        cancelled = true
        // Only a launched process can be terminated (terminate() on one that hasn't started
        // raises and kills the app); ones not yet launched see `cancelled` and never start.
        processes.forEach { $0.cancel() }
        for i in jobs.indices where [.waiting, .finding, .copying].contains(jobs[i].state) {
            jobs[i].state = .failed("Cancelled")
        }
    }

    func revealFolder() {
        guard let lastFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastFolder])
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    private func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    private func run(_ id: UUID) async {
        guard let job = job(id), !cancelled else { return }
        let host = job.item.host
        let port = Self.port

        update(id) { $0.state = .finding }
        guard let path = await find(job.item.fileName, on: host, port: port) else {
            if !cancelled { update(id) { $0.state = .failed("Not found on the deck by FTP") } }
            return
        }
        let url = FTPPaths.url(host: host, port: port, path: path)

        let headers = await curl(["-sI", "--fail", "--connect-timeout", "5", "--max-time", "20", url])
        let total = headers.status == 0 ? FTPPaths.contentLength(fromHeaders: headers.output) : nil
        update(id) { $0.total = total }

        let fm = FileManager.default
        let destination = job.destination
        let part = destination.appendingPathExtension("part")
        if let total, let size = Self.size(of: destination), size == total {
            update(id) { $0.copied = total; $0.state = .skipped }
            return
        }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            update(id) { $0.state = .failed("Can't create folder: \(error.localizedDescription)") }
            return
        }

        update(id) { $0.state = .copying }
        let progress = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                // The part file is renamed when the copy ends; don't read it after that.
                guard !Task.isCancelled else { break }
                let size = Self.size(of: part) ?? 0
                self?.update(id) { $0.copied = size }
            }
        }
        // A copy that stalls (deck gone mid-transfer) gives up after 20 s without data instead of hanging.
        var args = ["-s", "--fail", "--connect-timeout", "5", "--speed-limit", "1", "--speed-time", "20",
                    "--ftp-method", "singlecwd", "-o", part.path, url]
        if let total, let have = Self.size(of: part), have > 0, have < total {
            args.insert(contentsOf: ["-C", "-"], at: 0)   // resume an interrupted copy
        } else {
            try? fm.removeItem(at: part)
        }
        let download = await curl(args)
        progress.cancel()

        if cancelled { return }
        let got = Self.size(of: part) ?? 0
        guard download.status == 0, total.map({ got == $0 }) ?? (got > 0) else {
            update(id) { $0.copied = got; $0.state = .failed("Copy stopped (curl \(download.status))") }
            return
        }
        do {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: part, to: destination)
            update(id) { $0.copied = got; $0.state = .done }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    // MARK: Finding a clip

    /// Walks the deck's folders (breadth first, three levels) for `fileName`.
    private func find(_ fileName: String, on host: String, port: Int) async -> [String]? {
        var queue: [[String]] = [[]]
        var listed = 0
        while !queue.isEmpty, listed < 40, !cancelled {
            let dir = queue.removeFirst()
            let result = await curl(["-s", "--fail", "--connect-timeout", "5", "--max-time", "20", "--list-only",
                                     FTPPaths.url(host: host, port: port, path: dir, directory: true)])
            listed += 1
            guard result.status == 0 else { continue }
            let names = FTPPaths.names(fromListing: result.output)
            if names.contains(fileName) { return dir + [fileName] }
            guard dir.count < 3 else { continue }
            for name in names where !Self.looksLikeFile(name) {
                queue.append(dir + [name])
            }
        }
        return nil
    }

    /// Media files have an extension; folders (slot numbers, drive names) usually don't.
    private static func looksLikeFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        return (2...4).contains(ext.count)
    }

    nonisolated private static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    // MARK: curl

    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var cancelled = false

        /// Starts the process unless it was cancelled first.
        func launch() throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            try process.run()
            return true
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }

    /// Runs /usr/bin/curl; returns its exit status and standard output.
    private func curl(_ args: [String]) async -> (status: Int32, output: String) {
        let box = ProcessBox()
        box.process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        box.process.arguments = args
        let out = Pipe()
        box.process.standardOutput = out
        box.process.standardError = FileHandle.nullDevice
        processes.append(box)
        defer { processes.removeAll { $0 === box } }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    guard try box.launch() else {
                        continuation.resume(returning: (-1, ""))
                        return
                    }
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    box.process.waitUntilExit()
                    continuation.resume(returning: (box.process.terminationStatus, String(decoding: data, as: UTF8.self)))
                } catch {
                    continuation.resume(returning: (-1, ""))
                }
            }
        }
    }

    // MARK: Folder

    /// A likely Dropbox folder in the home folder, to start the folder picker in.
    static func dropboxGuess() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = ((try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            + ((try? FileManager.default.contentsOfDirectory(
                at: home.appendingPathComponent("Library/CloudStorage"), includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
        return candidates.first { $0.lastPathComponent.localizedCaseInsensitiveContains("dropbox") }
    }

    /// Asks for the backup folder; returns its path.
    static func chooseFolder(startingAt current: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Back up here"
        panel.message = "Choose where take backups go. A folder inside Dropbox syncs them."
        panel.directoryURL = current.map { URL(fileURLWithPath: $0) } ?? dropboxGuess()
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
