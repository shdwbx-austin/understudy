import AVFoundation
import Foundation
import UnderstudyCore

/// What Understudy knows about a song's audio file.
struct AudioAnalysis: Codable, Sendable {
    /// Waveform of the music channels (the timecode channel left out). Kept in its own file beside
    /// the analysis (`waveform.peaks`), not in the JSON.
    var waveform: WaveformPeaks?
    /// Timecode found in the file, if any.
    var ltc: LTCScanResult?
    /// The file without its timecode channel; nil when there's no timecode (play the original),
    /// or when timecode is all the file has.
    var musicPath: String?
    /// The timecode channel on its own, for LTC out.
    var ltcPath: String?
    var channels: Int
    /// The tempo heard in the music (nil: none clear, or not looked for yet).
    var tempo: TempoEstimate?
    /// Tempo detection has run on this file (so a file with no clear tempo isn't read again).
    var tempoChecked: Bool?

    // Older analyses also have `peaks` (3000 0…1 values per song): it's ignored, and the
    // waveform is rebuilt from the audio file.
    enum CodingKeys: String, CodingKey { case ltc, musicPath, ltcPath, channels, tempo, tempoChecked }
}

/// Reads a song's audio once, in the background: looks for LTC in each channel, writes a copy
/// without that channel (so timecode never reaches the PA) and one with only that channel (for
/// LTC out), and builds a waveform of the music. Everything is cached by the file's path, size
/// and date, so the next launch is instant.
enum AudioAnalyzer {
    /// Seconds of the start of the file scanned for timecode.
    static let scanSeconds = 20.0
    /// Part of every cache folder's name (it was the waveform's bucket count and the analysis
    /// version). Unchanged so existing analyses are still found: a missing or older waveform file
    /// is rebuilt on its own, without splitting the audio again.
    private static let folderKey = "3000|2"

    static func analyze(path: String, rate: FrameRate, root: URL) -> AudioAnalysis? {
        guard let folder = cacheFolder(for: path, rate: rate, root: root) else { return nil }
        let meta = folder.appendingPathComponent("analysis.json")
        let wave = folder.appendingPathComponent("waveform.peaks")
        if let data = try? Data(contentsOf: meta), var cached = try? JSONDecoder().decode(AudioAnalysis.self, from: data),
           cached.musicPath.map({ FileManager.default.fileExists(atPath: $0) }) ?? true,
           cached.ltcPath.map({ FileManager.default.fileExists(atPath: $0) }) ?? true {
            let music = (0..<cached.channels).filter { $0 != cached.ltc?.channel }
            cached.waveform = music.isEmpty ? nil : (try? Data(contentsOf: wave)).flatMap { WaveformPeaks(encoded: $0) }
            // Analysed before tempo detection, or before this waveform format: read the file once
            // more for what's missing, keep the rest.
            let needWaveform = !music.isEmpty && cached.waveform == nil
            let needTempo = cached.tempoChecked != true
            if needWaveform || needTempo {
                let heard = listen(path: path, music: music, waveform: needWaveform, tempo: needTempo)
                if needWaveform, let waveform = heard.waveform {
                    cached.waveform = waveform
                    try? waveform.encoded().write(to: wave, options: .atomic)
                }
                if needTempo {
                    cached.tempo = heard.tempo
                    cached.tempoChecked = true
                    if let data = try? JSONEncoder().encode(cached) { try? data.write(to: meta, options: .atomic) }
                }
            }
            return cached
        }
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let sampleRate = format.sampleRate
        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }

        // 1. Scan the start of every channel for timecode.
        let scanner = LTCChannelScanner(channels: channels, sampleRate: sampleRate, rate: rate)
        let scanFrames = min(file.length, AVAudioFramePosition(scanSeconds * sampleRate))
        while file.framePosition < scanFrames {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            for c in 0..<channels { scanner.feed(channel: c, data[c], count: Int(buffer.frameLength)) }
        }
        let ltc = scanner.result()
        file.framePosition = 0

        // 2. One pass over the whole file: waveform of the music, and the split copies.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let musicChannels = (0..<channels).filter { $0 != ltc?.channel }
        var musicFile: AVAudioFile?
        var ltcFile: AVAudioFile?
        if let ltc {
            if !musicChannels.isEmpty {
                musicFile = try? AVAudioFile(forWriting: folder.appendingPathComponent("music.caf"),
                                             settings: lossless(sampleRate, channels: musicChannels.count, bits: 24),
                                             commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            _ = ltc
            ltcFile = try? AVAudioFile(forWriting: folder.appendingPathComponent("timecode.caf"),
                                       settings: lossless(sampleRate, channels: 1, bits: 16),
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        let musicBuffer = musicFile.flatMap { AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: chunk) }
        let ltcBuffer = ltcFile.flatMap { AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: chunk) }
        var builder = WaveformBuilder(sampleRate: sampleRate, expectedFrames: Int(file.length))
        var lows = [Float](repeating: 0, count: Int(chunk)), highs = lows
        var listener = TempoListener(sampleRate: sampleRate, channels: musicChannels, chunk: Int(chunk))
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            if !musicChannels.isEmpty { addFrames(data, channels: musicChannels, frames: frames, to: &builder, lows: &lows, highs: &highs) }
            listener.feed(data, frames: frames)
            if let musicFile, let musicBuffer, let out = musicBuffer.floatChannelData {
                musicBuffer.frameLength = AVAudioFrameCount(frames)
                for (i, c) in musicChannels.enumerated() { out[i].update(from: data[c], count: frames) }
                try? musicFile.write(from: musicBuffer)
            }
            if let ltc, let ltcFile, let ltcBuffer, let out = ltcBuffer.floatChannelData {
                ltcBuffer.frameLength = AVAudioFrameCount(frames)
                out[0].update(from: data[ltc.channel], count: frames)
                try? ltcFile.write(from: ltcBuffer)
            }
        }
        let waveform = musicChannels.isEmpty ? nil : builder.finish()
        let analysis = AudioAnalysis(
            waveform: waveform,
            ltc: ltc,
            musicPath: musicFile == nil ? nil : folder.appendingPathComponent("music.caf").path,
            ltcPath: ltcFile == nil ? nil : folder.appendingPathComponent("timecode.caf").path,
            channels: channels,
            tempo: listener.estimate(hint: SongTempo.bpm(fromFileName: (path as NSString).lastPathComponent)),
            tempoChecked: true
        )
        // Close the copies before anyone reads them.
        musicFile = nil
        ltcFile = nil
        if let waveform { try? waveform.encoded().write(to: wave, options: .atomic) }
        if let data = try? JSONEncoder().encode(analysis) { try? data.write(to: meta, options: .atomic) }
        return analysis
    }

