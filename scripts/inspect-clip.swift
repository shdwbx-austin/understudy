// Prints a QuickTime clip's video codec, size, frame rate, frame count and start timecode as JSON.
//
//   swift scripts/inspect-clip.swift clip.mov
//
// Frames are counted from the container's samples without decoding, so it works for codecs
// macOS can't decode (NotchLC).
import AVFoundation
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: inspect-clip.swift clip.mov\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let asset = AVURLAsset(url: url)

func fourCC(_ v: FourCharCode) -> String {
    String([24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((v >> $0) & 0xFF))) })
}

guard let track = asset.tracks(withMediaType: .video).first else {
    print(#"{"error":"no video track"}"#)
    exit(1)
}
let desc = track.formatDescriptions.first.map { $0 as! CMFormatDescription }
let codec = desc.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
let dims = desc.map { CMVideoFormatDescriptionGetDimensions($0) }

// Count video samples.
var frames = 0
if let reader = try? AVAssetReader(asset: asset) {
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    output.alwaysCopiesSampleData = false
    reader.add(output)
    if reader.startReading() {
        while let s = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(s) }
    }
}

// Start timecode from the tmcd track.
var timecode = "none"
if let tc = asset.tracks(withMediaType: .timecode).first, let reader = try? AVAssetReader(asset: asset) {
    let output = AVAssetReaderTrackOutput(track: tc, outputSettings: nil)
    reader.add(output)
    // The first buffers can be empty markers; use the first one with data.
    var first: CMSampleBuffer?
    if reader.startReading() {
        while let s = output.copyNextSampleBuffer() {
            if CMSampleBufferGetDataBuffer(s) != nil { first = s; break }
        }
    }
    if let s = first, let block = CMSampleBufferGetDataBuffer(s), let fd = CMSampleBufferGetFormatDescription(s) {
        var raw: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &raw) { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: $0.baseAddress!) }
        let n = Int(UInt32(bigEndian: raw))
        let q = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(fd))
        if q > 0 {
            timecode = String(format: "%02d:%02d:%02d:%02d", n / (q * 3600) % 24, n / (q * 60) % 60, n / q % 60, n % q)
        }
    }
}

let info: [String: Any] = [
    "file": url.lastPathComponent,
    "codec": codec,
    "width": Int(dims?.width ?? 0),
    "height": Int(dims?.height ?? 0),
    "fps": Double(track.nominalFrameRate),
    "frames": frames,
    "duration": CMTimeGetSeconds(asset.duration),
    "timecode": timecode,
]
let data = try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
