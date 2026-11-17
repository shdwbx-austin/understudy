// Records from synthetic sources with the Understudy recorder's engine and checks the files:
//  1. NDI loopback: sends a 29.97 test pattern over NDI, receives it and records ~10 s (H.264).
//  2. A generated frame source (no NDI) for ~3 s in ProRes 422 Proxy.
//  3. The recorder as a deck slot through DeckController: arm, log show code, stop, clip list,
//     take map; then record-while-code-runs.
// Each file is opened with AVFoundation and checked for frame count, length and the timecode
// stamped on its first frame. Run with scripts/recorder-harness.sh (never touches the real store).
@preconcurrency import AVFoundation
import Foundation
import UnderstudyCore

setvbuf(stdout, nil, _IONBF, 0)
guard let store = ProcessInfo.processInfo.environment["UNDERSTUDY_STORE"], !store.isEmpty else {
    print("Set UNDERSTUDY_STORE to a temp folder first."); exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : store, isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let seconds = Double(ProcessInfo.processInfo.environment["HARNESS_SECONDS"] ?? "") ?? 10

final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

func wait(_ timeout: Double, until done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if done() { return true }; Thread.sleep(forTimeInterval: 0.05) }
    return done()
}

struct Check { let name: String; let ok: Bool; let detail: String }
var checks: [Check] = []
func check(_ name: String, _ ok: Bool, _ detail: String) {
    checks.append(Check(name: name, ok: ok, detail: detail))
    print("\(ok ? "PASS" : "FAIL")  \(name): \(detail)")
}

/// Records one take from `source` and returns it.
func record(_ source: RecorderSource, codec: RecorderCodec, seconds: Double, startTC: Timecode, rate: FrameRate, file: String) -> RecorderTake? {
    let recorder = InternalRecorder(deckName: "Harness")
    let status = Box(InternalRecorder.Status())
    let finished = Box<Result<RecorderTake, RecorderError>?>(nil)
    let lock = NSLock()
    recorder.onStatus = { s in lock.lock(); status.value = s; lock.unlock() }
    recorder.onTakeFinished = { r in lock.lock(); finished.value = r; lock.unlock() }
    func snap() -> InternalRecorder.Status { lock.lock(); defer { lock.unlock() }; return status.value }
    recorder.open(source, dropFrame: rate.isDropFrame, folder: out)
    guard wait(15, until: { snap().videoFormat != nil }) else {
        print("No picture from \(source.label): \(snap().state)"); return nil
    }
    print("Source live: \(snap().signal ?? "?") (\(snap().videoFormat ?? "?"))")
    let url = out.appendingPathComponent(file)
    try? FileManager.default.removeItem(at: url)
    let startSeconds = Double(startTC.frameIndex(at: rate)) / rate.exact
    recorder.startTake(.init(url: url, takeID: 1, codec: codec, startSeconds: startSeconds, startHost: HostClock.now(),
                             timecodeAtVideoRate: true, dropFrame: rate.isDropFrame))
    let began = Date()
    var lastReport = 0
    while Date().timeIntervalSince(began) < seconds {
        Thread.sleep(forTimeInterval: 0.25)
        let s = snap()
        let t = Int(Date().timeIntervalSince(began))
        if t != lastReport {
            lastReport = t
            print(String(format: "  %2ds  tc %@  dropped %d  skipped %d  %@  warnings: %@", t, s.timecode?.display(dropFrame: rate.isDropFrame) ?? "--",
                         s.health.droppedFrames, s.health.skippedFrames, RecorderHealth.rateText(s.health.bytesPerSecond),
                         s.health.warnings.map(\.text).joined(separator: ", ")))
        }
    }
    let pos = recorder.currentPosition()
    print("  position at stop: \(pos.map { "\($0.timecode.display(dropFrame: rate.isDropFrame))" } ?? "none")")
    recorder.stopTake()
    guard wait(20, until: { lock.lock(); defer { lock.unlock() }; return finished.value != nil }) else { print("Take never finished"); return nil }
    recorder.close()
    lock.lock(); let result = finished.value!; lock.unlock()
    switch result {
    case .failure(let e): print("Take failed: \(e.message)"); return nil
    case .success(let take): return take
    }
}