    /// Each frame's lowest and highest sample across `channels`, into the waveform.
    private static func addFrames(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, channels: [Int], frames: Int,
                                  to builder: inout WaveformBuilder, lows: inout [Float], highs: inout [Float]) {
        if lows.count < frames {
            lows = [Float](repeating: 0, count: frames)
            highs = lows
        }
        let first = data[channels[0]]
        for f in 0..<frames { lows[f] = first[f]; highs[f] = first[f] }
        for c in channels.dropFirst() {
            let ch = data[c]
            for f in 0..<frames {
                lows[f] = min(lows[f], ch[f])
                highs[f] = max(highs[f], ch[f])
            }
        }
        lows.withUnsafeBufferPointer { l in
            highs.withUnsafeBufferPointer { h in
                builder.add(lows: UnsafeBufferPointer(rebasing: l[0..<frames]), highs: UnsafeBufferPointer(rebasing: h[0..<frames]))
            }
        }
    }

    /// Reads the file once more for the waveform, the tempo or both (for analyses made before them).
    static func listen(path: String, music: [Int], waveform: Bool, tempo: Bool) -> (waveform: WaveformPeaks?, tempo: TempoEstimate?) {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return (nil, nil) }
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return (nil, nil) }
        let music = music.filter { $0 < Int(format.channelCount) }
        var listener = TempoListener(sampleRate: format.sampleRate, channels: music, chunk: Int(chunk))
        var builder = WaveformBuilder(sampleRate: format.sampleRate, expectedFrames: Int(file.length))
        var lows = [Float](repeating: 0, count: Int(chunk)), highs = lows
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            if tempo { listener.feed(data, frames: frames) }
            if waveform, !music.isEmpty { addFrames(data, channels: music, frames: frames, to: &builder, lows: &lows, highs: &highs) }
        }
        return (waveform && !music.isEmpty ? builder.finish() : nil,
                tempo ? listener.estimate(hint: SongTempo.bpm(fromFileName: (path as NSString).lastPathComponent)) : nil)
    }

    private static func lossless(_ sampleRate: Double, channels: Int, bits: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: sampleRate,
         AVNumberOfChannelsKey: channels, AVEncoderBitDepthHintKey: bits]
    }

    /// One folder per version of an audio file: name, size, date and show rate, hashed (not the
    /// full path, so a copy moved into the project keeps its analysis).
    private static func cacheFolder(for path: String, rate: FrameRate, root: URL) -> URL? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a
        let name = URL(fileURLWithPath: path).lastPathComponent
        for byte in "\(name)|\(size)|\(Int(date))|\(rate.rawValue)|\(folderKey)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return root.appendingPathComponent(String(format: "%016llx", hash), isDirectory: true)
    }
}

/// Listens for a song's tempo as its audio streams past: the music channels mixed, and each one
/// on its own (up to eight), so a click channel is found when there is one.
struct TempoListener {
    private var mix: OnsetEnvelope
    private var perChannel: [Int: OnsetEnvelope] = [:]
    private let channels: [Int]
    private var scratch: [Float]

    init(sampleRate: Double, channels: [Int], chunk: Int) {
        self.channels = channels
        mix = OnsetEnvelope(sampleRate: sampleRate)
        if channels.count > 1 {
            for c in channels.prefix(8) { perChannel[c] = OnsetEnvelope(sampleRate: sampleRate) }
        }
        scratch = [Float](repeating: 0, count: chunk)
    }

    mutating func feed(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
        guard !channels.isEmpty else { return }
        if scratch.count < frames { scratch = [Float](repeating: 0, count: frames) }
        let scale = 1 / Float(channels.count)
        for f in 0..<frames {
            var sum: Float = 0
            for c in channels { sum += data[c][f] }
            scratch[f] = sum * scale
        }
        scratch.withUnsafeBufferPointer { mix.feed($0.baseAddress!, count: frames) }
        for c in perChannel.keys { perChannel[c]!.feed(data[c], count: frames) }
    }

    func estimate(hint: Double?) -> TempoEstimate? {
        guard !channels.isEmpty else { return nil }
        let whole = TempoDetector.estimate(mix, hint: hint)
        var each: [Int: TempoEstimate] = [:]
        for (c, env) in perChannel { if let e = TempoDetector.estimate(env, hint: hint) { each[c] = e } }
        return TempoDetector.best(mix: whole, channels: each)
    }
}
