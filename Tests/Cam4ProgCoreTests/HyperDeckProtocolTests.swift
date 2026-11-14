import XCTest
@testable import Cam4ProgCore

final class HyperDeckProtocolTests: XCTestCase {
    func testParsesInterleavedResponsesByteByByte() {
        let wire = "500 connection info:\r\nprotocol version: 1.13\r\nmodel: HyperDeck Studio 4K Pro\r\n\r\n200 ok\r\n208 transport info:\r\nstatus: play\r\nclip id: 3\r\ndisplay timecode: 01:00:10:12\r\nvideo format: 2160p5994\r\n\r\n"
        var parser = HyperDeckResponseParser()
        var responses: [HyperDeckResponse] = []
        for byte in Array(wire.utf8) { responses += parser.feed([byte]) }
        XCTAssertEqual(responses.count, 3)
        XCTAssertTrue(responses[0].isAsync)
        XCTAssertEqual(responses[0].fields["model"], "HyperDeck Studio 4K Pro")
        XCTAssertEqual(responses[1].code, 200)
        var info = TransportInfo()
        info.merge(responses[2].fields)
        XCTAssertEqual(info.status, .play)
        XCTAssertEqual(info.clipID, 3)
        XCTAssertEqual(info.displayTimecode, Timecode("01:00:10:12"))
        XCTAssertEqual(info.videoFormat, "2160p5994")
    }

    func testParsesClipsV1AndV2() {
        var parser = HyperDeckResponseParser()
        let wire = "205 clips info:\r\nclip count: 2\r\n1: 01:00:00:00 00:03:42:10 00:00:00:00 00:03:42:10 ME1_0001.mov\r\n2: ME1 take two.mov 01:00:00:00 00:01:00:00\r\n\r\n"
        let r = parser.feed(Array(wire.utf8))[0]
        let clips = DeckClip.parse(r)
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].id, 1)
        XCTAssertEqual(clips[0].start, Timecode("01:00:00:00"))
        XCTAssertEqual(clips[0].duration, Timecode("00:03:42:10"))
        XCTAssertEqual(clips[0].name, "ME1_0001.mov")
        XCTAssertEqual(clips[1].name, "ME1 take two.mov")
    }

    func testCommands() {
        XCTAssertEqual(HyperDeckCommand.gotoClip(id: 4, frame: 1200), "goto: clip id: 4 clip: 1200")
        XCTAssertEqual(HyperDeckCommand.recordPrefix("ME 1/PGM"), "configuration: record prefix: ME_1_PGM")
        XCTAssertEqual(HyperDeckCommand.preview(true), "preview: enable: true")
    }
}
