import Foundation
import Testing
@testable import UnderstudyCore

struct RecorderTests {
    // MARK: Deck slots

    @Test func oldDeckConfigLoadsAsHyperDeck() throws {
        let json = #"{"id":0,"name":"ME 1","host":"10.255.255.1","enabled":true,"playOffsetFrames":2}"#
        let config = try JSONDecoder().decode(DeckConfig.self, from: Data(json.utf8))
        #expect(config.kind == .hyperdeck)
        #expect(config.isAssigned)
        #expect(config.networkHost == "10.255.255.1")
        #expect(config.recorder == RecorderSettings())
    }

    @Test func recorderSlotRoundTrips() throws {
        var config = DeckConfig(id: 2, name: "ME 3", host: "")
        #expect(!config.isAssigned)
        config.kind = .recorder
        #expect(!config.isAssigned)   // no source yet
        config.recorder = RecorderSettings(source: RecorderSource(kind: .ndi, id: "STUDIO (Program)", name: "STUDIO (Program)"),
                                           codec: .proResProxy)
        #expect(config.isAssigned)
        #expect(config.networkHost == nil)
        let back = try JSONDecoder().decode(DeckConfig.self, from: JSONEncoder().encode(config))
        #expect(back == config)
        #expect(back.recorder.source?.label == "NDI · STUDIO (Program)")
    }

    @Test func recorderHostIsNotAnAddress() {
        // A recorder slot that once was a HyperDeck keeps the old address but doesn't use it.
        let config = DeckConfig(id: 0, name: "ME 1", host: "10.255.255.9", kind: .recorder,
                                recorder: RecorderSettings(source: .testPattern))
        #expect(config.networkHost == nil)
        #expect(config.isAssigned)
    }

    @Test func unknownCodecFallsBackToH264() throws {
        let json = #"{"source":{"kind":"testPattern","id":"bars","name":"Test pattern"},"codec":"dnxhr"}"#
        let settings = try JSONDecoder().decode(RecorderSettings.self, from: Data(json.utf8))
        #expect(settings.codec == .h264)
        #expect(settings.source == .testPattern)
    }

    // MARK: Rates and formats

    @Test func nearestRate() {
        #expect(FrameRate.nearest(fps: 29.97, dropFrame: true) == .fps29_97DF)
        #expect(FrameRate.nearest(fps: 30000.0 / 1001.0, dropFrame: false) == .fps29_97)
        #expect(FrameRate.nearest(fps: 30.0, dropFrame: true) == .fps30)
        #expect(FrameRate.nearest(fps: 29.99, dropFrame: false) == .fps30)
        #expect(FrameRate.nearest(fps: 24.0, dropFrame: false) == .fps24)
        #expect(FrameRate.nearest(fps: 23.98, dropFrame: false) == .fps23_976)
        #expect(FrameRate.nearest(fps: 25.02, dropFrame: false) == .fps25)
        #expect(FrameRate.nearest(fps: 59.94, dropFrame: true) == .fps59_94DF)
        #expect(FrameRate.nearest(fps: 50, dropFrame: false) == .fps50)
        #expect(FrameRate.nearest(fps: 15, dropFrame: false) == nil)
        #expect(FrameRate.nearest(fps: 0, dropFrame: false) == nil)
        #expect(FrameRate.nearest(fps: .nan, dropFrame: false) == nil)
    }

    @Test func frameDurations() {
        #expect(FrameRate.fps29_97DF.frameDuration == (1001, 30000))
        #expect(FrameRate.fps23_976.frameDuration == (1001, 24000))
        #expect(FrameRate.fps25.frameDuration == (1, 25))
        #expect(FrameRate.fps60.frameDuration == (1, 60))
    }

