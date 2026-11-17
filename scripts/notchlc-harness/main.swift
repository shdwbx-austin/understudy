// Transcodes one file through Adobe Media Encoder with the same driver Understudy uses
// (MediaEncoder + NotchLC), printing progress. Built by scripts/notchlc-harness.sh.
//
//   notchlc-harness <work folder> <source> <output> [--preset file.epr] [--cancel-after SECONDS]
//
// Without --preset it uses the NotchLC format's default preset, as the app does.
// NOTCHLC_KEEP_ENCODED=/path.mov keeps a copy of Media Encoder's own file, for looking at. Like the app,
// Media Encoder writes to a short temporary path, then NotchLCFinish copies that into
// <output> with the source's timecode.
import Foundation
import UnderstudyCore

setvbuf(stdout, nil, _IOLBF, 0)

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
let preset = option("--preset") ?? ""
let cancelAfter = option("--cancel-after").flatMap(Double.init)
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: notchlc-harness work source output [--preset epr] [--cancel-after s]\n".utf8))
    exit(2)
}
let work = URL(fileURLWithPath: args[0], isDirectory: true)
let source = URL(fileURLWithPath: args[1]).standardizedFileURL
let output = URL(fileURLWithPath: args[2]).standardizedFileURL

guard let app = MediaEncoder.newest() else {
    print("FAIL no Adobe Media Encoder in /Applications")
    exit(1)
}
let ame = MediaEncoder(app: app, workFolder: work)
let started = Date()
@MainActor func stamp(_ s: String) { print(String(format: "%6.1fs  %@", Date().timeIntervalSince(started), s)) }

do {
    stamp(ame.isWatching ? "\(ame.name) already watching" : "starting \(ame.name)")
    try ame.ensureWatching()
    let encoded = MediaEncoder.encodePath()
    let job = try ame.submit(source: source, output: encoded, preset: preset)
    var last = NotchLC.Status.starting
    var cancelled = false
    while true {
        try? await Task.sleep(nanoseconds: 250_000_000)
        let status = job.status
        if status != last { stamp("\(status)"); last = status }
        if status.isFinal { break }
        if let cancelAfter, !cancelled, case .encoding = status, Date().timeIntervalSince(started) > cancelAfter {
            job.cancel()
            cancelled = true
            stamp("cancel requested")
        }
        if Date().timeIntervalSince(started) > 15, !ame.isWatching {
            print("FAIL \(ame.name) quit or crashed")
            exit(1)
        }
        if Date().timeIntervalSince(started) > 1800 { print("FAIL timed out"); exit(1) }
    }
    ame.cleanUp(job)
    switch last {
    case .done:
        stamp("encoded, adding timecode")
        guard let file = MediaEncoder.produced(encoded) else { print("FAIL no file from Media Encoder"); exit(1) }
        if let keep = ProcessInfo.processInfo.environment["NOTCHLC_KEEP_ENCODED"] {
            try? FileManager.default.copyItem(at: file, to: URL(fileURLWithPath: keep))
        }
        let info = await NotchLCFinish.source(source)
        try await NotchLCFinish.finish(encoded: file, source: info, to: output)
        try? FileManager.default.removeItem(at: file)
        stamp("finished")
        print("OK \(output.path)")
        exit(0)
    case .stopped:
        if let file = MediaEncoder.produced(encoded) { try? FileManager.default.removeItem(at: file) }
        print("STOPPED")
        exit(cancelled ? 0 : 1)
    case .failed(let why): print("FAIL \(why)"); exit(1)
    default: exit(1)
    }
} catch {
    print("FAIL \(error.localizedDescription)")
    exit(1)
}
