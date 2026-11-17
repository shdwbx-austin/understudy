// Records from synthetic sources with the Understudy recorder's engine and checks the files:
//  1. NDI loopback through Understudy's own sender (BGRX) 1080p29.97 DF → H.264, ~10 s; then a
//     source with alpha (BGRA), recorded without it and said so.
//  2. NDI loopback, UYVY 1080p25 → HEVC: the 2vuy path (what Understudy's own NDI out sends).
//  3. NDI loopback, UYVY 576i50 interleaved → ProRes 422: SD colour (BT.601) and fields; then a
//     sender sending separate fields (NDI weaves them into interleaved frames for the receiver);
//     then a stand-in for this Mac's own Understudy output, which must be hidden and refused.
//  4. Generated frames (no NDI) → ProRes 422 Proxy, across the 11:00 drop-frame minute.
//  5. A 5-frame gap in the source: held frames, constant frame rate.
//  6. 10-bit 4:2:2 (x422) → ProRes 422, stamped with the time of day at 29.97 non-drop.
//  7. The recorder as a deck slot through DeckController.
// Each file is opened with AVFoundation and checked for frame count, length, timecode, colour and
// field tags, and the colour of the bars decoded back out (a 601/709 mix-up shifts them, and they
// only come back right if the recorder leaves the pixels alone). Run with scripts/recorder-harness.sh
// (temp store only).
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

/// Show code (not clock time) at a timecode.
func showCode(_ tc: Timecode, _ rate: FrameRate) -> RecorderStartCode {
    RecorderStartCode(seconds: Double(tc.frameIndex(at: rate)) / rate.exact, isClockTime: false)
}

/// Records one take from `source`; also returns every warning shown while it ran.
func record(_ source: RecorderSource, codec: RecorderCodec, seconds: Double, startTC: Timecode, rate: FrameRate,
            file: String) -> (take: RecorderTake, warnings: Set<String>)? {
    let recorder = InternalRecorder(deckName: "Harness")
    let status = Box(InternalRecorder.Status())
    let finished = Box<Result<RecorderTake, RecorderError>?>(nil)
    let lock = NSLock()
    recorder.onStatus = { s in lock.lock(); status.value = s; lock.unlock() }
    recorder.onTakeFinished = { r in lock.lock(); finished.value = r; lock.unlock() }
    func snap() -> InternalRecorder.Status { lock.lock(); defer { lock.unlock() }; return status.value }
    recorder.open(source, codec: codec, dropFrame: rate.isDropFrame, folder: out)
    guard wait(15, until: { snap().videoFormat != nil }) else {
        print("No picture from \(source.label): \(snap().state)"); return nil
    }
    print("Source live: \(snap().signal ?? "?") (\(snap().videoFormat ?? "?"))")
    let url = out.appendingPathComponent(file)
    try? FileManager.default.removeItem(at: url)
    recorder.startTake(.init(url: url, takeID: 1, codec: codec, start: showCode(startTC, rate), startHost: HostClock.now(),
                             timecodeAtVideoRate: true, dropFrame: rate.isDropFrame))
    let began = Date()
    var lastReport = -1
    var warnings: Set<String> = []
    while Date().timeIntervalSince(began) < seconds {
        Thread.sleep(forTimeInterval: 0.25)
        let s = snap()
        warnings.formUnion(s.health.warnings.map(\.text))
        let t = Int(Date().timeIntervalSince(began))
        if t != lastReport {
            lastReport = t
            print(String(format: "  %2ds  tc %@  dropped %d  skipped %d  %@  warnings: %@", t, s.timecode?.display(dropFrame: rate.isDropFrame) ?? "--",
                         s.health.droppedFrames, s.health.skippedFrames, RecorderHealth.rateText(s.health.bytesPerSecond),
                         s.health.warnings.map(\.text).joined(separator: ", ")))
        }
    }
    recorder.stopTake()
    guard wait(20, until: { lock.lock(); defer { lock.unlock() }; return finished.value != nil }) else { print("Take never finished"); return nil }
    recorder.close()
    lock.lock(); let result = finished.value!; lock.unlock()
    switch result {
    case .failure(let e): print("Take failed: \(e.message)"); return nil
    case .success(let take): return (take, warnings)
    }
}

