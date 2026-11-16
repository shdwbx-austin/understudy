import AVFoundation
import CoreMedia
import Foundation
import os

/// Plays the selected take's recordings (backed-up files, pulled into the project) in Understudy,
/// locked to the timeline's timecode the same way the decks chase it, and sends each one out as
/// its own NDI stream ("Understudy ME 1"…). Up to three decks; shown one at a time or side by side.
/// Only runs in Timeline mode.
@MainActor
final class VideoViewer: ObservableObject {
    static let maxSlots = 3

    struct Slot: Identifiable, Equatable {
        let deckID: Int
        var name: String
        var clipName: String?
        var url: URL?
        var status: String
        var id: Int { deckID }
    }

    @Published private(set) var slots: [Slot] = []
    /// One deck on its own, or nil for all side by side.
    @Published var solo: Int?
    @Published var ndiEnabled: Bool {
        didSet {
            UserDefaults.standard.set(ndiEnabled, forKey: "understudy.ndiEnabled")
            rebuildSenders()
        }
    }
    /// NDI at 1080p (light) or the files' own size.
    @Published var ndiFullSize: Bool {
        didSet {
            UserDefaults.standard.set(ndiFullSize, forKey: "understudy.ndiFullSize")
            slots.forEach { if let item = players[$0.deckID]?.currentItem { attachOutput(to: item, deck: $0.deckID) } }
        }
    }
    @Published private(set) var ndiStatus: String = ""

    private(set) var players: [Int: AVPlayer] = [:]
    private var fps: [Int: Double] = [:]
    private var lastSeekTarget: [Int: Double] = [:]
    private var lastSeekTime: [Int: Double] = [:]
    private var lastCheck: [Int: Double] = [:]
    private var running: Set<Int> = []
    private let pump = Pump()

    init() {
        ndiEnabled = UserDefaults.standard.bool(forKey: "understudy.ndiEnabled")
        ndiFullSize = UserDefaults.standard.bool(forKey: "understudy.ndiFullSize")
        refreshNDIStatus()
    }

    // MARK: Loading

    /// Shows these decks' files (nil url: no file found, with `status` saying why).
    func load(_ entries: [Slot]) {
        let entries = Array(entries.prefix(Self.maxSlots))
        for entry in entries {
            let old = slots.first { $0.deckID == entry.deckID }
            if old?.url != entry.url {
                players[entry.deckID]?.pause()
                running.remove(entry.deckID)
                lastSeekTarget[entry.deckID] = nil
                if let url = entry.url {
                    let item = AVPlayerItem(url: url)
                    let player = players[entry.deckID] ?? AVPlayer()
                    player.automaticallyWaitsToMinimizeStalling = false
                    player.isMuted = true
                    player.replaceCurrentItem(with: item)
                    players[entry.deckID] = player
                    attachOutput(to: item, deck: entry.deckID)
                    let deck = entry.deckID
                    Task { @MainActor [weak self] in
                        let rate = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first?.load(.nominalFrameRate)
                        let fps = Double(rate ?? 30)
                        self?.fps[deck] = fps
                        self?.pump.setFPS(fps, for: deck)   // NDI says 29.97 as 30000/1001
                    }
                } else {
                    players[entry.deckID]?.replaceCurrentItem(with: nil)
                    pump.setOutput(nil, for: entry.deckID)
                }
            }
        }
        for gone in slots where !entries.contains(where: { $0.deckID == gone.deckID }) {
            players[gone.deckID]?.pause()
            players[gone.deckID] = nil
            pump.setOutput(nil, for: gone.deckID)
        }
        if entries != slots { slots = entries }
        if let s = solo, !slots.contains(where: { $0.deckID == s }) { solo = nil }
        rebuildSenders()
    }

