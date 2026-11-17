import AVFoundation
import Combine
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
    /// Each deck slot's Playback LUT, applied on screen and on NDI alike (never to the deck).
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
    /// A deck whose file can't be played: why (shown on its picture, in the NDI line and on its feed).
    @Published private(set) var playProblems: [Int: String] = [:]
    private var tracks: [Int: TrackInfo] = [:]
    private var statusWatch: [Int: AnyCancellable] = [:]

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
                    playProblems[entry.deckID] = nil
                    watchStatus(of: item, deck: entry.deckID, file: url.lastPathComponent)
                    applyGrade(deck: entry.deckID)
                    let deck = entry.deckID
                    // The output goes on once the track is known (size, pixel aspect, fields); the
                    // feed keeps sending its last frame meanwhile.
                    Task { @MainActor [weak self] in
                        let info = await TrackInfo.load(AVURLAsset(url: url))
                        guard let self, self.players[deck]?.currentItem === item else { return }
                        self.tracks[deck] = info
                        self.fps[deck] = info.fps
                        self.pump.setFPS(info.fps, for: deck)   // NDI says 29.97 as 30000/1001
                        self.pump.setFormat(.init(aspect: info.displayAspect, interlaced: info.interlaced), for: deck)
                        self.attachOutput(to: item, deck: deck)
                    }
                } else {
                    players[entry.deckID]?.replaceCurrentItem(with: nil)
                    pump.setOutput(nil, for: entry.deckID)
                    statusWatch[entry.deckID] = nil
                    playProblems[entry.deckID] = nil
                }
            }
        }
        for gone in slots where !entries.contains(where: { $0.deckID == gone.deckID }) {
            players[gone.deckID]?.pause()
            players[gone.deckID] = nil
            pump.setOutput(nil, for: gone.deckID)
            statusWatch[gone.deckID] = nil
            playProblems[gone.deckID] = nil
        }
        if entries != slots { slots = entries }
        if let s = solo, !slots.contains(where: { $0.deckID == s }) { solo = nil }
        rebuildSenders()
    }

    /// Shows deck `deck`'s frames (the very frames NDI sends) in `layer`.
    func attachDisplay(_ layer: AVSampleBufferDisplayLayer, deck: Int) { pump.addDisplay(layer, for: deck) }
    func detachDisplay(_ layer: AVSampleBufferDisplayLayer) { pump.removeDisplay(layer) }

    /// The output NDI and the viewer read: BGRA, converted to Rec.709 (HDR and wide-gamut files
    /// without a Playback LUT are tone-mapped/converted here; with one, the LUT already made
    /// Rec.709). Light mode only scales down, to 1080 lines, keeping the aspect; smaller files
    /// go at their own size.
    private func attachOutput(to item: AVPlayerItem, deck: Int) {
        var settings: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ]
        if !ndiFullSize, let info = tracks[deck], let (w, h) = info.lightSize {
            settings[kCVPixelBufferWidthKey as String] = w
            settings[kCVPixelBufferHeightKey as String] = h
        }
        item.outputs.forEach { item.remove($0) }
        let output = AVPlayerItemVideoOutput(outputSettings: settings)
        item.add(output)
        pump.setOutput(output, for: deck)
        redraw(deck)
    }

    /// A file that won't play says so (instead of "Loading…" for ever).
    private func watchStatus(of item: AVPlayerItem, deck: Int, file: String) {
        statusWatch[deck] = item.publisher(for: \.status).receive(on: DispatchQueue.main).sink { [weak self, weak item] status in
            MainActor.assumeIsolated {
                guard let self, let item, status == .failed, self.players[deck]?.currentItem === item else { return }
                let reason = item.error?.localizedDescription ?? "unknown error"
                self.playProblems[deck] = "Can't play \(file) (\(reason))"
                self.pump.setOutput(nil, for: deck)
                self.rebuildSenders()
            }
        }
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
                        note: slot.url == nil ? slot.status : playProblems[slot.deckID])
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
                ndiStatus = "Sending " + feeds.map { feed in
                    if let problem = playProblems[feed.deckID] { return feed.source + " (" + problem + ")" }
                    return feed.source + (feed.note == nil ? "" : " (test pattern)")
                }.joined(separator: ", ")
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

