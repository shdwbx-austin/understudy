import AVFoundation
import CoreMedia
import Foundation
import os
import UnderstudyCore

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
            if ndiEnabled { onNDIEnabled?() }
        }
    }
    /// Called when NDI is switched on, so the current take's decks load even off the View screen.
    var onNDIEnabled: (() -> Void)?
    /// NDI at 1080p (light) or the files' own size.
    @Published var ndiFullSize: Bool {
        didSet {
            UserDefaults.standard.set(ndiFullSize, forKey: "understudy.ndiFullSize")
            slots.forEach { if let item = players[$0.deckID]?.currentItem { attachOutput(to: item, deck: $0.deckID) } }
        }
    }
    @Published private(set) var ndiStatus: String = ""
    /// Each deck's chosen LUT, applied on screen and on NDI alike.
    @Published private(set) var transforms: [Int: InputTransform] = [:]
    /// A deck whose transform couldn't be applied (e.g. its LUT file is missing): why.
    @Published private(set) var gradeProblems: [Int: String] = [:]
    private var gradeGeneration: [Int: Int] = [:]

    private(set) var players: [Int: AVPlayer] = [:]
    private var fps: [Int: Double] = [:]
    private var lastSeekTarget: [Int: Double] = [:]
    private var lastSeekTime: [Int: Double] = [:]
    private var lastCheck: [Int: Double] = [:]
    private var running: Set<Int> = []
    private let pump = NDIPump()

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
                    applyGrade(deck: entry.deckID)
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

    // MARK: Input transforms

    /// Sets the decks' transforms (from their settings); decks whose transform changed are
    /// regraded at once, playing or paused.
    func setTransforms(_ new: [Int: InputTransform]) {
        let new = new.filter { $0.value != .none }
        let changed = Set(new.keys).union(transforms.keys).filter { new[$0] != transforms[$0] }
        guard !changed.isEmpty else { return }
        transforms = new
        changed.forEach { applyGrade(deck: $0) }
    }

    /// Applies the deck's transform again (its LUT file was loaded again).
    func regrade(deck: Int) { applyGrade(deck: deck) }

    /// Puts the deck's transform on its current item (or takes it off), off the main thread
    /// for reading the LUT; a newer change or another file wins over a late one.
    private func applyGrade(deck: Int) {
        gradeGeneration[deck, default: 0] += 1
        let generation = gradeGeneration[deck]
        gradeProblems[deck] = nil
        guard let player = players[deck], let item = player.currentItem else { return }
        let transform = transforms[deck] ?? .none
        if transform == .none {
            if item.videoComposition != nil {
                item.videoComposition = nil
                redraw(deck)
            }
            return
        }
        let asset = item.asset
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<AVVideoComposition?, Error>
            do {
                if let cube = try VideoGrade.cube(for: transform) {
                    result = .success(try await VideoGrade.composition(for: asset, cube: cube))
                } else {
                    result = .success(nil)
                }
            } catch {
                result = .failure(error)
            }
            await self?.finishGrade(result, deck: deck, item: item, generation: generation)
        }
    }

    private func finishGrade(_ result: Result<AVVideoComposition?, Error>, deck: Int, item: AVPlayerItem, generation: Int?) {
        guard gradeGeneration[deck] == generation, players[deck]?.currentItem === item else { return }
        switch result {
        case .success(let comp):
            item.videoComposition = comp
            redraw(deck)
        case .failure(let error):
            item.videoComposition = nil
            gradeProblems[deck] = error.localizedDescription
            redraw(deck)
        }
    }

    /// A paused picture is drawn again with the new look (screen and NDI).
    private func redraw(_ deck: Int) {
        guard !running.contains(deck), let player = players[deck], player.currentItem?.status == .readyToPlay else { return }
        player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
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

    /// One NDI source per deck in the viewer, video or not; with no decks at all, one source
    /// ("Understudy") so receivers can still find this Mac. Feeds without video send a test pattern.
    struct Feed: Equatable {
        let deckID: Int
        let source: String
        /// Why there's no picture, or nil when the deck has a video.
        let note: String?
    }

    static let noDeckID = -1

    var feeds: [Feed] {
        if slots.isEmpty {
            return [Feed(deckID: Self.noDeckID, source: "Understudy", note: "No decks with takes yet")]
        }
        return slots.map { slot in
            let name = slot.name.trimmingCharacters(in: .whitespaces)
            return Feed(deckID: slot.deckID, source: "Understudy " + (name.isEmpty ? "Deck \(slot.deckID + 1)" : name),
                        note: slot.url == nil ? slot.status : nil)
        }
    }

    func refreshNDIStatus() {
        let lib = NDILibrary.shared
        if !lib.isAvailable {
            ndiStatus = "NDI library not found (bundle libndi in the app, or install the NDI SDK/runtime)."
        } else if !ndiEnabled {
            ndiStatus = ""   // the switch says it
        } else {
            let failed = feeds.filter { pump.sender(for: $0.deckID) == nil }
            if !failed.isEmpty {
                ndiStatus = "NDI couldn't start " + failed.map(\.source).joined(separator: ", ")
            } else {
                ndiStatus = "Sending " + feeds.map { $0.source + ($0.note == nil ? "" : " (test pattern)") }.joined(separator: ", ")
            }
        }
    }

    private func rebuildSenders() {
        var senders: [Int: NDISender] = [:]
        var notes: [Int: NDIPump.Card] = [:]
        if ndiEnabled {
            for feed in feeds {
                let existing = pump.sender(for: feed.deckID)
                senders[feed.deckID] = existing?.name == feed.source ? existing : NDISender(name: feed.source)
                if let note = feed.note { notes[feed.deckID] = .init(title: feed.source, note: note) }
            }
        }
        pump.setSenders(senders, fps: fps, cards: notes)
        refreshNDIStatus()
    }
}

