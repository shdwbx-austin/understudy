import AudioToolbox
import AVFoundation
import Foundation
import os
import UnderstudyCore

/// Where an engine plays: a device (nil = system default) and the first device channel it uses.
struct AudioRoute: Equatable {
    var deviceUID: String?
    var channel: Int
}

/// Plays the timeline's song audio and, optionally, LTC that follows the timeline.
///
/// Song files are scheduled against host time, the same clock the transport and the chase run
/// on, so audio, LTC and decks start together. Music and LTC use separate engines, so each can go
/// to its own device and channels (e.g. music on 1–2 of the PA feed, LTC on 4 of an interface).
@MainActor
final class TimelinePlayer {
    /// What the LTC render thread needs, swapped in whole under a lock.
    private struct LTCPlan: Sendable {
        var playing = false
        var anchorPosition = 0.0
        var anchorTime = 0.0
        var layout: TimelineLayout?
    }

    private let music = AVAudioEngine()
    private let ltc = AVAudioEngine()
    private var players: [UUID: AVAudioPlayerNode] = [:]
    private var files: [String: AVAudioFile] = [:]
    private var ltcNode: AVAudioSourceNode?
    private let plan = OSAllocatedUnfairLock(initialState: LTCPlan())
    private var musicRoute = AudioRoute(deviceUID: nil, channel: 0)
    private var ltcRoute: AudioRoute?
    private var configured = false

    /// Last audio problem, for the UI (nil when fine).
    private(set) var problem: String?

    // MARK: Routing

    func configure(music route: AudioRoute, ltc ltcRoute: AudioRoute?) {
        guard !configured || route != musicRoute || ltcRoute != self.ltcRoute else { return }
        musicRoute = route
        self.ltcRoute = ltcRoute
        configured = true
        problem = nil
        stopMusic()
        music.stop()
        if !point(music, at: route, channels: [0, 1]) {
            problem = "Couldn't open the audio output for song audio."
        }
        ltc.stop()
        if let ltcRoute {
            installLTCNode()
            if !point(ltc, at: ltcRoute, channels: [0]) {
                problem = "Couldn't open the LTC output."
            }
            startLTC()
        }
    }