/// What the output needs to know about a file's video track.
struct TrackInfo: Sendable {
    var width = 1920, height = 1080
    /// Width / height as shown (pixel aspect and clean aperture included).
    var displayAspect: Float?
    var interlaced = false
    var fps = 30.0

    /// Light mode: scaled down to 1080 lines keeping the pixel aspect, or nil (own size).
    var lightSize: (Int, Int)? {
        guard height > 1080 else { return nil }
        let w = (Double(width) * 1080 / Double(height) / 2).rounded() * 2
        return (Int(w), 1080)
    }

    static func load(_ asset: AVURLAsset) async -> TrackInfo {
        var info = TrackInfo()
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return info }
        if let rate = try? await track.load(.nominalFrameRate), rate > 0 { info.fps = Double(rate) }
        if let desc = try? await track.load(.formatDescriptions).first {
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            info.width = Int(dims.width)
            info.height = Int(dims.height)
            let shown = CMVideoFormatDescriptionGetPresentationDimensions(desc, usePixelAspectRatio: true, useCleanAperture: true)
            if shown.height > 0 { info.displayAspect = Float(shown.width / shown.height) }
            if let fields = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_FieldCount) as? NSNumber {
                info.interlaced = fields.intValue == 2
            }
        }
        return info
    }
}

/// Pulls each player's current frame, off the main thread, and hands the same BGRA frame to its
/// NDI stream and to the viewer's picture(s) of that deck, so what's on screen is exactly what goes
/// out. A feed with no new frame for a moment sends its last frame again (paused, between takes,
/// or while the next file opens), so receivers never see bars between takes; only a feed with no
/// video sends the test pattern. Every frame, pattern or not, goes out at the feed's own rate and
/// last size, so receivers don't renegotiate.
final class NDIPump: @unchecked Sendable {
    struct Card: Equatable, Sendable {
        let title: String
        let note: String
    }

    /// How a deck's frames are described to NDI.
    struct Format: Equatable, Sendable {
        /// Display aspect (pixel aspect included); nil: width / height.
        var aspect: Float?
        var interlaced = false
    }

    private struct State {
        var outputs: [Int: AVPlayerItemVideoOutput] = [:]
        var senders: [Int: NDISender] = [:]
        var fps: [Int: Double] = [:]
        var cards: [Int: Card] = [:]
        var formats: [Int: Format] = [:]
        /// Per-frame NDI metadata (XML), e.g. the Playback LUT in use.
        var metadata: [Int: String] = [:]
        var displays: [Int: [DisplaySink]] = [:]
    }

    /// Idle feeds (no new frames) repeat at this rate.
    static let idleInterval = 0.1
    /// Advertised before a feed's file says otherwise.
    static let defaultFPS = 30000.0 / 1001