    @Test func videoFormatNamesReadBackAsTheSameRate() {
        for rate in FrameRate.allCases {
            let name = RecorderFormat.videoFormat(height: 1080, rate: rate)
            #expect(FrameRate.fromVideoFormat(name, dropFrame: rate.isDropFrame) == rate, "\(name)")
        }
        #expect(RecorderFormat.videoFormat(height: 1080, rate: .fps29_97DF) == "1080p2997")
        #expect(RecorderFormat.videoFormat(height: 720, rate: .fps50) == "720p50")
    }

    @Test func durationsNeverDropLabels() {
        #expect(RecorderFormat.duration(frames: 0, nominal: 30).description == "00:00:00:00")
        #expect(RecorderFormat.duration(frames: 299, nominal: 30).description == "00:00:09:29")
        #expect(RecorderFormat.duration(frames: 30 * 3600 + 30 * 61 + 5, nominal: 30).description == "01:01:01:05")
        // Back through the deck's own reading.
        let d = RecorderFormat.duration(frames: 12_345, nominal: 25)
        #expect(d.durationFrames(nominal: 25) == 12_345)
    }

    @Test func showCodeToTimecodeIndex() {
        // 01:00:00;00 on 29.97 DF LTC, stamped on 59.94 DF video: twice the frames, same instant.
        let ltc = Double(Timecode("01:00:00;00")!.frameIndex(at: .fps29_97DF))
        let video = RecorderFormat.timecodeIndex(ltcFrames: ltc, ltcRate: .fps29_97DF, rate: .fps59_94DF)
        #expect(Timecode(frameIndex: video, rate: .fps59_94DF).display(dropFrame: true) == "01:00:00;00")
        let same = RecorderFormat.timecodeIndex(ltcFrames: ltc, ltcRate: .fps29_97DF, rate: .fps29_97DF)
        #expect(same == Int(ltc))
    }