/// What a file should say about itself.
struct Expect {
    var format: String
    var color = RecorderColor.rec709
    var scan = RecorderScan.progressive
    var dropped = 0
}

/// Opens the file and checks it against the take.
func verify(_ take: RecorderTake, expectStart: Timecode, rate: FrameRate, seconds: Double, label: String, _ expect: Expect) async {
    let asset = AVURLAsset(url: URL(fileURLWithPath: take.path))
    do {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let tcTracks = try await asset.loadTracks(withMediaType: .timecode)
        guard let v = videoTracks.first else { check("\(label) video track", false, "none"); return }
        let fps = try await v.load(.nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
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
        let desc = try await v.load(.formatDescriptions).first
        let codecText = desc.map { RecorderPixelFormat.name(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
        let tcDuration = try await tcTracks.first?.load(.timeRange).duration.seconds
        let expectedFrames = Int((seconds * rate.exact).rounded())
        print("  \(label): \(frames) frames, \(String(format: "%.3f", duration)) s, nominal \(fps) fps, codec \(codecText), tmcd samples \(tcSamples)")
        check("\(label) codec", codecText == take.codec.fourCC, codecText)
        check("\(label) frame count", frames == take.frames && abs(frames - expectedFrames) <= Int(rate.exact * 0.5),
              "\(frames) in file, take says \(take.frames), ~\(expectedFrames) expected for \(seconds) s")
        check("\(label) constant frame rate", abs(duration - Double(frames) / rate.exact) < 0.01 && abs(Double(fps) - rate.exact) < 0.05,
              String(format: "%.3f s for %d frames, nominal %.3f fps at %@", duration, frames, fps, rate.rawValue))
        check("\(label) format name", take.videoFormat == expect.format, take.videoFormat)

        // Colour and field tags in the file.
        func ext(_ key: CFString) -> Any? { desc.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: key) } }
        let tags = [ext(kCMFormatDescriptionExtension_ColorPrimaries), ext(kCMFormatDescriptionExtension_TransferFunction),
                    ext(kCMFormatDescriptionExtension_YCbCrMatrix)].map { ($0 as? String) ?? "none" }
        check("\(label) colour tags", tags == [expect.color.primaries, expect.color.transfer, expect.color.matrix],
              tags.joined(separator: " / "))
        let fieldCount = (ext(kCMFormatDescriptionExtension_FieldCount) as? NSNumber)?.intValue ?? 1
        let fieldDetail = ext(kCMFormatDescriptionExtension_FieldDetail) as? String
        let wantDetail: String? = expect.scan == .progressive ? nil
            : (expect.scan == .topFieldFirst ? kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly : kCMFormatDescriptionFieldDetail_SpatialFirstLineLate) as String
        check("\(label) field tags", fieldCount == (expect.scan.isInterlaced ? 2 : 1) && fieldDetail == wantDetail,
              "field count \(fieldCount), detail \(fieldDetail ?? "none")")

        // Timecode.
        guard let firstTC else { check("\(label) timecode track", false, "missing"); return }
        let tc = Timecode(frameIndex: Int(firstTC), rate: rate)
        check("\(label) timecode = take start", Int(firstTC) == take.startFrame,
              "file \(tc.display(dropFrame: rate.isDropFrame)), take \(take.clip.start.display(dropFrame: rate.isDropFrame))")
        let late = Int(firstTC) - expectStart.frameIndex(at: rate)
        check("\(label) timecode = code asked for at REC", late >= 0 && late <= 3,
              "asked \(expectStart.display(dropFrame: rate.isDropFrame)) at REC, first frame \(tc.display(dropFrame: rate.isDropFrame)) (\(late) frames later)")
        check("\(label) timecode covers the file", abs((tcDuration ?? 0) - duration) < 0.01,
              String(format: "tmcd %.3f s vs video %.3f s", tcDuration ?? 0, duration))
        check("\(label) dropped frames", take.droppedFrames == expect.dropped, "\(take.droppedFrames)")

        // The bars, decoded back to RGB the way a player reads the file's tags.
        if let bars = try await barColours(asset, track: v) {
            let red = bars.red, green = bars.green
            let ok = close(red, (191, 0, 0)) && close(green, (0, 191, 0))
            check("\(label) bar colours", ok, "red bar \(red), green bar \(green) (75% bars: 191,0,0 and 0,191,0)")
        } else {
            check("\(label) bar colours", false, "couldn't decode a frame")
        }
    } catch {
        check("\(label) readable", false, error.localizedDescription)
    }
}

func close(_ a: (Int, Int, Int), _ b: (Int, Int, Int), within t: Int = 10) -> Bool {
    abs(a.0 - b.0) <= t && abs(a.1 - b.1) <= t && abs(a.2 - b.2) <= t
}

/// Decodes the first frame to BGRA and reads the centre of the red (6th) and green (4th) 75% bars.
func barColours(_ asset: AVAsset, track: AVAssetTrack) async throws -> (red: (Int, Int, Int), green: (Int, Int, Int))? {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    reader.startReading()
    guard let sample = output.copyNextSampleBuffer(), let image = CMSampleBufferGetImageBuffer(sample) else { return nil }
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(image) else { return nil }
    let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image), stride = CVPixelBufferGetBytesPerRow(image)
    func at(bar: Int) -> (Int, Int, Int) {
        let x = Int((Double(bar) + 0.5) * Double(w) / 7), y = h / 4
        let p = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        return (Int(p[2]), Int(p[1]), Int(p[0]))
    }
    return (at(bar: 5), at(bar: 3))
}