/// Opens the file and checks it against the take.
func verify(_ take: RecorderTake, expectStart: Timecode, rate: FrameRate, seconds: Double, label: String, expectDropped: Int = 0) async {
    let asset = AVURLAsset(url: URL(fileURLWithPath: take.path))
    do {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let tcTracks = try await asset.loadTracks(withMediaType: .timecode)
        guard let v = videoTracks.first else { check("\(label) video track", false, "none"); return }
        let fps = try await v.load(.nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        // Count video samples.
        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderTrackOutput(track: v, outputSettings: nil)
        reader.add(vOut)
        var tcOut: AVAssetReaderTrackOutput?
        if let t = tcTracks.first { let o = AVAssetReaderTrackOutput(track: t, outputSettings: nil); reader.add(o); tcOut = o }
        reader.startReading()
        var frames = 0
        while let s = vOut.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(s) }
        var firstTC: Int32?
        var tcSamples = 0
        if let tcOut {
            while let s = tcOut.copyNextSampleBuffer() {
                tcSamples += 1
                if firstTC == nil, let block = CMSampleBufferGetDataBuffer(s) {
                    var v: Int32 = 0
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &v)
                    firstTC = Int32(bigEndian: v)
                }
            }
        }
        let codec = try await v.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) }
        let codecText = codec.map { c in String(bytes: [24, 16, 8, 0].map { UInt8((c >> $0) & 0xff) }, encoding: .ascii) ?? "?" } ?? "?"
        let tcDuration = try await tcTracks.first?.load(.timeRange).duration.seconds
        let expectedFrames = Int((seconds * rate.exact).rounded())
        print("  \(label): \(frames) frames, \(String(format: "%.3f", duration)) s, nominal \(fps) fps, codec \(codecText), tmcd samples \(tcSamples), tmcd length \(tcDuration.map { String(format: "%.3f", $0) } ?? "-") s")
        check("\(label) codec", codecText == take.codec.fourCC, codecText)
        check("\(label) frame count", frames == take.frames && abs(frames - expectedFrames) <= Int(rate.exact * 0.5),
              "\(frames) in file, take says \(take.frames), ~\(expectedFrames) expected for \(seconds) s")
        check("\(label) length", abs(duration - Double(frames) / rate.exact) < 0.01,
              String(format: "%.3f s for %d frames at %@", duration, frames, rate.rawValue))
        check("\(label) frame rate", abs(Double(fps) - rate.exact) < 0.05, "\(fps)")
        guard let firstTC else { check("\(label) timecode track", false, "missing"); return }
        let tc = Timecode(frameIndex: Int(firstTC), rate: rate)
        check("\(label) timecode = take start", Int(firstTC) == take.startFrame,
              "file \(tc.display(dropFrame: rate.isDropFrame)), take \(take.clip.start.display(dropFrame: rate.isDropFrame))")
        let late = Int(firstTC) - expectStart.frameIndex(at: rate)
        check("\(label) timecode = code asked for at REC", late >= 0 && late <= 3,
              "asked \(expectStart.display(dropFrame: rate.isDropFrame)) at REC, first frame \(tc.display(dropFrame: rate.isDropFrame)) (\(late) frames later: time to first frame)")
        check("\(label) timecode covers the file", abs((tcDuration ?? 0) - duration) < 0.01,
              String(format: "tmcd %.3f s vs video %.3f s", tcDuration ?? 0, duration))
        check("\(label) dropped frames", take.droppedFrames == expectDropped, "\(take.droppedFrames)")
    } catch {
        check("\(label) readable", false, error.localizedDescription)
    }
}

let rate = FrameRate.fps29_97DF
let start = Timecode("01:00:00;00")!

