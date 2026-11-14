import Testing
@testable import Cam4ProgCore

struct HyperDeckProtocolTests {
    @Test func parsesInterleavedResponsesByteByByte() throws {
        let wire = "500 connection info:\r\nprotocol version: 1.13\r\nmodel: HyperDeck Studio 4K Pro\r\n\r\n200 ok\r\n208 transport info:\r\nstatus: play\r\nclip id: 3\r\ndisplay timecode: 01:00:10:12\r\nvideo format: 2160p5994\r\n\r\n"
        var parser = HyperDeckResponseParser()
        var responses: [HyperDeckResponse] = []
        for byte in Array(wire.utf8) { responses += parser.feed([byte]) }
        try #require(responses.count == 3)
        #expect(responses[0].isAsync)
        #expect(responses[0].fields["model"] == "HyperDeck Studio 4K Pro")
        #expect(responses[1].code == 200)
        var info = TransportInfo()
        info.merge(responses[2].fields)
        #expect(info.status == .play)
        #expect(info.clipID == 3)
        #expect(info.displayTimecode == Timecode("01:00:10:12"))
        #expect(info.videoFormat == "2160p5994")
    }

    @Test func parsesClipsV1AndV2() throws {
        var parser = HyperDeckResponseParser()
        let wire = "205 clips info:\r\nclip count: 2\r\n1: 01:00:00:00 00:03:42:10 00:00:00:00 00:03:42:10 ME1_0001.mov\r\n2: ME1 take two.mov 01:00:00:00 00:01:00:00\r\n\r\n"
        let r = try #require(parser.feed(Array(wire.utf8)).first)
        let clips = DeckClip.parse(r)
        try #require(clips.count == 2)
        #expect(clips[0].id == 1)
        #expect(clips[0].start == Timecode("01:00:00:00"))
        #expect(clips[0].duration == Timecode("00:03:42:10"))
        #expect(clips[0].name == "ME1_0001.mov")
        #expect(clips[1].name == "ME1 take two.mov")
    }

    @Test func commands() {
        #expect(HyperDeckCommand.gotoClip(id: 4, frame: 1200) == "goto: clip id: 4 clip: 1200")
        #expect(HyperDeckCommand.recordPrefix("ME 1/PGM") == "configuration: record prefix: ME_1_PGM")
        #expect(HyperDeckCommand.preview(true) == "preview: enable: true")
        #expect(HyperDeckCommand.timecodePreference(dropFrame: true) == "configuration: timecode preference: dropframe")
        #expect(HyperDeckCommand.timecodeInputInternal == "configuration: timecode input: internal")
    }
}