/// Sends `make()`'s frames over NDI as `name` at `rate` until the returned stop is called.
func sendOverNDI(rate: FrameRate, _ send: @escaping @Sendable () -> Void) -> () -> Void {
    let queue = DispatchQueue(label: "harness.send", qos: .userInteractive)
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
    timer.schedule(deadline: .now(), repeating: 1 / rate.exact, leeway: .milliseconds(1))
    timer.setEventHandler(handler: send)
    timer.resume()
    return { timer.cancel() }
}

func findNDI(_ name: String) -> String? {
    var found: String?
    _ = wait(10) { found = NDIFinder.shared.currentSources(wait: 0.5).first { $0.contains(name) }; return found != nil }
    return found
}

let ndiReady = NDILibrary.shared.isAvailable
if ndiReady { print("NDI: \(NDILibrary.shared.path ?? "?")") } else { check("NDI library", false, "set UNDERSTUDY_LIBNDI to libndi.dylib") }

// 1. NDI loopback through Understudy's own sender (opaque BGRX) → H.264.
if ndiReady, let sender = NDISender(name: "Recorder Harness Bars") {
    let rate = FrameRate.fps29_97DF, start = Timecode("01:00:00;00")!
    let pattern = NDITestPattern(title: "Harness", note: "NDI BGRX loopback")
    let stop = sendOverNDI(rate: rate) { if let f = pattern.frame() { sender.send(f, fps: rate.exact) } }
    if let name = findNDI("Recorder Harness Bars"),
       let (take, warnings) = record(RecorderSource(kind: .ndi, id: name, name: name), codec: .h264, seconds: seconds,
                                     startTC: start, rate: rate, file: "Harness NDI_0001.mov") {
        check("NDI BGRX: no alpha warning", !warnings.contains("SOURCE ALPHA NOT RECORDED"), warnings.sorted().joined(separator: ", "))
        await verify(take, expectStart: start, rate: rate, seconds: seconds, label: "NDI BGRX H.264", Expect(format: "1080p2997"))
    } else { check("NDI BGRX take", false, "no take") }
    stop()
}

// 1b. A source with alpha (BGRA, as a graphics feed sends): recorded without it, and said so.
if ndiReady, let sender = UYVYSender(name: "Recorder Harness Alpha", fourCC: NDIReceiver.fourCCBGRA) {
    let rate = FrameRate.fps25, start = Timecode("01:30:00:00")!
    let pattern = NDITestPattern(title: "Harness", note: "NDI BGRA (alpha) loopback")
    let stop = sendOverNDI(rate: rate) { if let f = pattern.frame() { sender.send(f, rate: rate, interleaved: false) } }
    if let name = findNDI("Recorder Harness Alpha"),
       let (take, warnings) = record(RecorderSource(kind: .ndi, id: name, name: name), codec: .h264, seconds: 3,
                                     startTC: start, rate: rate, file: "Harness Alpha_0001.mov") {
        check("NDI BGRA: alpha dropped is said", warnings.contains("SOURCE ALPHA NOT RECORDED"), warnings.sorted().joined(separator: ", "))
        await verify(take, expectStart: start, rate: rate, seconds: 3, label: "NDI BGRA (alpha) H.264", Expect(format: "1080p25"))
    } else { check("NDI BGRA take", false, "no take") }
    stop()
}

