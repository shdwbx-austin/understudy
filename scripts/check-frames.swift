// Decodes a clip made from scripts/make-test-clip.swift (or a transcode of one) and reads the
// frame counter drawn into every frame. Prints the count and whether the frames run 0, 1, 2, …
// with none dropped, repeated or out of order. Exits 1 if not.
//
//   swift scripts/check-frames.swift clip.mov [expected frames]
import AVFoundation
import CoreVideo
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: check-frames.swift clip.mov [expected]\n".utf8))
    exit(2)
}
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let expected = args.count > 2 ? Int(args[2]) : nil
guard let track = asset.tracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else {
    print("FAIL can't read \(args[1])")
    exit(1)
}
let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
])
reader.add(output)
guard reader.startReading() else {
    print("FAIL can't decode \(args[1]): \(reader.error.map { "\($0)" } ?? "?")")
    exit(1)
}

func counter(_ buffer: CVPixelBuffer) -> Int {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let width = CVPixelBufferGetWidth(buffer)
    let block = width / 20
    var n = 0
    for bit in 0..<16 {
        let x = bit * block + block / 2 + (block - 4) / 2
        let y = 8 + block / 2
        let p = base + y * stride + x * 4
        let luma = (Int(p[0]) + Int(p[1]) + Int(p[2])) / 3
        n = n << 1 | (luma > 128 ? 1 : 0)
    }
    return n
}

var frames = 0
var problems: [String] = []
while let sample = output.copyNextSampleBuffer() {
    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
    let n = counter(buffer)
    if n != frames, problems.count < 10 { problems.append("frame \(frames) reads \(n)") }
    frames += 1
}
if reader.status == .failed { problems.append("decode failed: \(reader.error.map { "\($0)" } ?? "?")") }
if let expected, frames != expected { problems.append("\(frames) frames, expected \(expected)") }
if problems.isEmpty {
    print("OK \(frames) frames decoded, counter 0…\(frames - 1) in order")
} else {
    print("FAIL " + problems.joined(separator: "; "))
    exit(1)
}
