// Writes a short ProRes 422 test clip with a QuickTime timecode track, for checking transcodes.
//
//   swift scripts/make-test-clip.swift out.mov [frames=100] [fps=25] [start=01:00:00:00] [width=1280] [height=720]
//
// fps is a whole number (24, 25, 30, 50…) or 23.976, 29.97, 59.94 (non-drop timecode).
//
// Every frame is different (a moving bar and a frame counter drawn as blocks), so dropped or
// repeated frames show up when the result is decoded.
import AVFoundation
import CoreVideo
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-test-clip.swift out.mov [frames] [fps] [start] [w] [h]\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: args[1])
let frames = args.count > 2 ? Int(args[2]) ?? 100 : 100
let rate = args.count > 3 ? args[3] : "25"
// One frame lasts `frameValue / timescale`; the timecode counts `quanta` frames a second.
let (frameValue, timescale, quanta): (CMTimeValue, Int32, Int32) = {
    switch rate {
    case "23.976", "23.98": return (1001, 24000, 24)
    case "29.97": return (1001, 30000, 30)
    case "59.94": return (1001, 60000, 60)
    default: let n = Int32(rate) ?? 25; return (1, n, n)
    }
}()
func frameTime(_ i: Int) -> CMTime { CMTime(value: CMTimeValue(i) * frameValue, timescale: timescale) }
let start = args.count > 4 ? args[4] : "01:00:00:00"
let width = args.count > 5 ? Int(args[5]) ?? 1280 : 1280
let height = args.count > 6 ? Int(args[6]) ?? 720 : 720

try? FileManager.default.removeItem(at: out)
let writer = try AVAssetWriter(outputURL: out, fileType: .mov)

let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.proRes422,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
])
video.expectsMediaDataInRealTime = false
video.mediaTimeScale = timescale   // 29.97 needs 30000; the default 600 rounds frame lengths
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
])

// Timecode track (tmcd), one sample holding the start frame number.
var tcFormat: CMTimeCodeFormatDescription?
CMTimeCodeFormatDescriptionCreate(allocator: nil, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
                                  frameDuration: frameTime(1), frameQuanta: UInt32(quanta),
                                  flags: kCMTimeCodeFlag_24HourMax, extensions: nil, formatDescriptionOut: &tcFormat)
let timecode = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: tcFormat)
timecode.mediaTimeScale = timescale
writer.movieTimeScale = timescale
video.addTrackAssociation(withTrackOf: timecode, type: AVAssetTrack.AssociationType.timecode.rawValue)

writer.add(video)
writer.add(timecode)
guard writer.startWriting() else { fatalError("can't write: \(writer.error.map { "\($0)" } ?? "?")") }
writer.startSession(atSourceTime: .zero)

func startFrame(_ s: String, fps: Int32) -> Int32 {
    let p = s.split(whereSeparator: { ":;.".contains($0) }).compactMap { Int32($0) }
    guard p.count == 4 else { return 0 }
    return ((p[0] * 60 + p[1]) * 60 + p[2]) * fps + p[3]
}

func fill(_ buffer: CVPixelBuffer, frame: Int) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let barX = (frame * 16) % width
    for y in 0..<height {
        let row = base + y * stride
        for x in 0..<width {
            let p = row + x * 4
            // Background gradient, a white bar that moves 16 px per frame.
            var b = UInt8(x * 255 / width), g = UInt8(y * 255 / height), r = UInt8(80)
            if x >= barX && x < barX + 16 { b = 255; g = 255; r = 255 }
            p[0] = b; p[1] = g; p[2] = r; p[3] = 255
        }
    }
    // Frame number in binary as 16 blocks along the top: white = 1, black = 0.
    let block = width / 20
    for bit in 0..<16 {
        let on = (frame >> (15 - bit)) & 1 == 1
        for y in 8..<(8 + block) {
            let row = base + y * stride
            for x in (bit * block + block / 2)..<(bit * block + block / 2 + block - 4) {
                let p = row + x * 4
                let v: UInt8 = on ? 255 : 0
                p[0] = v; p[1] = v; p[2] = v
            }
        }
    }
}

// The single timecode sample covers the whole clip. It goes in first: the writer interleaves
// tracks, so video stalls if the timecode track has nothing yet.
var tcValue = startFrame(start, fps: quanta).bigEndian
var block: CMBlockBuffer?
CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 4, blockAllocator: nil,
                                   customBlockSource: nil, offsetToData: 0, dataLength: 4, flags: 0, blockBufferOut: &block)
CMBlockBufferReplaceDataBytes(with: &tcValue, blockBuffer: block!, offsetIntoDestination: 0, dataLength: 4)
var timing = CMSampleTimingInfo(duration: frameTime(frames),
                                presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
var size = 4
var sample: CMSampleBuffer?
CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                     formatDescription: tcFormat, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                     sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
while !timecode.isReadyForMoreMediaData { usleep(1000) }
timecode.append(sample!)
timecode.markAsFinished()

for i in 0..<frames {
    while !video.isReadyForMoreMediaData { usleep(1000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    fill(buffer!, frame: i)
    adaptor.append(buffer!, withPresentationTime: frameTime(i))
}
video.markAsFinished()


writer.endSession(atSourceTime: frameTime(frames))
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fatalError("write failed: \(writer.error.map { "\($0)" } ?? "?")") }
print("\(out.path): \(frames) frames at \(rate) fps, \(width)x\(height), starts \(start)")
