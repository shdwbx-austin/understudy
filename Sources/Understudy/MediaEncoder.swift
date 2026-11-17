import Foundation
import UnderstudyCore

/// Adobe Media Encoder, driven by ExtendScript, with Notch's NotchLC plugin doing the encode.
///
/// Media Encoder runs a script given on its command line (`--console es.processFile`) only when
/// that command starts it; while it's open, a second one is ignored. So the first launch runs
/// `NotchLC.watcherScript`, which polls `inbox` every second, and each transcode is a job script
/// dropped there. Progress goes to the status file named in `current` (one transcode at a time),
/// and creating `cancel` stops Media Encoder's queue.
///
/// Foundation only, so scripts/notchlc-harness can compile it too.
struct MediaEncoder: Sendable {
    /// The app bundle, e.g. /Applications/Adobe Media Encoder 2027/Adobe Media Encoder 2027.app.
    let app: URL
    /// Understudy's folder for jobs (inbox, heartbeat, status files).
    let workFolder: URL

    var inbox: URL { workFolder.appendingPathComponent("inbox", isDirectory: true) }
    var heartbeat: URL { workFolder.appendingPathComponent("heartbeat") }
    var jobsFolder: URL { workFolder.appendingPathComponent("jobs", isDirectory: true) }
    var currentFile: URL { workFolder.appendingPathComponent("current") }
    var cancelFile: URL { workFolder.appendingPathComponent("cancel") }
    var binary: URL {
        app.appendingPathComponent("Contents/MacOS").appendingPathComponent(app.deletingPathExtension().lastPathComponent)
    }
    var name: String { app.deletingPathExtension().lastPathComponent }

    /// Where Notch's installer puts the plugin.
    static let pluginPath = "/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore/NotchLCPremierePlugin.bundle"
    static var pluginInstalled: Bool { FileManager.default.fileExists(atPath: pluginPath) }

    /// The export format the Notch plugin adds to Media Encoder.
    static let format = "NotchLC"

    /// The newest Media Encoder in /Applications (`Adobe Media Encoder 2027` beats `2026`).
    static func newest(in folder: String = "/Applications") -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        for name in names.filter({ $0.hasPrefix("Adobe Media Encoder") }).sorted().reversed() {
            let app = URL(fileURLWithPath: folder).appendingPathComponent(name).appendingPathComponent(name + ".app")
            if FileManager.default.fileExists(atPath: app.path) { return app }
        }
        return nil
    }

    /// The watcher touched its heartbeat in the last few seconds.
    var isWatching: Bool {
        guard let text = try? String(contentsOf: heartbeat, encoding: .utf8),
              let ms = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return abs(Date().timeIntervalSince1970 - ms / 1000) < NotchLC.heartbeatFresh
    }

    /// Media Encoder is open (started by anyone).
    var isRunning: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", binary.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    enum Failure: LocalizedError {
        case openWithoutWatcher(String)
        case didNotStart(String)

        var errorDescription: String? {
            switch self {
            case .openWithoutWatcher(let name):
                return "\(name) is open but wasn't started by Understudy. Quit it, then transcode again."
            case .didNotStart(let name):
                return "\(name) didn't start (or its scripting didn't run)."
            }
        }
    }

    /// Makes sure Media Encoder is open and running the watcher, starting it if needed.
    /// Blocks (up to `timeout`) while Media Encoder starts; call it off the main thread.
    func ensureWatching(timeout: TimeInterval = 180, cancelled: @Sendable () -> Bool = { false }) throws {
        if isWatching { return }
        if isRunning {
            // It may have just been started by us and not be ready yet: give it a moment.
            if waitForHeartbeat(10, cancelled: cancelled) { return }
            throw Failure.openWithoutWatcher(name)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        try? fm.removeItem(at: heartbeat)
        let script = workFolder.appendingPathComponent("watch.jsx")
        try NotchLC.watcherScript(inbox: inbox.path, heartbeat: heartbeat.path, cancelFile: cancelFile.path, currentFile: currentFile.path).write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = binary
        p.arguments = ["--console", "es.processFile", script.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        guard waitForHeartbeat(timeout, cancelled: cancelled) else { throw Failure.didNotStart(name) }
    }

    private func waitForHeartbeat(_ seconds: TimeInterval, cancelled: @Sendable () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !cancelled() {
            if isWatching { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return isWatching
    }

    /// One transcode's files.
    struct Job: Sendable {
        let id: String
        let statusFile: URL
        /// The watcher deletes it once it has stopped the queue.
        let cancelFile: URL

        var status: NotchLC.Status {
            NotchLC.status(fromFile: (try? String(contentsOf: statusFile, encoding: .utf8)) ?? "")
        }

        /// Stops Media Encoder's queue (and so this encode).
        func cancel() { FileManager.default.createFile(atPath: cancelFile.path, contents: nil) }
    }

    /// Drops a job for `source` into the inbox. The watcher picks it up within a second.
    /// One at a time: the previous job must have finished.
    func submit(source: URL, output: URL, preset: String = "") throws -> Job {
        let fm = FileManager.default
        try fm.createDirectory(at: jobsFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let job = Job(id: id, statusFile: jobsFolder.appendingPathComponent("\(id).status"), cancelFile: cancelFile)
        fm.createFile(atPath: job.statusFile.path, contents: nil)
        try? fm.removeItem(at: cancelFile)   // an old cancel would stop this job
        try job.statusFile.path.write(to: currentFile, atomically: true, encoding: .utf8)
        let text = NotchLC.script(source: source.path, output: output.path, format: preset.isEmpty ? Self.format : "",
                                  preset: preset, statusFile: job.statusFile.path, currentFile: currentFile.path)
        // Written beside, then renamed in, so the watcher never runs half a file.
        let temp = inbox.appendingPathComponent("\(id).tmp")
        try text.write(to: temp, atomically: true, encoding: .utf8)
        try fm.moveItem(at: temp, to: inbox.appendingPathComponent("\(id).jsx"))
        return job
    }

    /// Where Media Encoder should write an encode: a short path in the temporary folder. Notch's
    /// plugin (1.4.3) crashes Media Encoder when the output path is long (~240 characters).
    static func encodePath() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("understudy-nlc", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(String(UUID().uuidString.prefix(8)) + ".mov")
    }

    /// The file Media Encoder actually wrote for `expected`: the same path, or the same name with
    /// the extension its format uses (an H.264 preset writes `.mp4` whatever it was asked for).
    static func produced(_ expected: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: expected.path) { return expected }
        let stem = expected.deletingPathExtension().lastPathComponent
        let dir = expected.deletingLastPathComponent()
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.first { ($0 as NSString).deletingPathExtension == stem }.map { dir.appendingPathComponent($0) }
    }

    /// Asks the watching Media Encoder to quit (a clean quit; killing it brings up Adobe's crash
    /// reporter). Only for test harnesses: Understudy leaves Media Encoder open for the user.
    func quit() throws {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let temp = inbox.appendingPathComponent("quit.tmp")
        try "app.scheduleTask(\"app.quit()\", 500, false);".write(to: temp, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: inbox.appendingPathComponent("quit.jsx"))
        try FileManager.default.moveItem(at: temp, to: inbox.appendingPathComponent("quit.jsx"))
    }

    /// Removes a finished job's files.
    func cleanUp(_ job: Job) {
        try? FileManager.default.removeItem(at: currentFile)
        try? FileManager.default.removeItem(at: job.statusFile)
    }
}