    private func attachOutput(to item: AVPlayerItem, deck: Int) {
        var attrs: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                             kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()]
        if !ndiFullSize {
            attrs[kCVPixelBufferWidthKey as String] = 1920
            attrs[kCVPixelBufferHeightKey as String] = 1080
        }
        item.outputs.forEach { item.remove($0) }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(output)
        pump.setOutput(output, for: deck)
    }

    // MARK: Locking to timecode

    /// Called every tick in Timeline mode. `target` gives a deck's position in its file (seconds)
    /// for a host time, or nil where its take has no footage.
    func sync(now: Double, playing: Bool, target: (Int, Double) -> Double?) {
        for slot in slots {
            // Not open yet (e.g. a cold read off a drive): starting or seeking now throws, so wait
            // for it; the next tick (5 ms) tries again.
            guard let player = players[slot.deckID], let item = player.currentItem,
                  player.status == .readyToPlay, item.status == .readyToPlay else { continue }
            let id = slot.deckID
            let frame = 1 / (fps[id] ?? 30)
            if playing {
                let lead = 0.06
                guard let start = target(id, now + lead) else {
                    if running.contains(id) { player.pause(); running.remove(id) }
                    continue
                }
                if !running.contains(id) {
                    roll(player, at: start, hostTime: now + lead)
                    running.insert(id)
                    lastCheck[id] = now
                } else if now - (lastCheck[id] ?? 0) >= 0.25 {
                    lastCheck[id] = now
                    // Drifted (or the take map jumped): lock again at once.
                    if let expected = target(id, now), abs(player.currentTime().seconds - expected) > 1.5 * frame {
                        roll(player, at: start, hostTime: now + lead)
                    }
                }
            } else {
                if running.contains(id) { player.pause(); running.remove(id) }
                guard let t = target(id, now) else { continue }
                // Paused: the exact frame under the playhead, throttled while scrubbing.
                if abs((lastSeekTarget[id] ?? -1) - t) > frame / 2, now - (lastSeekTime[id] ?? 0) >= 0.05 {
                    lastSeekTarget[id] = t
                    lastSeekTime[id] = now
                    player.seek(to: CMTime(seconds: t, preferredTimescale: 600_000), toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
    }

    /// Outside Timeline mode: hold still.
    func stop() {
        for id in running { players[id]?.pause() }
        running.removeAll()
    }

    private func roll(_ player: AVPlayer, at seconds: Double, hostTime: Double) {
        player.setRate(1, time: CMTime(seconds: max(0, seconds), preferredTimescale: 600_000),
                       atHostTime: CMClockMakeHostTimeFromSystemUnits(Self.ticks(hostTime)))
    }

    /// Host seconds (HostClock) → mach ticks.
    static func ticks(_ seconds: Double) -> UInt64 {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return UInt64(max(0, seconds) * 1e9 * Double(tb.denom) / Double(tb.numer))
    }

    // MARK: NDI

    func refreshNDIStatus() {
        let lib = NDILibrary.shared
        if !lib.isAvailable {
            ndiStatus = "NDI library not found (bundle libndi in the app, or install the NDI SDK/runtime)."
        } else if !ndiEnabled {
            ndiStatus = "NDI off"
        } else {
            let names = slots.filter { $0.url != nil }.map { "Understudy \($0.name)" }
            ndiStatus = names.isEmpty ? "NDI on: no videos loaded" : "Sending " + names.joined(separator: ", ")
        }
    }

    private func rebuildSenders() {
        var senders: [Int: NDISender] = [:]
        if ndiEnabled {
            for slot in slots where slot.url != nil {
                senders[slot.deckID] = pump.sender(for: slot.deckID)?.name == "Understudy \(slot.name)"
                    ? pump.sender(for: slot.deckID) : NDISender(name: "Understudy \(slot.name)")
            }
        }
        pump.setSenders(senders, fps: fps)
        refreshNDIStatus()
    }
}

/// Pulls each player's current frame and sends it to its NDI stream, off the main thread.
private final class Pump: @unchecked Sendable {
    private struct State {
        var outputs: [Int: AVPlayerItemVideoOutput] = [:]
        var senders: [Int: NDISender] = [:]
        var fps: [Int: Double] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "understudy.ndi.pump", qos: .userInitiated)

    func setOutput(_ output: AVPlayerItemVideoOutput?, for deck: Int) {
        state.withLock { $0.outputs[deck] = output }
    }

    func sender(for deck: Int) -> NDISender? { state.withLock { $0.senders[deck] } }

    func setFPS(_ fps: Double, for deck: Int) { state.withLock { $0.fps[deck] = fps } }

    func setSenders(_ senders: [Int: NDISender], fps: [Int: Double]) {
        state.withLock { s in
            s.senders = senders
            for (deck, value) in fps { s.fps[deck] = value }
        }
        if senders.isEmpty {
            timer?.cancel()
            timer = nil
        } else if timer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            // 120 Hz checks: every new frame of a 60p file goes out within ~8 ms.
            t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    private func tick() {
        let s = state.withLock { $0 }
        let now = CACurrentMediaTime()
        for (deck, sender) in s.senders {
            guard let output = s.outputs[deck] else { continue }
            let time = output.itemTime(forHostTime: now)
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { continue }
            sender.send(buffer, fps: s.fps[deck] ?? 30)
        }
    }

    deinit { timer?.cancel() }
}
