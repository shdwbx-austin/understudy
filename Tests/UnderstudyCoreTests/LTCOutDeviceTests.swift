import Foundation
import Testing
@testable import UnderstudyCore

@Suite("LTC out device")
struct LTCOutDeviceTests {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test func newSettingsFollowTheSongAudio() {
        var settings = AppSettings()
        settings.timelineOutputUID = "RME"
        settings.ltcOutputChannel = 2
        #expect(settings.ltcOutputDeviceUID == "RME")
    }

    @Test func aPickedDeviceIsUsed() {
        var settings = AppSettings()
        settings.timelineOutputUID = "RME"
        settings.ltcOutputFollowsSong = false
        settings.ltcOutputUID = "MOTU"
        #expect(settings.ltcOutputDeviceUID == "MOTU")
        settings.ltcOutputUID = nil
        #expect(settings.ltcOutputDeviceUID == nil)  // system default
    }

    @Test func olderSettingsWithNoLTCDeviceFollowTheSongAudio() throws {
        let settings = try decode(#"{"timelineOutputUID":"RME","ltcOutputChannel":2}"#)
        #expect(settings.ltcOutputFollowsSong)
        #expect(settings.ltcOutputDeviceUID == "RME")
    }

    @Test func olderSettingsKeepAPickedLTCDevice() throws {
        let settings = try decode(#"{"timelineOutputUID":"RME","ltcOutputUID":"MOTU","ltcOutputChannel":0}"#)
        #expect(!settings.ltcOutputFollowsSong)
        #expect(settings.ltcOutputDeviceUID == "MOTU")
    }

    @Test func roundTrips() throws {
        var settings = AppSettings()
        settings.ltcOutputFollowsSong = false
        settings.ltcOutputUID = nil
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(!back.ltcOutputFollowsSong)
        #expect(back.ltcOutputDeviceUID == nil)
    }
}