// 1. NDI loopback.
var ndiPassed = false
if NDILibrary.shared.isAvailable, let sender = NDISender(name: "Understudy Harness Bars") {
    print("NDI: \(NDILibrary.shared.path ?? "?")")
    let pattern = NDITestPattern(title: "Harness", note: "NDI loopback for the recorder harness")
    let sendQueue = DispatchQueue(label: "harness.send", qos: .userInteractive)
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: sendQueue)
    timer.schedule(deadline: .now(), repeating: 1 / rate.exact, leeway: .milliseconds(1))
    timer.setEventHandler { if let f = pattern.frame() { sender.send(f, fps: rate.exact) } }
    timer.resume()
    var name: String?
    _ = wait(10) { name = NDIFinder.shared.currentSources(wait: 0.5).first { $0.contains("Understudy Harness Bars") }; return name != nil }
    if let name {
        print("Found NDI source: \(name)")
        if let take = record(RecorderSource(kind: .ndi, id: name, name: name), codec: .h264, seconds: seconds,
                             startTC: start, rate: rate, file: "Harness NDI_0001.mov") {
            await verify(take, expectStart: start, rate: rate, seconds: seconds, label: "NDI H.264")
            ndiPassed = true
        } else { check("NDI take", false, "no take") }
    } else { check("NDI source found", false, "the harness sender never showed up") }
    timer.cancel()
} else {
    check("NDI library", false, "set UNDERSTUDY_LIBNDI to libndi.dylib")
}

// 2. Generated frames, ProRes Proxy.
let genSeconds = 3.0
if let take = record(.testPattern, codec: .proResProxy, seconds: genSeconds, startTC: Timecode("10:59:58;00")!, rate: .fps29_97DF,
                     file: "Harness Bars_0001.mov") {
    await verify(take, expectStart: Timecode("10:59:58;00")!, rate: .fps29_97DF, seconds: genSeconds, label: "Generated ProRes Proxy")
} else { check("Generated take", false, "no take") }

// 3. The recorder as a deck (DeckController), continuous and record-while-code-runs.
await deckPathChecks(out: out)

// 4. A gap in the source: 60 frames at 25 fps with 5 missing. The file must stay 25 fps
// constant, with the previous picture held in the empty slots and the drop counted.
do {
    let url = out.appendingPathComponent("Harness Gap_0001.mov")
    try? FileManager.default.removeItem(at: url)
    let pattern = NDITestPattern(title: "Gap", note: "frames 20–24 missing")
    let writer = try TakeWriter(request: .init(url: url, takeID: 1, codec: .h264, startSeconds: 3600, startHost: 0,
                                               timecodeAtVideoRate: true, dropFrame: false),
                                width: NDITestPattern.width, height: NDITestPattern.height, videoRate: .fps25)
    for n in 0..<60 where !(20..<25).contains(n) {
        guard let buffer = pattern.frame() else { break }
        writer.append(RecorderFrame(buffer: buffer, time: Double(n) / 25, host: Double(n) / 25, fps: 25))
        while !writer.isReady { Thread.sleep(forTimeInterval: 0.002) }   // offline: let the encoder keep up
    }
    let result = Box<Result<RecorderTake, RecorderError>?>(nil)
    writer.finish { result.value = $0 }
    _ = wait(10) { result.value != nil }
    if case .success(let take)? = result.value {
        check("Gap: drop counted", take.droppedFrames == 5, "\(take.droppedFrames) dropped")
        await verify(take, expectStart: Timecode("01:00:00:00")!, rate: .fps25, seconds: 60.0 / 25, label: "Gap held",
                     expectDropped: 5)
    } else {
        check("Gap take", false, "\(String(describing: result.value))")
    }
} catch {
    check("Gap take", false, "\(error)")
}

let failed = checks.filter { !$0.ok }
print("\n\(checks.count - failed.count)/\(checks.count) checks passed. Files in \(out.path)")
exit(failed.isEmpty ? 0 : 1)
