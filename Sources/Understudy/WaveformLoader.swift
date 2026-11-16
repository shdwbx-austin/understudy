import AVFoundation
import Foundation
import UnderstudyCore

/// What Understudy knows about a song's audio file.
struct AudioAnalysis: Codable, Sendable {
    /// Waveform of the music channels (the timecode channel left out), 0…1.
    var peaks: [Float]
    /// Timecode found in the file, if any.
    var ltc: LTCScanResult?
    /// The file without its timecode channel; nil when there's no timecode (play the original),
    /// or when timecode is all the file has.
    var musicPath: String?
    /// The timecode channel on its own, for LTC out.
    var ltcPath: String?
    var channels: Int
}

/// Reads a song's audio once, in the background: looks for LTC in each channel, writes a copy
/// without that channel (so timecode never reaches the PA) and one with only that channel (for
/// LTC out), and builds a waveform of the music. Everything is cached by the file's path, size
/// and date, so the next launch is instant.
enum AudioAnalyzer {
    static let buckets = 3000
    /// Seconds of the start of the file scanned for timecode.
    static let scanSeconds = 20.0
    private static let version = 2

    static func analyze(path: String, rate: FrameRate, root: URL) -> AudioAnalysis? {
        guard let folder = cacheFolder(for: path, rate: rate, root: root) else { return nil }
        let meta = folder.appendingPathComponent("analysis.json")
        if let data = try? Data(contentsOf: meta), let cached = try? JSONDecoder().decode(AudioAnalysis.self, from: data),
           cached.musicPath.map({ FileManager.default.fileExists(atPath: $0) }) ?? true,
           cached.ltcPath.map({ FileManager.default.fileExists(atPath: $0) }) ?? true {
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
        var accumulator = PeakAccumulator(totalFrames: Int(file.length), buckets: buckets)
        var magnitudes = [Float](repeating: 0, count: Int(chunk))
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for f in 0..<frames {
                var peak: Float = 0
                for c in musicChannels { peak = max(peak, abs(data[c][f])) }
                magnitudes[f] = peak
            }
            magnitudes.withUnsafeBufferPointer { accumulator.add(UnsafeBufferPointer(rebasing: $0[0..<frames])) }
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
        let analysis = AudioAnalysis(
            peaks: musicChannels.isEmpty ? [] : accumulator.normalized,
            ltc: ltc,
            musicPath: musicFile == nil ? nil : folder.appendingPathComponent("music.caf").path,
            ltcPath: ltcFile == nil ? nil : folder.appendingPathComponent("timecode.caf").path,
            channels: channels
        )
        // Close the copies before anyone reads them.
        musicFile = nil
        ltcFile = nil
        if let data = try? JSONEncoder().encode(analysis) { try? data.write(to: meta, options: .atomic) }
        return analysis
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
        for byte in "\(name)|\(size)|\(Int(date))|\(rate.rawValue)|\(buckets)|\(version)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return root.appendingPathComponent(String(format: "%016llx", hash), isDirectory: true)
    }
}
