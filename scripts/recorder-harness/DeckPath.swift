import Foundation
import UnderstudyCore

/// The recorder as a deck: DeckController arms it, logs show code against the take (as AppModel's
/// logTakes does), stops it, lists the clip and files the take map; then the same in
/// record-while-code-runs. Show code is simulated: it rolls from 02:00:00;00 and jumps 100 s
/// forward partway through the continuous take.
@MainActor
func deckPathChecks(out: URL) async {
    let rate = FrameRate.fps29_97DF
    let folder = out.appendingPathComponent("Deck path", isDirectory: true)
    let deck = DeckController(id: 7)
    let showStart = Double(Timecode("02:00:00;00")!.frameIndex(at: rate)) / rate.exact
    let t0 = HostClock.now()
    var jump = 0.0
    func show(_ host: Double) -> Double { showStart + jump + (host - t0) }
    func span(_ clip: DeckClip) -> (Double, Double) {
        let s = clip.start.seconds(at: rate)
        return (s, s + Double(clip.duration.durationFrames(nominal: rate.nominal)) / rate.exact)
    }
    deck.recorderFolder = { folder }
    deck.recorderStartSeconds = { show($0) }
    deck.recorderTimecodeAtVideoRate = { true }
    deck.buildsTakeMaps = true
    var finishedCount = 0
    deck.onRecordingFinished = { finishedCount += 1 }
    deck.onClipsRefreshed = { [unowned deck] in deck.maps.attachPending(to: deck.clips, deckSpan: span) }

    func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
    func until(_ timeout: Double, _ ok: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if ok() { return true }; await sleep(0.05) }
        return ok()
    }

    deck.attachRecorder(RecorderSettings(source: .testPattern, codec: .hevc), dropFrame: true)
    let live = await until(10) { deck.isConnected && deck.transport.inputVideoFormat != nil }
    check("Deck path: recorder slot connects", live,
          "connection \(deck.connection), input \(deck.transport.inputVideoFormat ?? "none"), model \(deck.model ?? "-")")
    guard live else { return }

    // Continuous: REC, log readings every 0.1 s for 6 s (code jumps at 3 s), STOP.
    let showAtREC = show(HostClock.now())
    deck.arm(prefix: "ME 8", mode: .continuous, dropFrame: true)
    let began = Date()
    while Date().timeIntervalSince(began) < 6 {
        if jump == 0, Date().timeIntervalSince(began) >= 3 { jump = 100 }
        deck.poll { [unowned deck] tc, at in
            deck.logTakeReading(ltcSeconds: show(at), deckSeconds: (Double(tc.frameIndex(at: rate)) + 0.5) / rate.exact,
                                deckDropFrame: true, now: HostClock.now())
        }
        await sleep(0.1)
    }
    check("Deck path: transport shows record", deck.transport.status == .record && deck.isLoggingTake,
          "status \(deck.transport.status), logging \(deck.isLoggingTake), tc \(deck.transport.displayTimecode?.display(dropFrame: true) ?? "-")")
    deck.stopAll()
    let listed = await until(15) { deck.clips.count == 1 && finishedCount >= 2 }
    check("Deck path: take listed as a clip", listed, deck.clips.map { "\($0.id) \($0.name) \($0.start.display(dropFrame: true)) +\($0.duration)" }.joined(separator: ", "))
    if let clip = deck.clips.first {
        check("Deck path: deck-style file name", clip.name == "ME 8_0001.mov", clip.name)
        check("Deck path: file in the recorder folder", FileManager.default.fileExists(atPath: folder.appendingPathComponent(clip.name).path),
              folder.appendingPathComponent(clip.name).path)
        let recIndex = Int((showAtREC * rate.exact).rounded())
        let late = clip.start.frameIndex(at: rate) - recIndex
        check("Deck path: clip stamped with show code at REC", late >= 0 && late <= 3,
              "show code at REC \(Timecode(frameIndex: recIndex, rate: rate).display(dropFrame: true)), clip \(clip.start.display(dropFrame: true)) (\(late) frames later)")
        let frames = clip.duration.durationFrames(nominal: rate.nominal)
        check("Deck path: clip length", abs(Double(frames) - 6 * rate.exact) <= 6, "\(frames) frames for ~6 s")
        if let map = deck.maps.map(for: clip) {
            let segs = map.segments.map { String(format: "[%.2f–%.2f %+.3f]", $0.ltcStart - showStart, $0.ltcEnd - showStart, $0.offset) }
            check("Deck path: take map filed with the jump as two segments", map.segments.count == 2,
                  "\(map.segments.count) segments: \(segs.joined(separator: " "))")
            if map.segments.count == 2 {
                let frame = 1 / rate.exact
                check("Deck path: first run lines up with the clip", abs(map.segments[0].offset) < frame, String(format: "offset %+.4f s", map.segments[0].offset))
                check("Deck path: jumped run offset −100 s", abs(map.segments[1].offset + 100) < frame, String(format: "offset %+.4f s", map.segments[1].offset))
                // Show code one second after REC is one second into the clip.
                let deckAt = map.deckSeconds(atLTC: showAtREC + 1) ?? -1
                check("Deck path: show code finds the right frame", abs(deckAt - span(clip).0 - 1) < 2 * frame,
                      String(format: "REC + 1 s of show code → %.3f s into the clip", deckAt - span(clip).0))
            }
        } else {
            check("Deck path: take map filed", false, "no map for \(clip.name)")
        }
    }
    check("Deck path: back to live after STOP", deck.transport.status == .preview && deck.transport.displayTimecode == nil,
          "status \(deck.transport.status)")
    check("Deck path: disk time left", deck.mediaSecondsLeft != nil, deck.mediaSecondsLeft.map { "\($0 / 60) min" } ?? "none")

    // Record while code runs: nothing until code rolls, a take per run.
    jump = 0
    deck.buildsTakeMaps = false
    deck.arm(prefix: "ME 8", mode: .timecodeRun, dropFrame: true)
    for _ in 0..<10 { deck.recorderShowCode(rolling: false); await sleep(0.1) }
    check("Deck path: armed, no code, not recording", deck.recorder?.isRecording == false, "\(deck.transport.status)")
    for run in 0..<2 {
        for _ in 0..<20 { deck.recorderShowCode(rolling: true); await sleep(0.1) }
        check("Deck path: code run \(run + 1) records", deck.transport.status == .record, "\(deck.transport.status)")
        for _ in 0..<5 { deck.recorderShowCode(rolling: false); await sleep(0.1) }
    }
    deck.stopAll()
    let runs = await until(15) { deck.clips.count == 3 }
    check("Deck path: one take per code run", runs, deck.clips.map(\.name).joined(separator: ", "))
    check("Deck path: run takes count up", deck.clips.map(\.name) == ["ME 8_0001.mov", "ME 8_0002.mov", "ME 8_0003.mov"],
          deck.clips.map { "\($0.name) @ \($0.start.display(dropFrame: true))" }.joined(separator: ", "))
    let store = TimelineModel.storeDirectory.appendingPathComponent("recorder/deck-8.json").path
    check("Deck path: take list saved in the (temp) store", FileManager.default.fileExists(atPath: store), store)
    deck.disconnect()
}
