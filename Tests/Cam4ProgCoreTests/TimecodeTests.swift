import XCTest
@testable import Cam4ProgCore

final class TimecodeTests: XCTestCase {
    func testDropFrameRoundTrip() {
        for rate in [FrameRate.fps29_97DF, .fps59_94DF, .fps25, .fps23_976] {
            for index in stride(from: 0, to: 40_000, by: 7) {
                let tc = Timecode(frameIndex: index, rate: rate)
                XCTAssertEqual(tc.frameIndex(at: rate), index, "\(rate) \(tc)")
            }
        }
    }

    func testDropFrameSkipsLabels() {
        XCTAssertEqual(Timecode(frameIndex: 1799, rate: .fps29_97DF).description, "00:00:59:29")
        XCTAssertEqual(Timecode(frameIndex: 1800, rate: .fps29_97DF).description, "00:01:00:02")
        XCTAssertEqual(Timecode(frameIndex: 17982, rate: .fps29_97DF).description, "00:10:00:00")
        XCTAssertEqual(Timecode(frameIndex: 3600, rate: .fps59_94DF).description, "00:01:00:04")
    }

    func testFamiliesShareLabelTime() {
        let tc = Timecode("01:00:00:00")!
        XCTAssertEqual(tc.seconds(at: .fps29_97DF), tc.seconds(at: .fps59_94DF), accuracy: 1e-9)
        XCTAssertEqual(tc.seconds(at: .fps25), tc.seconds(at: .fps50), accuracy: 1e-9)
    }

    func testParse() {
        XCTAssertEqual(Timecode("01:02:03;04"), Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4))
        XCTAssertNil(Timecode("01:02:03"))
        XCTAssertNil(Timecode("01:72:03:00"))
    }

    func testVideoFormats() {
        XCTAssertEqual(FrameRate.fromVideoFormat("2160p5994", dropFrame: true), .fps59_94DF)
        XCTAssertEqual(FrameRate.fromVideoFormat("4Kp5994", dropFrame: false), .fps59_94)
        XCTAssertEqual(FrameRate.fromVideoFormat("2160p59.94", dropFrame: false), .fps59_94)
        XCTAssertEqual(FrameRate.fromVideoFormat("1080i5994", dropFrame: true), .fps29_97DF)
        XCTAssertEqual(FrameRate.fromVideoFormat("1080p25", dropFrame: false), .fps25)
        XCTAssertEqual(FrameRate.fromVideoFormat("1080p23976", dropFrame: false), .fps23_976)
        XCTAssertNil(FrameRate.fromVideoFormat("none", dropFrame: false))
    }
}
