import AVFoundation
import Foundation
import UnderstudyCore

/// Reads a waveform overview from an audio file, a chunk at a time, and caches it on disk keyed
/// by the file's path, size and date, so the next launch is instant.
enum WaveformLoader {
    static let buckets = 3000

    static func peaks(forFileAt path: String) -> [Float]? {
        let cache = cacheURL(for: path)
        if let cache, let data = try? Data(contentsOf: cache), data.count >= MemoryLayout<Float>.size {
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
        var accumulator = PeakAccumulator(totalFrames: Int(file.length), buckets: buckets)
        var magnitudes = [Float](repeating: 0, count: Int(chunk))
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            for f in 0..<frames {
                var peak: Float = 0
                for c in 0..<Int(format.channelCount) { peak = max(peak, abs(channels[c][f])) }
                magnitudes[f] = peak
            }
            magnitudes.withUnsafeBufferPointer { accumulator.add(UnsafeBufferPointer(rebasing: $0[0..<frames])) }
        }
        let peaks = accumulator.normalized
        if let cache {
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? peaks.withUnsafeBytes { Data($0) }.write(to: cache, options: .atomic)
        }
        return peaks
    }

    /// One cache file per version of an audio file: path, size and modification date, hashed.
    private static func cacheURL(for path: String) -> URL? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a
        for byte in "\(path)|\(size)|\(date)|\(buckets)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return TimelineModel.storeDirectory.appendingPathComponent("waveforms", isDirectory: true)
            .appendingPathComponent(String(format: "%016llx.peaks", hash))
    }
}
