// Waveform harness: renders a generated song's waveform at the timeline's zooms, checks an older
// cached analysis is upgraded in place, and times drawing a 2-hour show. Run with
// scripts/waveform-harness.sh (temp store only). Render.swift draws a window of a file's waveform;
// swap it for another version's to compare.
@preconcurrency import AVFoundation
import Foundation

setvbuf(stdout, nil, _IONBF, 0)
guard let store = ProcessInfo.processInfo.environment["UNDERSTUDY_STORE"], !store.isEmpty else {
    print("Set UNDERSTUDY_STORE to a temp folder first."); exit(2)
}
let storeURL = URL(fileURLWithPath: store, isDirectory: true)
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : store, isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok   \(what)" : "  FAIL \(what)")
    if !ok { failures += 1 }
}

/// A 4-minute stereo test song: a kick every half second (120 BPM) with a hat between, under a
/// slow sine sweep 40 Hz → 8 kHz that swells and fades; a quiet bridge at 2:00–2:10; and a short
/// burst at exactly 2:02.000.
func writeTestSong(_ url: URL, seconds: Double = 240) throws {
    let rate = 48_000.0
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let chunk = 48_000
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))!
    var phase = 0.0
    var seed: UInt64 = 1
    var frame = 0
    let total = Int(seconds * rate)
    while frame < total {
        let n = min(chunk, total - frame)
        buffer.frameLength = AVAudioFrameCount(n)
        let l = buffer.floatChannelData![0], r = buffer.floatChannelData![1]
        for i in 0..<n {
            let t = Double(frame + i) / rate
            let f = 40 * pow(200, t / seconds)
            phase += 2 * .pi * f / rate
            let swell = 0.35 + 0.25 * sin(2 * .pi * t / 37)
            let beat = t.truncatingRemainder(dividingBy: 0.5)
            let kick = beat < 0.25 ? exp(-beat * 30) * sin(2 * .pi * 55 * beat * (1 + exp(-beat * 40))) : 0
            let hb = (t + 0.25).truncatingRemainder(dividingBy: 0.5)
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Double(Int64(bitPattern: seed >> 1) % 2001) / 1000 - 1
            let hat = hb < 0.05 ? exp(-hb * 120) * noise * 0.4 : 0
            var s = swell * sin(phase) * 0.6 + kick * 0.7 + hat
            if t >= 120, t < 130 { s *= 0.08 }
            if t >= 122, t < 122.005 { s = (frame + i) % 2 == 0 ? 0.95 : -0.95 }
            l[i] = Float(s)
            r[i] = Float(s * 0.9 + noise * 0.01)
        }
        try file.write(from: buffer)
        frame += n
    }
}

let song = storeURL.appendingPathComponent("test-song.wav")
let root = storeURL.appendingPathComponent("analysis", isDirectory: true)
print("Writing a 4-minute test song…")
try writeTestSong(song)

print("Analysing…")
var started = Date()
guard let peaks = Render.analyze(path: song.path, root: root) else { print("analysis failed"); exit(1) }
print(String(format: "  %.2f s", Date().timeIntervalSince(started)))

// The timeline's zooms for a 4-minute song: whole song, 8×, 32× (its closest), across a
// 1500-point window on a Retina screen.
let windows: [(name: String, from: Double, to: Double)] = [
    ("1-whole-song", 0, 240), ("2-zoom-8x", 105, 135), ("3-zoom-32x", 119.5, 127),
]
for w in windows {
    let url = out.appendingPathComponent("\(Render.label)-\(w.name).png")
    let ok = MainActor.assumeIsolated { Render.png(peaks, from: w.from, to: w.to, width: 1500, height: 180, to: url) }
    check(ok, "rendered \(url.lastPathComponent)")
}

if Render.label == "after" {
    print("Upgrading an analysis cached before this waveform format…")
    let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    check(folders.count == 1, "one cache folder")
    let folder = folders[0]
    let meta = folder.appendingPathComponent("analysis.json")
    let wave = folder.appendingPathComponent("waveform.peaks")
    check(FileManager.default.fileExists(atPath: wave.path), "waveform.peaks written beside analysis.json")
    // What an older Understudy left: 3000 peaks in the JSON, no waveform file.
    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: meta)) as! [String: Any]
    check(json["peaks"] == nil, "no peaks in the new analysis.json")
    json["peaks"] = [Float](repeating: 0.5, count: 3000)
    try JSONSerialization.data(withJSONObject: json).write(to: meta)
    try FileManager.default.removeItem(at: wave)
    let before = try Data(contentsOf: meta)
    started = Date()
    let upgraded = Render.analyze(path: song.path, root: root)
    check(upgraded != nil, String(format: "old cache read and upgraded (%.2f s)", Date().timeIntervalSince(started)))
    check(FileManager.default.fileExists(atPath: wave.path), "waveform.peaks rebuilt in the same folder")
    check((try? FileManager.default.contentsOfDirectory(atPath: root.path).count) == 1, "no second cache folder")
    check((try? Data(contentsOf: meta)) == before, "rest of the analysis kept as it was")
    check(Render.sameDrawing(upgraded, peaks), "same waveform as a fresh analysis")
    // A damaged or future-format waveform file is rebuilt too.
    try Data("nonsense".utf8).write(to: wave)
    check(Render.sameDrawing(Render.analyze(path: song.path, root: root), peaks), "a damaged waveform file is rebuilt")
}

print("Drawing a 2-hour show (30 four-minute songs)…")
let timing = Render.timeShow(peaks)
print(timing)

print(failures == 0 ? "All good. Images in \(out.path)" : "\(failures) failed.")
exit(failures == 0 ? 0 : 1)
