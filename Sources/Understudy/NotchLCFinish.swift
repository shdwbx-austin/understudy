@preconcurrency import AVFoundation
import Foundation

/// Turns Media Encoder's NotchLC file into the finished clip: copies every track as it is (no
/// re-encode; macOS can't decode NotchLC and doesn't need to) into the destination, and adds the
/// source's QuickTime timecode track, which Notch's exporter leaves out.
///
/// It also means Media Encoder only ever writes to a short temporary path: the NotchLC plugin
/// (1.4.3) crashes Media Encoder when the output path is long (a stack buffer overflow while it
/// creates the movie; seen at ~240 characters, fine at ~75).
///
/// Foundation/AVFoundation only, so scripts/notchlc-harness can compile it too.
enum NotchLCFinish {
    enum Failure: LocalizedError {
        case unreadable(String)
        case writer(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let s): return "Couldn't read the NotchLC file: \(s)"
            case .writer(let s): return "Couldn't write the NotchLC file: \(s)"
            }
        }
    }

    /// What the finished file takes from the source: its timecode (format and first sample's bytes).
    struct Source: @unchecked Sendable {
        var timecodeFormat: CMFormatDescription?
        var timecodeData: Data?
    }

    static func source(_ url: URL) async -> Source {
        let asset = AVURLAsset(url: url)
        var info = Source()
        guard let track = try? await asset.loadTracks(withMediaType: .timecode).first,
              let reader = try? AVAssetReader(asset: asset) else { return info }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { return info }
        defer { reader.cancelReading() }
        // The first buffers can be empty markers; use the first one with data.
        while let s = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(s), let format = CMSampleBufferGetFormatDescription(s) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= 4 else { continue }
            var data = Data(count: length)
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            info.timecodeFormat = format
            info.timecodeData = data
            break
        }
        return info
    }

    /// One track being copied. AVFoundation's reader outputs and writer inputs aren't Sendable;
    /// each pair is only touched on its own queue.
    private struct Pair: @unchecked Sendable {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        let isVideo: Bool
    }

    /// Progress is reported every half percent, not every frame.
    private final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var last = -1.0
        func advance(to f: Double) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard f - last >= 0.005 else { return false }
            last = f
            return true
        }
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var _failed = false
        var failed: Bool { lock.lock(); defer { lock.unlock() }; return _failed }
        func fail() { lock.lock(); _failed = true; lock.unlock() }
    }

    /// Copies `encoded` into `destination` (the caller picks a free name), adding the source's
    /// timecode as one sample covering the whole clip. Each track keeps its own timescale
    /// (AVAssetWriter's default of 1/600 s can't hold 29.97's 1001/30000). `progress` gets 0…1 by
    /// time. Writes `<destination>.partial` first and renames it, so a half-written file is never
    /// left under the final name.
    static func finish(encoded: URL, source: Source, to destination: URL,
                       progress: @escaping @Sendable (Double) -> Void = { _ in },
                       cancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        let asset = AVURLAsset(url: encoded)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.load(.tracks).filter { $0.mediaType == .video || $0.mediaType == .audio }
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        guard let video = tracks.first(where: { $0.mediaType == .video }) else { throw Failure.unreadable("no video track") }
        let range = try await video.load(.timeRange)
        let videoTimescale = try await video.load(.naturalTimeScale)
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw Failure.unreadable(error.localizedDescription) }

        let fm = FileManager.default
        let partial = destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + ".partial")
        try? fm.removeItem(at: partial)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: partial, fileType: .mov) } catch { throw Failure.writer(error.localizedDescription) }
        writer.movieTimeScale = videoTimescale

        var pairs: [Pair] = []
        var videoInput: AVAssetWriterInput?
        for track in tracks {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { continue }
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if track.mediaType != .audio {   // audio keeps its sample rate; setting it raises
                input.mediaTimeScale = try await track.load(.naturalTimeScale)
            }
            let isVideo = track == video
            if isVideo {
                input.transform = try await track.load(.preferredTransform)
                videoInput = input
            }
            guard writer.canAdd(input) else { continue }
            reader.add(output)
            writer.add(input)
            pairs.append(Pair(output: output, input: input, isVideo: isVideo))
        }

        var tcInput: AVAssetWriterInput?
        if let format = source.timecodeFormat, let videoInput {
            let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            input.mediaTimeScale = videoTimescale
            if writer.canAdd(input) {
                videoInput.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.timecode.rawValue)
                writer.add(input)
                tcInput = input
            }
        }

        guard reader.startReading() else { throw Failure.unreadable(reader.error?.localizedDescription ?? "reader didn't start") }
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "writer didn't start") }
        writer.startSession(atSourceTime: range.start)

        // The timecode sample goes in first: the writer interleaves tracks, so the others stall
        // until every track has something.
        if let tcInput, let format = source.timecodeFormat, let data = source.timecodeData,
           let sample = makeTimecodeSample(format: format, data: data, start: range.start, duration: range.duration) {
            tcInput.append(sample)
            tcInput.markAsFinished()
        }

        let outcome = Outcome()
        let start = range.start
        let seconds = range.duration.seconds
        let reported = Reported()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for (index, pair) in pairs.enumerated() {
                group.enter()
                let queue = DispatchQueue(label: "understudy.notchlc.finish.\(index)")
                let finished = Outcome()   // "failed" here just means this track is finished
                pair.input.requestMediaDataWhenReady(on: queue) {
                    func end() {
                        finished.fail()
                        pair.input.markAsFinished()
                        group.leave()
                    }
                    while pair.input.isReadyForMoreMediaData && !finished.failed {
                        if cancelled() || outcome.failed {
                            outcome.fail()
                            end()
                            return
                        }
                        guard let sample = pair.output.copyNextSampleBuffer() else {
                            end()
                            return
                        }
                        if pair.isVideo, seconds > 0 {
                            let t = (CMSampleBufferGetPresentationTimeStamp(sample) - start).seconds
                            if reported.advance(to: min(1, max(0, t / seconds))) { progress(min(1, max(0, t / seconds))) }
                        }
                        // The reader hands out empty marker buffers too; only real samples are copied.
                        guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                        if !pair.input.append(sample) {
                            outcome.fail()
                            end()
                            return
                        }
                    }
                }
            }
            group.notify(queue: .global()) { done.resume() }
        }

        if outcome.failed || reader.status == .failed {
            let why = writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "copy failed"
            writer.cancelWriting()
            reader.cancelReading()
            try? fm.removeItem(at: partial)
            if cancelled() { throw CancellationError() }
            throw Failure.writer(why)
        }
        writer.endSession(atSourceTime: range.end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? fm.removeItem(at: partial)
            throw Failure.writer(writer.error?.localizedDescription ?? "didn't finish")
        }
        try fm.moveItem(at: partial, to: destination)
        progress(1)
    }

    /// One timecode sample holding the source's first value, lasting `duration`.
    private static func makeTimecodeSample(format: CMFormatDescription, data: Data, start: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let length = data.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var size = length
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