    @Test func timeOfDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 14, minute: 30, second: 15))!
        let index = RecorderFormat.timeOfDayIndex(date, rate: .fps25, calendar: calendar)
        #expect(Timecode(frameIndex: index, rate: .fps25).description == "14:30:15:00")
    }

    // MARK: Frame clock

    @Test func steadyFramesWithJitterTakeEverySlot() {
        var clock = RecorderFrameClock(fps: 30)
        var noise = SystemRandomNumberGenerator()
        var placed: [Int] = []
        for n in 0..<300 {
            let jitter = Double.random(in: -0.4...0.4, using: &noise) / 30
            if let i = clock.place(at: 100 + Double(n) / 30 + jitter) { placed.append(i) }
        }
        #expect(placed == Array(0..<300))
        #expect(clock.dropped == 0)
        #expect(clock.skipped == 0)
        #expect(clock.length == 300)
    }

    @Test func missingFramesLeaveHeldSlotsAndCount() {
        var clock = RecorderFrameClock(fps: 25)
        for n in 0..<10 { _ = clock.place(at: Double(n) / 25) }
        // Five frames never arrive.
        #expect(clock.place(at: 15.0 / 25) == 15)
        #expect(clock.dropped == 5)
        #expect(clock.place(at: 16.0 / 25) == 16)
        #expect(clock.length == 17)
    }

    @Test func oneLateFrameDoesNotMove() {
        var clock = RecorderFrameClock(fps: 30)
        for n in 0..<5 { _ = clock.place(at: Double(n) / 30) }
        // Frame 5 arrives 1.2 frames late, frame 6 on time: both keep their slots.
        #expect(clock.place(at: 6.2 / 30) == 5)
        #expect(clock.place(at: 6.0 / 30) == 6)
        #expect(clock.dropped == 0)
    }

    @Test func fasterSourceSkipsExtraFrames() {
        // A 30 fps source into a 29.97 recording gains a frame every ~33 s.
        var clock = RecorderFrameClock(fps: 30000.0 / 1001.0)
        var placed = 0
        for n in 0..<(30 * 120) where clock.place(at: Double(n) / 30) != nil { placed += 1 }
        #expect(clock.skipped >= 2 && clock.skipped <= 4)
        #expect(placed + clock.skipped == 30 * 120)
        #expect(clock.dropped == 0)
    }

    @Test func burstAfterStallDropsThenSkips() {
        var clock = RecorderFrameClock(fps: 30)
        for n in 0..<10 { _ = clock.place(at: Double(n) / 30) }
        // 100 ms stall, then three frames at once.
        let t = 13.0 / 30
        #expect(clock.place(at: t) == 13)
        #expect(clock.dropped == 3)
        // One frame may run up to 1.5 frames ahead of real time; the rest of the burst is left out.
        #expect(clock.place(at: t + 0.001) == 14)
        #expect(clock.place(at: t + 0.002) == nil)
        #expect(clock.place(at: t + 0.003) == nil)
        #expect(clock.skipped == 2)
        // Back on time, it carries on from the next slot.
        #expect(clock.place(at: 15.0 / 30) == 15)
    }

    @Test func unplacedFrameCountsAsDropped() {
        var clock = RecorderFrameClock(fps: 30)
        _ = clock.place(at: 0)
        let i = clock.place(at: 1.0 / 30)!
        clock.unplace(i)
        #expect(clock.dropped == 1)
        #expect(clock.place(at: 2.0 / 30) == 2)
        #expect(clock.length == 3)
    }

    // MARK: Takes

    @Test func takeNamesCountUpLikeADeck() {
        var list = RecorderTakeList()
        #expect(list.nextName(prefix: "ME 1") == "ME 1_0001.mov")
        list.add(take(id: 1, name: "ME 1_0001.mov"))
        #expect(list.nextName(prefix: "ME 1") == "ME 1_0002.mov")
        #expect(list.nextName(prefix: "ME 2") == "ME 2_0001.mov")
        #expect(list.nextName(prefix: "ME 1") { $0 == "ME 1_0002.mov" } == "ME 1_0003.mov")
        #expect(list.nextName(prefix: "a/b: c") == "a-b- c_0001.mov")
        #expect(list.nextName(prefix: "  ") == "Recorder_0001.mov")
        #expect(list.nextID == 2)
    }

    @Test func takeIsAClipStampedWithItsCode() {
        let start = Timecode("01:00:00;00")!.frameIndex(at: .fps29_97DF)
        let t = RecorderTake(id: 3, name: "ME 1_0003.mov", path: "/x/ME 1_0003.mov", startFrame: start, frames: 304,
                             rate: .fps29_97DF, videoFormat: "1080p2997", codec: .h264)
        let clip = t.clip
        #expect(clip.id == 3)
        #expect(clip.name == "ME 1_0003.mov")
        #expect(clip.start.display(dropFrame: true) == "01:00:00;00")
        #expect(clip.duration.description == "00:00:10:04")
        // The deck span AppModel computes for this clip.
        let s = clip.start.seconds(at: .fps29_97DF)
        let e = s + Double(clip.duration.durationFrames(nominal: 30)) / FrameRate.fps29_97DF.exact
        #expect(abs((e - s) - 304 / FrameRate.fps29_97DF.exact) < 1e-9)
    }

    @Test func clipsSkipMissingFiles() {
        var list = RecorderTakeList()
        list.add(take(id: 2, name: "b.mov"))
        list.add(take(id: 1, name: "a.mov"))
        #expect(list.takes.map(\.id) == [1, 2])
        #expect(list.clips { $0 != "/takes/a.mov" }.map(\.name) == ["b.mov"])
        #expect(list.take(named: "a.mov")?.id == 1)
    }

    @Test func takeListRoundTrips() throws {
        var list = RecorderTakeList()
        list.add(take(id: 1, name: "a.mov"))
        let back = try JSONDecoder().decode(RecorderTakeList.self, from: JSONEncoder().encode(list))
        #expect(back == list)
    }

    private func take(id: Int, name: String) -> RecorderTake {
        RecorderTake(id: id, name: name, path: "/takes/\(name)", startFrame: 0, frames: 30, rate: .fps30,
                     videoFormat: "1080p30", codec: .hevc, createdAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: Health

    @Test func healthyRecordingHasNoWarnings() {
        var h = RecorderHealth()
        h.sourceOpen = true
        h.recording = true
        h.secondsSinceFrame = 0.03
        h.bytesPerSecond = 2_500_000
        h.freeBytes = 500_000_000_000
        #expect(h.warnings.isEmpty)
        #expect(h.secondsLeft == 200_000)
    }

    @Test func lostSignalWhileRecordingIsAnAlarm() {
        var h = RecorderHealth()
        h.sourceOpen = true
        h.secondsSinceFrame = 2
        #expect(h.warnings == [RecorderWarning(.caution, "NO SIGNAL")])
        h.recording = true
        #expect(h.warnings == [RecorderWarning(.alarm, "NO SIGNAL")])
        h.secondsSinceFrame = nil
        #expect(h.warnings.map(\.text) == ["WAITING FOR PICTURE"])
    }

    @Test func droppedFramesAndASlowEncoderSayWhat() {
        var h = RecorderHealth()
        h.recording = true
        h.droppedFrames = 1
        #expect(h.warnings.map(\.text) == ["1 FRAME DROPPED"])
        h.droppedFrames = 12
        h.recentEncoderDrops = 3
        h.skippedFrames = 2
        #expect(h.warnings.map(\.text) == ["ENCODER OR DISK FALLING BEHIND", "12 FRAMES DROPPED", "2 EXTRA SOURCE FRAMES LEFT OUT"])
        #expect(h.warnings.first?.level == .alarm)
        #expect(h.warnings.last?.level == .note)
    }

    @Test func diskWarningsUseTheLiveOrExpectedRate() {
        var h = RecorderHealth()
        h.freeBytes = 1_000_000_000
        #expect(h.secondsLeft == nil)
        h.estimatedBytesPerSecond = 2_000_000          // 500 s: under 10 min
        #expect(h.warnings == [RecorderWarning(.caution, "DISK: 8 MIN LEFT")])
        h.bytesPerSecond = 10_000_000                  // live rate wins: 100 s
        #expect(h.warnings == [RecorderWarning(.alarm, "DISK: 1 MIN LEFT")])
        h.freeBytes = 300_000_000                      // 30 s
        #expect(h.warnings == [RecorderWarning(.alarm, "DISK: 30 S LEFT")])
        h.freeBytes = 100_000_000_000
        #expect(h.warnings.isEmpty)
    }

    @Test func softwareEncoderIsANote() {
        var h = RecorderHealth()
        h.softwareEncoder = true
        #expect(h.warnings == [RecorderWarning(.note, "SOFTWARE ENCODER: HEAVY ON THIS MAC")])
    }

    @Test func rateText() {
        #expect(RecorderHealth.rateText(nil) == "—")
        #expect(RecorderHealth.rateText(18_400_000) == "18.4 MB/s")
    }

    @Test func codecRates() {
        // 1080p29.97 targets.
        let fps = FrameRate.fps29_97.exact
        #expect(abs(Double(RecorderCodec.h264.targetBitRate(width: 1920, height: 1080, fps: fps)) - 20e6) < 1e6)
        #expect(abs(Double(RecorderCodec.hevc.targetBitRate(width: 1920, height: 1080, fps: fps)) - 12.4e6) < 1e6)
        #expect(abs(RecorderCodec.proRes422.estimatedBytesPerSecond(width: 1920, height: 1080, fps: fps) * 8 - 147e6) < 5e6)
        #expect(RecorderCodec.proResProxy.isProRes && !RecorderCodec.hevc.isProRes)
        #expect(Set(RecorderCodec.allCases.map(\.fourCC)) == ["avc1", "hvc1", "apco", "apcn"])
    }
}