/// Pulls each player's current frame and sends it to its NDI stream, off the main thread. A
/// feed with no new frame for a moment sends its last frame again (paused, or between takes), so
/// a receiver that connects then still gets a picture; a feed with no video sends a test pattern.
final class NDIPump: @unchecked Sendable {
    struct Card: Equatable, Sendable {
        let title: String
        let note: String
    }

    private struct State {
        var outputs: [Int: AVPlayerItemVideoOutput] = [:]
        /// Bumped when a deck's output changes, so its held frame is dropped.
        var generation: [Int: Int] = [:]
        var senders: [Int: NDISender] = [:]
        var fps: [Int: Double] = [:]
        var cards: [Int: Card] = [:]
    }

    /// Idle feeds (no new frames) repeat at this rate.
    static let idleInterval = 0.1

    private let state = OSAllocatedUnfairLock(initialState: State())
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "understudy.ndi.pump", qos: .userInitiated)
    // Touched only on `queue`.
    private var held: [Int: (generation: Int, buffer: CVPixelBuffer)] = [:]
    private var lastSent: [Int: Double] = [:]
    private var patterns: [Int: NDITestPattern] = [:]

    func setOutput(_ output: AVPlayerItemVideoOutput?, for deck: Int) {
        state.withLock {
            $0.outputs[deck] = output
            $0.generation[deck, default: 0] += 1
        }
    }

    func sender(for deck: Int) -> NDISender? { state.withLock { $0.senders[deck] } }

    func setFPS(_ fps: Double, for deck: Int) { state.withLock { $0.fps[deck] = fps } }

    func setSenders(_ senders: [Int: NDISender], fps: [Int: Double], cards: [Int: Card] = [:]) {
        state.withLock { s in
            s.senders = senders
            s.cards = cards
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
            let fps = s.fps[deck] ?? 30
            let generation = s.generation[deck] ?? 0
            if let card = s.cards[deck] {
                // No video: the test pattern, at the idle rate.
                sendPattern(card, deck: deck, sender: sender, now: now)
                continue
            }
            if let output = s.outputs[deck] {
                let time = output.itemTime(forHostTime: now)
                if output.hasNewPixelBuffer(forItemTime: time),
                   let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                    sender.send(buffer, fps: fps)
                    held[deck] = (generation, buffer)
                    lastSent[deck] = now
                    continue
                }
            }
            // Nothing new: repeat the held frame now and then, so late receivers get a picture.
            guard now - (lastSent[deck] ?? 0) >= Self.idleInterval else { continue }
            if let h = held[deck], h.generation == generation {
                sender.send(h.buffer, fps: fps)
                lastSent[deck] = now
            } else {
                // The file is still opening (or a cold read off a drive): bars until it draws.
                sendPattern(Card(title: sender.name, note: "Loading the video…"), deck: deck, sender: sender, now: now)
            }
        }
        for deck in held.keys where s.senders[deck] == nil { held[deck] = nil }
    }

    private func sendPattern(_ card: Card, deck: Int, sender: NDISender, now: Double) {
        guard now - (lastSent[deck] ?? 0) >= Self.idleInterval else { return }
        if patterns[deck]?.title != card.title || patterns[deck]?.note != card.note {
            patterns[deck] = NDITestPattern(title: card.title, note: card.note)
        }
        if let frame = patterns[deck]?.frame() {
            sender.send(frame, fps: 1 / Self.idleInterval)
            lastSent[deck] = now
        }
    }

    deinit { timer?.cancel() }
}
