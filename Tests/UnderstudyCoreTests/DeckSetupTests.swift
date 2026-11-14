import Testing
@testable import UnderstudyCore

struct DeckSetupTests {
    private func parse(_ wire: String) throws -> HyperDeckResponse {
        var parser = HyperDeckResponseParser()
        return try #require(parser.feed(Array(wire.utf8)).first)
    }

    @Test func readsConfiguration() throws {
        let r = try parse("211 configuration:\r\naudio input: embedded\r\nvideo input: SDI\r\nfile format: QuickTimeProResHQ\r\ntimecode input: internal\r\nrecord cache: false\r\n\r\n")
        #expect(r.code == 211)
        #expect(r.fields["file format"] == "QuickTimeProResHQ")
        #expect(r.fields["video input"] == "SDI")
    }

    @Test func readsDeviceAndSlots() throws {
        let d = DeckDeviceInfo(fields: try parse("204 device info:\r\nprotocol version: 1.13\r\nmodel: HyperDeck Extreme 8K HDR\r\nunique id: 7c2e\r\nslot count: 3\r\nsoftware version: 9.0\r\nname: PGM\r\n\r\n").fields)
        #expect(d.model == "HyperDeck Extreme 8K HDR")
        #expect(d.slotCount == 3)
        #expect(d.softwareVersion == "9.0")

        let s = try #require(DeckSlotInfo(fields: try parse("202 slot info:\r\nslot id: 1\r\nslot name: cfast1\r\nstatus: mounted\r\nvolume name: REH_A\r\nrecording time: 5025\r\nvideo format: 2160p5994\r\nremaining size: 250000000000\r\ntotal size: 1000000000000\r\n\r\n").fields))
        #expect(s.isMounted)
        #expect(s.volumeName == "REH_A")
        #expect(s.recordingTimeText == "1 h 23 min")
        #expect(abs((s.usedFraction ?? 0) - 0.75) < 1e-9)
        #expect(DeckSlotInfo(fields: ["status": "empty"]) == nil)
    }

    @Test func parametersAreConsistent() {
        #expect(Set(DeckParameter.all.map(\.key)).count == DeckParameter.all.count)
        for p in DeckParameter.all where p.group == .managed { #expect(!p.isEditable) }
        #expect(DeckParameter.named("file format")?.rebootsDeck == true)
        #expect(DeckParameter.named("video input")?.values.contains("4xSDI") == false)
        #expect(DeckParameter.named("file format")?.label(for: "QuickTimeProResHQ") == "ProRes 422 HQ")
        #expect(DeckSetupCommand.set("record cache", "true") == "configuration: record cache: true")
    }

    @Test func mediaTimeAcrossSlots() {
        let a = DeckSlotInfo(fields: ["slot id": "1", "status": "mounted", "recording time": "1500"])!
        let b = DeckSlotInfo(fields: ["slot id": "2", "status": "mounted", "recording time": "3600"])!
        let empty = DeckSlotInfo(fields: ["slot id": "3", "status": "empty", "recording time": "0"])!
        #expect(MediaTime.secondsLeft([a, b, empty]) == 5100)
        #expect(MediaTime.secondsLeft([]) == nil)
        #expect(MediaTime.secondsLeft([empty]) == 0)
        #expect(MediaTime.level(5100) == .ok)
        #expect(MediaTime.level(1500) == .low)
        #expect(MediaTime.level(500) == .critical)
        #expect(MediaTime.level(0) == .none)
        #expect(MediaTime.level(nil) == .ok)
        #expect(MediaTime.text(5100) == "1 h 25 min")
        #expect(MediaTime.text(1500) == "25 min")
        #expect(MediaTime.text(0) == "NO MEDIA")
    }

    @Test func findsMismatches() {
        let m = deckSettingMismatches([
            0: ["file format": "QuickTimeProResHQ", "audio codec": "PCM", "timecode input": "internal"],
            1: ["file format": "H.265High", "audio codec": "PCM", "timecode input": "external"],
            2: ["file format": "QuickTimeProResHQ"],
        ])
        #expect(m.keys.sorted() == ["file format"])   // timecode input is managed, not flagged
        #expect(m["file format"]?[1] == "H.265High")
    }
}
