import Foundation
import Testing
@testable import UnderstudyCore

@Suite("Dante out")
struct DanteOutTests {
    let speakers = DanteOut.Device(uid: "BuiltIn", name: "MacBook Pro Speakers", channels: 2)
    let fireface = DanteOut.Device(uid: "RME", name: "Fireface UCX II", channels: 20)
    let dvs = DanteOut.Device(uid: "DVS", name: "Dante Virtual Soundcard", channels: 8)

    @Test func findsTheVirtualSoundcard() {
        #expect(DanteOut.soundcard(in: [speakers, fireface, dvs]) == dvs)
        #expect(DanteOut.soundcard(in: [speakers, fireface]) == nil)
        let short = DanteOut.Device(uid: "x", name: "DVS", channels: 4)
        #expect(DanteOut.soundcard(in: [speakers, short]) == short)
        // The soundcard by name wins over another Dante-named device.
        let via = DanteOut.Device(uid: "via", name: "Dante Via", channels: 16)
        #expect(DanteOut.soundcard(in: [via, dvs]) == dvs)
        #expect(DanteOut.soundcard(in: [speakers, via]) == via)
        // The driver's model ID wins whatever DVS calls the device.
        let byModel = DanteOut.Device(uid: "m", name: "Studio Mac", channels: 8, model: "AUDINATE-DVS-MODEL-ID")
        #expect(DanteOut.soundcard(in: [via, dvs, byModel]) == byModel)
    }

    @Test func status() {
        #expect(DanteOut.status(enabled: false, soundcard: dvs, port: nil, portLinked: true) == .off)
        #expect(DanteOut.status(enabled: true, soundcard: nil, port: nil, portLinked: true) == .noSoundcard)
        let two = DanteOut.Device(uid: "DVS", name: "Dante Virtual Soundcard", channels: 2)
        #expect(DanteOut.status(enabled: true, soundcard: two, port: nil, portLinked: true)
                == .tooFewChannels(device: "Dante Virtual Soundcard", channels: 2))
        #expect(DanteOut.status(enabled: true, soundcard: dvs, port: nil, portLinked: false)
                == .sending(device: "Dante Virtual Soundcard", port: nil))
        #expect(DanteOut.status(enabled: true, soundcard: dvs, port: "Dante (en8)", portLinked: true)
                == .sending(device: "Dante Virtual Soundcard", port: "Dante (en8)"))
        let down = DanteOut.status(enabled: true, soundcard: dvs, port: "Dante (en8)", portLinked: false)
        #expect(down == .portDown(device: "Dante Virtual Soundcard", port: "Dante (en8)"))
        #expect(down.isRouted && down.isProblem)
        #expect(!DanteOut.Status.noSoundcard.isRouted)
    }

    @Test func settingsRoundTripAndOldSettingsLoad() throws {
        var settings = AppSettings()
        #expect(!settings.danteOut && settings.danteInterface == nil)
        settings.danteOut = true
        settings.danteInterface = "en8"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.danteOut && decoded.danteInterface == "en8")
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"ltcOutUseTrackTimecode": false}"#.utf8))
        #expect(!old.danteOut && old.danteInterface == nil && !old.ltcOutUseTrackTimecode)
    }

    @Test func extraSongOutputsRoundTripAndOldSettingsHaveNone() throws {
        var settings = AppSettings()
        #expect(settings.extraSongOutputs.isEmpty)
        settings.extraSongOutputs = [SongOutput(deviceUID: "headphones"), SongOutput(deviceUID: nil, channel: 2)]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.extraSongOutputs == settings.extraSongOutputs)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"timelineOutputChannel": 2}"#.utf8))
        #expect(old.extraSongOutputs.isEmpty && old.timelineOutputChannel == 2)
    }

    @Test func devRecordSendsTrackTimecodeAfterTheMusic() {
        // SHDWBX-style 4-channel device, music on 1–2: timecode on 3.
        #expect(DevTimecodeOut.channel(recordingFromTimeline: true, ltcOutSet: false, musicChannel: 0, deviceChannels: 4) == 2)
        // Music on 3–4 of an 8-channel interface: timecode on 5.
        #expect(DevTimecodeOut.channel(recordingFromTimeline: true, ltcOutSet: false, musicChannel: 2, deviceChannels: 8) == 4)
        // A stereo device has no spare channel.
        #expect(DevTimecodeOut.channel(recordingFromTimeline: true, ltcOutSet: false, musicChannel: 0, deviceChannels: 2) == nil)
        // LTC out set: that wins. Not recording from the timeline: nothing.
        #expect(DevTimecodeOut.channel(recordingFromTimeline: true, ltcOutSet: true, musicChannel: 0, deviceChannels: 4) == nil)
        #expect(DevTimecodeOut.channel(recordingFromTimeline: false, ltcOutSet: false, musicChannel: 0, deviceChannels: 4) == nil)
    }
}
