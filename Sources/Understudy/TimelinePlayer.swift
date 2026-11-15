import AudioToolbox
import AVFoundation
import Foundation
import os
import UnderstudyCore

/// What plays for one song: its music (nil = nothing to play), and its own timecode for LTC out
/// (nil = generate code for it instead).
struct SongSources {
    var music: String?
    var timecode: String?
}

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
        /// Timeline time where a track's own timecode is playing: the generator stays silent there.
        var trackCode: [Range<Double>] = []
    }

    private let music = AVAudioEngine()
    private let ltc = AVAudioEngine()
    /// One player per file, on the music engine, and per timecode file, on the LTC engine.
    private var players: [String: AVAudioPlayerNode] = [:]
    private var codePlayers: [String: AVAudioPlayerNode] = [:]
    private var files: [String: AVAudioFile] = [:]
    private var ltcNode: AVAudioSourceNode?
    private let plan = OSAllocatedUnfairLock(initialState: LTCPlan())
    private var musicRoute = AudioRoute(deviceUID: nil, channel: 0)
    private var ltcRoute: AudioRoute?
    private var configured = false

    /// Last audio problem, for the UI (nil when fine).
    private(set) var problem: String?

    // MARK: Routing

    /// Core Audio IDs the routes resolved to last time: a device that restarts (Dante Virtual
    /// Soundcard after a channel change, an interface replugged) comes back with a new ID and
    /// needs re-pointing even though its UID is the same.
    private var routedDevices: [AudioDeviceID?] = []

    /// Points music and LTC at their outputs. Returns true when anything changed (which stops
    /// what's playing: the caller restarts it).
    @discardableResult
    func configure(music route: AudioRoute, ltc ltcRoute: AudioRoute?) -> Bool {
        let devices = [route.deviceUID, ltcRoute?.deviceUID].map { $0.flatMap(AudioDeviceCatalog.deviceID(forUID:)) }
        guard !configured || route != musicRoute || ltcRoute != self.ltcRoute || devices != routedDevices else { return false }
        musicRoute = route
        self.ltcRoute = ltcRoute
        routedDevices = devices
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
        return true
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
                if !current.trackCode.contains(where: { $0.contains(t) }) {
                    position = layout.showSeconds(at: t).map { $0 * layout.rate.ltcRate.exact }
                }
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
    /// `sources` says what to play per song (default: its audio file, generated timecode).
    func start(layout: TimelineLayout, from t: Double, at host: Double, sources: [UUID: SongSources] = [:]) {
        stopMusic()
        var trackCode: [Range<Double>] = []
        var scheduled: [AVAudioPlayerNode] = []
        var scheduledCode: [AVAudioPlayerNode] = []
        for item in layout.items {
            let source = sources[item.song.id] ?? SongSources(music: item.song.audioPath, timecode: nil)
            // Where the file's first sample falls on the timeline, from its own timecode if trusted.
            let fileStart = item.timelineStart + (item.song.audioOffset ?? 0)
            // Never before this song's lead-in, never past its end.
            let earliest = item.timelineStart - layout.gap
            if let path = source.music, let file = file(at: path),
               let node = schedule(file, fileStart: fileStart, earliest: earliest, end: item.timelineEnd,
                                   from: t, at: host, player: { self.player(path, format: $0, on: self.music, in: &self.players) }) {
                scheduled.append(node)
            }
            if ltcRoute != nil, let path = source.timecode, let file = file(at: path) {
                let fileEnd = fileStart + Double(file.length) / file.processingFormat.sampleRate
                let range = max(fileStart, earliest)..<min(fileEnd, item.timelineEnd)
                if !range.isEmpty, let node = schedule(file, fileStart: fileStart, earliest: earliest, end: item.timelineEnd,
                                                       from: t, at: host,
                                                       player: { self.player(path, format: $0, on: self.ltc, in: &self.codePlayers) }) {
                    scheduledCode.append(node)
                    trackCode.append(range)
                }
            }
        }
        let codeRanges = trackCode
        plan.withLock { $0 = LTCPlan(playing: true, anchorPosition: t, anchorTime: host, layout: layout, trackCode: codeRanges) }
        startLTC()
        scheduledCode.forEach { $0.play() }
        guard !scheduled.isEmpty else { return }
        if !music.isRunning {
            do { try music.start() } catch {
                problem = "Song audio: \(error.localizedDescription)"
                return
            }
        }
        scheduled.forEach { $0.play() }
    }

    /// Schedules the part of `file` that falls in [max(earliest, fileStart), end) on the timeline,
    /// from timeline time `t` sounding at host time `host`. Returns the player, or nil if nothing plays.
    private func schedule(_ file: AVAudioFile, fileStart: Double, earliest: Double, end: Double, from t: Double,
                          at host: Double, player: (AVAudioFormat) -> AVAudioPlayerNode) -> AVAudioPlayerNode? {
        let sampleRate = file.processingFormat.sampleRate
        let fileEnd = fileStart + Double(file.length) / sampleRate
        let begin = max(t, earliest, fileStart)
        let stop = min(end, fileEnd)
        guard begin < stop else { return nil }
        let frames = AVAudioFrameCount(((stop - begin) * sampleRate).rounded(.down))
        guard frames > 0 else { return nil }
        let node = player(file.processingFormat)
        let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: host + (begin - t)))
        node.scheduleSegment(file, startingFrame: AVAudioFramePosition((begin - fileStart) * sampleRate),
                             frameCount: frames, at: when)
        return node
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
        codePlayers.values.forEach { $0.stop() }
    }

    private func player(_ path: String, format: AVAudioFormat, on engine: AVAudioEngine,
                        in nodes: inout [String: AVAudioPlayerNode]) -> AVAudioPlayerNode {
        if let node = nodes[path] { return node }
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        nodes[path] = node
        return node
    }

    private func file(at path: String) -> AVAudioFile? {
        if let file = files[path] { return file }
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        files[path] = file
        return file
    }

    /// Forgets players and open files no longer used by any song.
    func prune(keeping paths: Set<String>) {
        for (path, node) in players where !paths.contains(path) {
            node.stop()
            music.detach(node)
            players[path] = nil
        }
        for (path, node) in codePlayers where !paths.contains(path) {
            node.stop()
            ltc.detach(node)
            codePlayers[path] = nil
        }
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
