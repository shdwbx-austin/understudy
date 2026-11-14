import XCTest
@testable import Cam4ProgCore

final class LTCTests: XCTestCase {
    private func decode(_ samples: [Float], sampleRate: Double) -> [LTCFrame] {
        let decoder = LTCDecoder(sampleRate: sampleRate)
        var frames: [LTCFrame] = []
        samples.withUnsafeBufferPointer { buf in
            decoder.process(buf.baseAddress!, count: buf.count) { frames.append($0) }
        }
        return frames
    }

    func testDecodesEncodedLTCAcrossRates() {
        let start = Timecode("00:59:59:00")!
        for sampleRate in [44_100.0, 48_000.0, 96_000.0] {
            for rate in [FrameRate.fps23_976, .fps24, .fps25, .fps29_97DF, .fps30] {
                let audio = LTCEncoder.render(start: start, frameCount: 60, rate: rate, sampleRate: sampleRate)
                for signal in [audio, audio.map { -$0 * 0.3 }] {
                    let frames = decode(signal, sampleRate: sampleRate)
                    XCTAssertGreaterThanOrEqual(frames.count, 58, "\(rate) @ \(sampleRate)")
                    guard let first = frames.first else { continue }
                    let firstIndex = first.timecode.frameIndex(at: rate)
                    for (k, f) in frames.enumerated() {
                        XCTAssertEqual(f.timecode, Timecode(frameIndex: firstIndex + k, rate: rate))
                        XCTAssertEqual(f.dropFrameFlag, rate.isDropFrame)
                    }
                }
            }
        }
    }

    func testClockRollsAndDetectsJumps() {
        var clock = LTCClock(rate: .fps25)
        let start = Timecode("10:00:00:00")!.frameIndex(at: .fps25)
        for k in 0..<10 {
            clock.ingest(Timecode(frameIndex: start + k, rate: .fps25), dropFrameFlag: false, boundaryTime: Double(k + 1) / 25)
        }
        let now = 10.0 / 25 + 0.02
        XCTAssertTrue(clock.isRolling(at: now))
        XCTAssertEqual(clock.position(at: now)!, Double(start + 10) + 0.5, accuracy: 1e-6)
        XCTAssertFalse(clock.snapshot(at: now).jumped)

        clock.ingest(Timecode(frameIndex: start + 500, rate: .fps25), dropFrameFlag: false, boundaryTime: 11.0 / 25)
        XCTAssertTrue(clock.snapshot(at: 11.0 / 25).jumped)
        XCTAssertFalse(clock.isRolling(at: 2.0))
    }
}
