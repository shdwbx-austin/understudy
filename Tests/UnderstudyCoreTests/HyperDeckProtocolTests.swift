import Testing
@testable import UnderstudyCore

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

    @Test func recognisesGreeting() throws {
        var parser = HyperDeckResponseParser()
        let hello = "500 connection info:\r\nprotocol version: 1.13\r\nmodel: HyperDeck Studio HD Pro\r\n\r\n"
        let r = try #require(parser.feed(Array(hello.utf8)).first)
        let g = try #require(HyperDeckGreeting.recognise(r))
        #expect(g.model == "HyperDeck Studio HD Pro")
        #expect(g.protocolVersion == "1.13")
        #expect(!g.busy)

        var busyParser = HyperDeckResponseParser()
        let busy = try #require(busyParser.feed(Array("120 connection failed\r\n".utf8)).first)
        #expect(HyperDeckGreeting.recognise(busy)?.busy == true)

        var other = HyperDeckResponseParser()
        let ssh = other.feed(Array("SSH-2.0-OpenSSH_9.6\r\n".utf8))
        #expect(ssh.isEmpty || HyperDeckGreeting.recognise(ssh[0]) == nil)
        #expect(HyperDeckGreeting.recognise(HyperDeckResponse(code: 200, text: "ok")) == nil)
    }

    @Test func clipsVersion2WithSpacesAndCount() throws {
        // As documented for clips get: version: 2 — id: in duration in out filename (spaces allowed).
        var parser = HyperDeckResponseParser()
        let wire = "205 clips info:\r\nclip count: 2\r\n1: 00:00:00:00 00:01:00:00 00:00:00:00 00:01:00:00 PGM take 1.mov\r\n2: 01:00:00:00 00:00:30:00 00:00:00:00 00:00:30:00 PGM_0002.mov\r\n\r\n"
        let r = try #require(parser.feed(Array(wire.utf8)).first)
        let clips = DeckClip.parse(r)
        try #require(clips.count == 2)
        #expect(clips[0].name == "PGM take 1.mov")
        #expect(clips[1].start == Timecode("01:00:00:00"))
        #expect(clips[1].duration == Timecode("00:00:30:00"))
    }

    @Test func hintsForFixableFailures() {
        #expect(HyperDeckResponse(code: 122, text: "authentication required").hint?.contains("Enabled") == true)
        #expect(HyperDeckResponse(code: 120, text: "connection failed").hint != nil)
        #expect(HyperDeckResponse(code: 102, text: "syntax error").hint == nil)
    }

    @Test func lostInputClearsFormat() {
        var info = TransportInfo()
        info.merge(["input video format": "2160p5994", "video format": "2160p5994"])
        #expect(info.inputVideoFormat == "2160p5994")
        #expect(info.reportsInput)
        info.merge(["status": "preview"])                 // async update without the field: keep it
        #expect(info.inputVideoFormat == "2160p5994")
        info.merge(["input video format": "none"])         // signal lost
        #expect(info.inputVideoFormat == nil)
        #expect(info.reportsInput)
        #expect(!TransportInfo().reportsInput)
    }

    @Test func commands() {
        // The deck counts clip frames from 1 (measured on a HyperDeck Studio 4K Pro, 9.0.2).
        #expect(HyperDeckCommand.gotoClip(id: 4, frame: 1200) == "goto: clip id: 4 clip: 1201")
        #expect(HyperDeckCommand.gotoClip(id: 4, frame: 0) == "goto: clip id: 4 clip: 1")
        #expect(HyperDeckCommand.gotoFrameInClip(0) == "goto: clip: 1")
        #expect(HyperDeckCommand.recordPrefix("ME 1/PGM") == "configuration: record prefix: ME_1_PGM")
        #expect(HyperDeckCommand.preview(true) == "preview: enable: true")
        #expect(HyperDeckCommand.timecodePreference(dropFrame: true) == "configuration: timecode preference: dropframe")
        #expect(HyperDeckCommand.timecodeInputInternal == "configuration: timecode input: internal")
    }
}