    /// Points an engine's output at a device and maps its stereo output onto `channels` from the
    /// route's first channel (e.g. [0, 1] → device channels 3–4 for channel 2).
    private func point(_ engine: AVAudioEngine, at route: AudioRoute, channels: [Int]) -> Bool {
        guard let unit = engine.outputNode.audioUnit else { return false }
        var device: AudioDeviceID = 0
        if let uid = route.deviceUID, let id = AudioDeviceCatalog.deviceID(forUID: uid) {
            device = id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { return false }
        } else {
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size)
        }
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let stereo = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 2)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: stereo)
        let deviceChannels = max(2, AudioDeviceCatalog.channelCount(device, scope: kAudioDevicePropertyScopeOutput))
        var map = [Int32](repeating: -1, count: deviceChannels)
        for (source, offset) in channels.enumerated() {
            let target = route.channel + offset
            if map.indices.contains(target) { map[target] = Int32(source) }
        }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Input, 0,
                             &map, UInt32(map.count * MemoryLayout<Int32>.size))
        return true
    }

    // MARK: LTC

    private func installLTCNode() {
        guard ltcNode == nil else { return }
        let rate = ltc.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = rate > 0 ? rate : 48_000
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let node = Self.makeLTCNode(format: format, sampleRate: sampleRate, plan: plan)
        ltc.attach(node)
        ltc.connect(node, to: ltc.mainMixerNode, format: format)
        ltcNode = node
    }

    /// Built outside the main actor: the render block runs on the audio thread.
    private nonisolated static func makeLTCNode(format: AVAudioFormat, sampleRate: Double,
                                                plan: OSAllocatedUnfairLock<LTCPlan>) -> AVAudioSourceNode {
        let state = LTCRenderState()
        return AVAudioSourceNode(format: format) { _, timestamp, frameCount, data in
            let list = UnsafeMutableAudioBufferListPointer(data)
            guard let out = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let current = plan.withLock { $0 }
            let host = timestamp.pointee.mFlags.contains(.hostTimeValid)
                ? AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime)
                : AVAudioTime.seconds(forHostTime: mach_absolute_time())
            var position: Double?
            if current.playing, let layout = current.layout {
                let t = current.anchorPosition + (host - current.anchorTime)
                position = layout.showSeconds(at: t).map { $0 * layout.rate.ltcRate.exact }
                state.prepare(rate: layout.rate, sampleRate: sampleRate)
            }
            state.render(into: out, count: Int(frameCount), framePosition: position)
            return noErr
        }
    }

    private func startLTC() {
        guard ltcRoute != nil, !ltc.isRunning else { return }
        do { try ltc.start() } catch { problem = "LTC output: \(error.localizedDescription)" }
    }

    // MARK: Transport

    /// Starts song audio and LTC from timeline time `t`, with `t` sounding at host time `at`.
    func start(layout: TimelineLayout, from t: Double, at host: Double) {
        stopMusic()
        plan.withLock { $0 = LTCPlan(playing: true, anchorPosition: t, anchorTime: host, layout: layout) }
        startLTC()
        var scheduled: [AVAudioPlayerNode] = []
        for item in layout.items {
            guard let path = item.song.audioPath, let file = file(at: path) else { continue }
            let sampleRate = file.processingFormat.sampleRate
            let fileSeconds = Double(file.length) / sampleRate
            let length = min(item.duration, fileSeconds)
            let into = t - item.timelineStart
            guard into < length else { continue }
            let from = max(0, into)
            let frames = AVAudioFrameCount(((length - from) * sampleRate).rounded(.down))
            guard frames > 0 else { continue }
            let node = player(for: item.song.id, format: file.processingFormat)
            let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: host + max(0, -into)))
            node.scheduleSegment(file, startingFrame: AVAudioFramePosition(from * sampleRate),
                                 frameCount: frames, at: when)
            scheduled.append(node)
        }
        guard !scheduled.isEmpty else { return }
        if !music.isRunning {
            do { try music.start() } catch {
                problem = "Song audio: \(error.localizedDescription)"
                return
            }
        }
        scheduled.forEach { $0.play() }
    }

    func stop() {
        stopMusic()
        plan.withLock { $0.playing = false }
    }

    /// A new song order or gap while stopped: LTC keeps following the right layout.
    func update(layout: TimelineLayout) {
        plan.withLock { $0.layout = layout }
    }

    private func stopMusic() {
        players.values.forEach { $0.stop() }
    }

    private func player(for id: UUID, format: AVAudioFormat) -> AVAudioPlayerNode {
        if let node = players[id] { return node }
        let node = AVAudioPlayerNode()
        music.attach(node)
        music.connect(node, to: music.mainMixerNode, format: format)
        players[id] = node
        return node
    }

    private func file(at path: String) -> AVAudioFile? {
        if let file = files[path] { return file }
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        files[path] = file
        return file
    }

    /// Forgets players and open files for songs no longer on the timeline.
    func prune(keeping songs: [Song]) {
        let ids = Set(songs.map(\.id))
        for (id, node) in players where !ids.contains(id) {
            node.stop()
            music.detach(node)
            players[id] = nil
        }
        let paths = Set(songs.compactMap(\.audioPath))
        files = files.filter { paths.contains($0.key) }
    }

    /// Length of an audio file in seconds, or nil if it can't be read.
    static func duration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

/// The LTC generator, owned by the render thread only.
private final class LTCRenderState: @unchecked Sendable {
    private var generator: LTCGenerator?

    func prepare(rate: FrameRate, sampleRate: Double) {
        if generator?.rate != rate.ltcRate || generator?.sampleRate != sampleRate {
            generator = LTCGenerator(rate: rate, sampleRate: sampleRate)
        }
    }

    func render(into out: UnsafeMutablePointer<Float>, count: Int, framePosition: Double?) {
        if generator == nil {
            for i in 0..<count { out[i] = 0 }
            return
        }
        generator!.render(into: out, count: count, framePosition: framePosition)
    }
}