    private let state = OSAllocatedUnfairLock(initialState: State())
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "understudy.ndi.pump", qos: .userInitiated)
    // Touched only on `queue`.
    private var held: [Int: CVPixelBuffer] = [:]
    private var lastSent: [Int: Double] = [:]
    private var lastSize: [Int: (Int, Int)] = [:]
    private var patterns: [Int: NDITestPattern] = [:]

    /// The deck's new output. Its last frame keeps going out until the new one draws.
    func setOutput(_ output: AVPlayerItemVideoOutput?, for deck: Int) {
        state.withLock { $0.outputs[deck] = output }
    }

    func sender(for deck: Int) -> NDISender? { state.withLock { $0.senders[deck] } }

    func setFPS(_ fps: Double, for deck: Int) { state.withLock { $0.fps[deck] = fps } }

    func setFormat(_ format: Format, for deck: Int) { state.withLock { $0.formats[deck] = format } }

    func setMetadata(_ xml: String?, for deck: Int) { state.withLock { $0.metadata[deck] = xml } }

    func setSenders(_ senders: [Int: NDISender], fps: [Int: Double], cards: [Int: Card] = [:]) {
        state.withLock { s in
            s.senders = senders
            s.cards = cards
            for (deck, value) in fps { s.fps[deck] = value }
        }
        updateTimer()
    }

    // MARK: Pictures on screen

    final class DisplaySink: @unchecked Sendable {
        weak var layer: AVSampleBufferDisplayLayer?
        var id: ObjectIdentifier? { layer.map(ObjectIdentifier.init) }
        init(_ layer: AVSampleBufferDisplayLayer) { self.layer = layer }
    }

    /// Shows deck `deck`'s frames in `layer` (its last frame at once, if any).
    func addDisplay(_ layer: AVSampleBufferDisplayLayer, for deck: Int) {
        let sink = DisplaySink(layer)
        let id = ObjectIdentifier(layer)
        state.withLock { s in
            s.displays[deck] = (s.displays[deck] ?? []).filter { $0.id != nil && $0.id != id } + [sink]
        }
        queue.async { [weak self] in
            if let buffer = self?.held[deck] { Self.enqueue(buffer, to: [sink]) }
        }
        updateTimer()
    }

    func removeDisplay(_ layer: AVSampleBufferDisplayLayer) {
        let id = ObjectIdentifier(layer)
        state.withLock { s in
            for (deck, sinks) in s.displays { s.displays[deck] = sinks.filter { $0.id != nil && $0.id != id } }
            s.displays = s.displays.filter { !$0.value.isEmpty }
        }
        updateTimer()
    }

    private func updateTimer() {
        let busy = state.withLock { !$0.senders.isEmpty || !$0.displays.isEmpty }
        if !busy {
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

    // MARK: The loop

    private func tick() {
        let s = state.withLock { $0 }
        let now = CACurrentMediaTime()
        let decks = Set(s.senders.keys).union(s.displays.keys).union(s.outputs.keys)
        for deck in decks {
            let sender = s.senders[deck]
            let fps = s.fps[deck] ?? Self.defaultFPS
            if let card = s.cards[deck] {
                // No video: the test pattern, at the idle rate.
                if let sender { sendPattern(card, deck: deck, sender: sender, fps: fps, now: now) }
                continue
            }
            if let output = s.outputs[deck] {
                let time = output.itemTime(forHostTime: now)
                if output.hasNewPixelBuffer(forItemTime: time),
                   let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                    held[deck] = buffer
                    lastSize[deck] = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
                    if let sender { send(buffer, deck: deck, sender: sender, fps: fps, state: s, now: now) }
                    if let sinks = s.displays[deck] { Self.enqueue(buffer, to: sinks) }
                    continue
                }
            }
            // Nothing new: repeat the held frame now and then, so late receivers get a picture.
            guard let sender, now - (lastSent[deck] ?? 0) >= Self.idleInterval else { continue }
            if let buffer = held[deck] {
                send(buffer, deck: deck, sender: sender, fps: fps, state: s, now: now)
            } else {
                // Never had a picture yet (the first file still opening): bars until it draws.
                sendPattern(Card(title: sender.name, note: "Loading the video…"), deck: deck, sender: sender, fps: fps, now: now)
            }
        }
        for deck in held.keys where !decks.contains(deck) { held[deck] = nil }
    }

    private func send(_ buffer: CVPixelBuffer, deck: Int, sender: NDISender, fps: Double, state s: State, now: Double) {
        let format = s.formats[deck] ?? Format()
        sender.send(buffer, fps: fps, aspect: format.aspect, interlaced: format.interlaced, metadata: s.metadata[deck])
        lastSent[deck] = now
    }

    private func sendPattern(_ card: Card, deck: Int, sender: NDISender, fps: Double, now: Double) {
        guard now - (lastSent[deck] ?? 0) >= Self.idleInterval else { return }
        let (w, h) = lastSize[deck] ?? (1920, 1080)
        if let p = patterns[deck], p.title == card.title, p.note == card.note, p.width == w, p.height == h {} else {
            patterns[deck] = NDITestPattern(title: card.title, note: card.note, width: w, height: h)
        }
        if let frame = patterns[deck]?.frame() {
            // Advertised at the feed's own rate (only repeated at the idle rate), progressive.
            sender.send(frame, fps: fps, aspect: nil, interlaced: false, metadata: nil)
            lastSent[deck] = now
        }
    }

    /// Hands a frame to on-screen layers, shown as soon as it arrives.
    private static func enqueue(_ buffer: CVPixelBuffer, to sinks: [DisplaySink]) {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format) == noErr,
              let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        for sink in sinks {
            guard let layer = sink.layer else { continue }
            if #available(macOS 14.0, *) {
                let renderer = layer.sampleBufferRenderer
                if renderer.status == .failed { renderer.flush() }
                renderer.enqueue(sample)
            } else {
                if layer.status == .failed { layer.flush() }
                layer.enqueue(sample)
            }
        }
    }

    deinit { timer?.cancel() }
}