// 2. NDI UYVY 1080p25 → HEVC.
if ndiReady, let sender = UYVYSender(name: "Recorder Harness UYVY") {
    let rate = FrameRate.fps25, start = Timecode("09:59:50:00")!
    let pattern = NDITestPattern(title: "Harness", note: "NDI UYVY loopback")
    let convert = PictureConverter(width: 1920, height: 1080, format: kCVPixelFormatType_422YpCbCr8, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    nonisolated(unsafe) let state = (pattern, convert)
    let stop = sendOverNDI(rate: rate) {
        if let f = state.0.frame(), let u = state.1.convert(f) { sender.send(u, rate: rate, interleaved: false) }
    }
    if let name = findNDI("Recorder Harness UYVY"),
       let (take, warnings) = record(RecorderSource(kind: .ndi, id: name, name: name), codec: .hevc, seconds: 5,
                                     startTC: start, rate: rate, file: "Harness UYVY_0001.mov") {
        check("NDI UYVY: no alpha warning", !warnings.contains("SOURCE ALPHA NOT RECORDED"), warnings.sorted().joined(separator: ", "))
        await verify(take, expectStart: start, rate: rate, seconds: 5, label: "NDI UYVY HEVC", Expect(format: "1080p25"))
    } else { check("NDI UYVY take", false, "no take") }
    stop()
}

// 3. NDI UYVY 576i50 interleaved (BT.601) → ProRes 422.
if ndiReady, let sender = UYVYSender(name: "Recorder Harness SD") {
    let rate = FrameRate.fps25, start = Timecode("10:00:00:00")!
    let pattern = NDITestPattern(title: "Harness SD", note: "576i UYVY, BT.601")
    let convert = PictureConverter(width: 720, height: 576, format: kCVPixelFormatType_422YpCbCr8, matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
    nonisolated(unsafe) let state = (pattern, convert)
    let stop = sendOverNDI(rate: rate) {
        if let f = state.0.frame(), let u = state.1.convert(f) { sender.send(u, rate: rate, interleaved: true) }
    }
    if let name = findNDI("Recorder Harness SD"),
       let (take, warnings) = record(RecorderSource(kind: .ndi, id: name, name: name), codec: .proRes422, seconds: 4,
                                     startTC: start, rate: rate, file: "Harness SD_0001.mov") {
        check("NDI SD: interlaced kept (no progressive warning with ProRes)",
              !warnings.contains { $0.hasPrefix("INTERLACED") }, warnings.sorted().joined(separator: ", "))
        await verify(take, expectStart: start, rate: rate, seconds: 4, label: "NDI SD 576i ProRes",
                     Expect(format: "576i50", color: .rec601PAL, scan: .topFieldFirst))
    } else { check("NDI SD take", false, "no take") }
    stop()
}

// 3b. A sender sending separate fields (field 0, field 1, … at the field rate, each 288 lines: a
// field frame's yres is the field's own height). NDI weaves them for the receiver, so the take is
// 576i50 like the interleaved one. (If a receiver is ever handed separate fields, it reconnects
// asking NDI to de-interlace and the status says so; NDI doesn't do that with UYVY_BGRA.)
if ndiReady, let sender = UYVYSender(name: "Recorder Harness Fields") {
    let rate = FrameRate.fps25, start = Timecode("10:30:00:00")!
    let pattern = NDITestPattern(title: "Harness fields", note: "576i as separate fields")
    let convert = PictureConverter(width: 720, height: 288, format: kCVPixelFormatType_422YpCbCr8, matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
    nonisolated(unsafe) let state = (pattern, convert, Box(0))
    let stop = sendOverNDI(rate: .fps50) {
        state.2.value += 1
        if let f = state.0.frame(), let u = state.1.convert(f) { sender.send(u, rate: rate, formatType: state.2.value % 2 == 0 ? 2 : 3) }
    }
    if let name = findNDI("Recorder Harness Fields"),
       let (take, warnings) = record(RecorderSource(kind: .ndi, id: name, name: name), codec: .proRes422, seconds: 4,
                                     startTC: start, rate: rate, file: "Harness Fields_0001.mov") {
        print("  separate fields arrive as \(take.videoFormat); warnings: \(warnings.sorted().joined(separator: ", "))")
        // SD tags as standard(height:) gives for the picture that arrives.
        await verify(take, expectStart: start, rate: rate, seconds: 4, label: "NDI separate fields",
                     Expect(format: "576i50", color: .rec601PAL, scan: .topFieldFirst))
    } else { check("NDI separate-fields take", false, "no take") }
    stop()
}

// 3c. One of this Mac's own Understudy outputs ("Understudy ME 9" here, a stand-in): seen on the
// network, but never offered, and refused if a slot names it.
if ndiReady, let sender = NDISender(name: "Understudy ME 9") {
    let pattern = NDITestPattern(title: "Own output", note: "stand-in for Understudy's NDI out")
    let stop = sendOverNDI(rate: .fps25) { if let f = pattern.frame() { sender.send(f, fps: 25) } }
    if let name = findNDI("(Understudy ME 9)") {
        check("Own output: recognised as this Mac's", NDIFinder.isOwnOutput(name), name)
        let listed = Box<[String]?>(nil)
        NDIFinder.shared.list(wait: 1) { names in listed.value = names.filter { !NDIFinder.isOwnOutput($0) } }
        for _ in 0..<60 where listed.value == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        check("Own output: left out of the source list", listed.value.map { !$0.contains(name) } ?? false,
              "list: \((listed.value ?? []).joined(separator: ", "))")
        let recorder = InternalRecorder(deckName: "Harness own")
        let state = Box(InternalRecorder.Status.State.closed)
        recorder.onStatus = { s in state.value = s.state }
        recorder.open(RecorderSource(kind: .ndi, id: name, name: name), codec: .h264, dropFrame: false, folder: out)
        _ = wait(5) { if case .failed = state.value { return true }; return false }
        if case .failed(let why) = state.value {
            check("Own output: refused when a slot names it", why.contains("own NDI output"), why)
        } else {
            check("Own output: refused when a slot names it", false, "\(state.value)")
        }
        recorder.close()
    } else { check("Own output source found", false, "never showed up") }
    stop()
}

// 4. Generated frames → ProRes Proxy.
do {
    let rate = FrameRate.fps29_97DF, start = Timecode("10:59:58;00")!
    if let (take, _) = record(.testPattern, codec: .proResProxy, seconds: 3, startTC: start, rate: rate, file: "Harness Bars_0001.mov") {
        await verify(take, expectStart: start, rate: rate, seconds: 3, label: "Generated ProRes Proxy", Expect(format: "1080p2997"))
    } else { check("Generated take", false, "no take") }
}

/// Writes `count` frames straight into a TakeWriter (no source), leaving out `missing`.
func writeDirect(_ file: String, codec: RecorderCodec, rate: FrameRate, start: RecorderStartCode, count: Int, missing: Range<Int> = 0..<0,
                 convert: PictureConverter? = nil, scan: RecorderScan = .progressive,
                 inspect: (TakeWriter) -> Void = { _ in }) -> RecorderTake? {
    let url = out.appendingPathComponent(file)
    try? FileManager.default.removeItem(at: url)
    let pattern = NDITestPattern(title: file, note: missing.isEmpty ? "written directly" : "frames \(missing) missing")
    do {
        let writer = try TakeWriter(request: .init(url: url, takeID: 1, codec: codec, start: start, startHost: 0,
                                                   timecodeAtVideoRate: true, dropFrame: rate.isDropFrame),
                                    width: convert?.width ?? pattern.width, height: convert?.height ?? pattern.height,
                                    videoRate: rate, color: .rec709, scan: scan)
        inspect(writer)
        // Paced at the frame rate, as a live source arrives (a gap is real time with no frames).
        let began = Date()
        for n in 0..<count where !missing.contains(n) {
            let due = Double(n) / rate.exact - Date().timeIntervalSince(began)
            if due > 0 { Thread.sleep(forTimeInterval: due) }
            guard var buffer = pattern.frame() else { break }
            RecorderColor.rec709.attach(to: buffer)
            if let convert { guard let c = convert.convert(buffer) else { break }; buffer = c }
            scan.attach(to: buffer)
            let t = Double(n) / rate.exact
            writer.append(RecorderFrame(buffer: buffer, time: t, host: t, fps: rate.exact))
        }
        let result = Box<Result<RecorderTake, RecorderError>?>(nil)
        writer.finish { result.value = $0 }
        _ = wait(10) { result.value != nil }
        if case .success(let take)? = result.value { return take }
        check("\(file) take", false, "\(String(describing: result.value))")
    } catch {
        check("\(file) take", false, "\(error)")
    }
    return nil
}

// 5. A 5-frame gap: held frames keep it constant frame rate.
if let take = writeDirect("Harness Gap_0001.mov", codec: .h264, rate: .fps25, start: showCode(Timecode("01:00:00:00")!, .fps25),
                          count: 60, missing: 20..<25) {
    check("Gap: drop counted", take.droppedFrames == 5, "\(take.droppedFrames) dropped")
    await verify(take, expectStart: Timecode("01:00:00:00")!, rate: .fps25, seconds: 60.0 / 25, label: "Gap held",
                 Expect(format: "1080p25", dropped: 5))
}

// 6. 10-bit 4:2:2 (x422, what a 10-bit capture card gives for ProRes) → ProRes 422, stamped with
// the time of day 13:00:00 at 29.97 non-drop: the label must read the clock, not 3.6 s/h behind it.
let x422 = PictureConverter(width: 1920, height: 1080, format: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                            matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
if let take = writeDirect("Harness 10bit_0001.mov", codec: .proRes422, rate: .fps29_97,
                          start: RecorderStartCode(seconds: 13 * 3600, isClockTime: true), count: 60, convert: x422) {
    check("10-bit: clock time-of-day label", take.clip.start.description == "13:00:00:00", take.clip.start.description)
    await verify(take, expectStart: Timecode("13:00:00:00")!, rate: .fps29_97, seconds: 60 / FrameRate.fps29_97.exact,
                 label: "10-bit x422 ProRes 422", Expect(format: "1080p2997"))
}

// 6b. Interlaced into H.264: the encoder codes progressive frames, so the file says progressive and
// the recorder warns; into ProRes, bottom field first is kept as such.
var progressiveWarning = false
if let take = writeDirect("Harness Interlaced H264_0001.mov", codec: .h264, rate: .fps29_97DF,
                          start: showCode(Timecode("02:00:00;00")!, .fps29_97DF), count: 30, scan: .topFieldFirst,
                          inspect: { progressiveWarning = $0.interlacedAsProgressive }) {
    check("Interlaced H.264: says it's recorded progressive", progressiveWarning, "interlacedAsProgressive \(progressiveWarning)")
    await verify(take, expectStart: Timecode("02:00:00;00")!, rate: .fps29_97DF, seconds: 30 / FrameRate.fps29_97DF.exact,
                 label: "Interlaced → H.264", Expect(format: "1080i5994", scan: .progressive))
}
if let take = writeDirect("Harness BFF ProRes_0001.mov", codec: .proRes422, rate: .fps29_97DF,
                          start: showCode(Timecode("02:00:00;00")!, .fps29_97DF), count: 30, scan: .bottomFieldFirst) {
    await verify(take, expectStart: Timecode("02:00:00;00")!, rate: .fps29_97DF, seconds: 30 / FrameRate.fps29_97DF.exact,
                 label: "Bottom field first → ProRes", Expect(format: "1080i5994", scan: .bottomFieldFirst))
}

// 7. The recorder as a deck (DeckController), continuous and record-while-code-runs.
await deckPathChecks(out: out)

let failed = checks.filter { !$0.ok }
print("\n\(checks.count - failed.count)/\(checks.count) checks passed. Files in \(out.path)")
exit(failed.isEmpty ? 0 : 1)
