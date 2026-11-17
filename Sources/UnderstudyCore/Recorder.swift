import Foundation

// The Understudy recorder: a deck slot that records video on this Mac (a capture device or an NDI
// source) when there's no HyperDeck for it. This file is the logic that doesn't need AVFoundation:
// what a recorder slot is set to, how arriving frames land on the file's timeline, the take list
// it keeps instead of a deck's clip list, and the warnings it shows.

/// What fills a deck slot.
public enum DeckKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A Blackmagic HyperDeck on the network.
    case hyperdeck
    /// Understudy records the video itself (a stand-in deck; costs CPU, GPU and disk on this Mac).
    case recorder

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .hyperdeck: return "HyperDeck"
        case .recorder: return "Understudy recorder"
        }
    }
}

public enum RecorderSourceKind: String, Codable, Sendable {
    /// An AVFoundation capture device: capture card, webcam, Continuity Camera.
    case capture
    /// An NDI source on the network.
    case ndi
    /// Colour bars made on this Mac (for checking the encoder and disk with no hardware).
    case testPattern
}

/// Where a recorder slot takes its picture from.
public struct RecorderSource: Codable, Hashable, Sendable {
    public var kind: RecorderSourceKind
    /// Capture: the device's unique ID. NDI: the full source name, e.g. "STUDIO-MAC (Program)".
    public var id: String
    /// What the operator sees.
    public var name: String

    public init(kind: RecorderSourceKind, id: String, name: String) {
        self.kind = kind
        self.id = id
        self.name = name
    }

    public static let testPattern = RecorderSource(kind: .testPattern, id: "bars", name: "Test pattern")

    public var label: String {
        switch kind {
        case .capture: return name
        case .ndi: return "NDI · \(name)"
        case .testPattern: return "Test pattern"
        }
    }
}

extension RecorderSource {
    /// An NDI source name split into its machine and source parts: "STUDIO-MAC (Program)".
    public static func ndiParts(_ name: String) -> (host: String, source: String)? {
        guard let open = name.firstIndex(of: "("), name.hasSuffix(")"), open > name.startIndex else { return nil }
        let host = name[..<open].trimmingCharacters(in: .whitespaces)
        let source = name[name.index(after: open)..<name.index(before: name.endIndex)]
        return host.isEmpty ? nil : (host, String(source))
    }

    /// One of this Mac's own Understudy NDI outputs ("Understudy", "Understudy ME 1", …): copies of
    /// the decks' recordings with the Playback LUT applied, never something to record. `localHosts`
    /// are this machine's names (NDI uses its host name; compared without case or ".local").
    public static func isOwnUnderstudyOutput(_ ndiName: String, localHosts: [String]) -> Bool {
        guard let parts = ndiParts(ndiName) else { return false }
        guard parts.source == "Understudy" || parts.source.hasPrefix("Understudy ") else { return false }
        let mine = Set(localHosts.map(normalizedHost).filter { !$0.isEmpty })
        return mine.contains(normalizedHost(parts.host))
    }

    static func normalizedHost(_ h: String) -> String {
        var s = h.trimmingCharacters(in: .whitespaces).uppercased()
        while s.hasSuffix(".") { s.removeLast() }
        if s.hasSuffix(".LOCAL") { s.removeLast(6) }
        return s
    }
}

/// What the recorder encodes to. H.264 and HEVC use the Mac's hardware encoder; ProRes uses the
/// ProRes engine on Macs that have one (M1 Pro/Max/Ultra and later) and software elsewhere.
public enum RecorderCodec: String, Codable, CaseIterable, Sendable, Identifiable {
    case h264
    case hevc
    case proResProxy
    case proRes422

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "H.265 (HEVC)"
        case .proResProxy: return "ProRes 422 Proxy"
        case .proRes422: return "ProRes 422"
        }
    }

    /// QuickTime codec FourCC (what VideoToolbox calls the encoder).
    public var fourCC: String {
        switch self {
        case .h264: return "avc1"
        case .hevc: return "hvc1"
        case .proResProxy: return "apco"
        case .proRes422: return "apcn"
        }
    }

    public var isProRes: Bool { self == .proResProxy || self == .proRes422 }

    /// Bits per pixel per frame: the target for H.264/HEVC, Apple's published average for ProRes
    /// (1080p29.97: H.264 ≈ 20 Mb/s, HEVC ≈ 12 Mb/s, Proxy ≈ 45 Mb/s, 422 ≈ 147 Mb/s).
    var bitsPerPixel: Double {
        switch self {
        case .h264: return 0.32
        case .hevc: return 0.2
        case .proResProxy: return 0.73
        case .proRes422: return 2.36
        }
    }

    /// Average bit rate asked of the H.264/HEVC encoder (ProRes sets its own).
    public func targetBitRate(width: Int, height: Int, fps: Double) -> Int {
        Int(Double(width * height) * fps * bitsPerPixel)
    }

    /// Roughly how fast a recording grows, for "time left on disk" before the first take.
    public func estimatedBytesPerSecond(width: Int, height: Int, fps: Double) -> Double {
        Double(width * height) * fps * bitsPerPixel / 8
    }
}

/// A recorder slot's settings (saved with the deck list and the project).
public struct RecorderSettings: Codable, Equatable, Sendable {
    public var source: RecorderSource?
    public var codec: RecorderCodec = .h264

    public init(source: RecorderSource? = nil, codec: RecorderCodec = .h264) {
        self.source = source
        self.codec = codec
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try? c.decodeIfPresent(RecorderSource.self, forKey: .source)
        codec = (try? c.decodeIfPresent(RecorderCodec.self, forKey: .codec)) ?? .h264
    }
}

// MARK: - Rates and formats

extension FrameRate {
    /// The standard rate closest to a measured or declared `fps` (within 1%), counting drop-frame
    /// for 29.97/59.94 if `dropFrame`. Nil for anything that isn't a broadcast rate.
    public static func nearest(fps: Double, dropFrame: Bool) -> FrameRate? {
        guard fps.isFinite, fps > 0 else { return nil }
        let candidates: [FrameRate] = [.fps23_976, .fps24, .fps25, dropFrame ? .fps29_97DF : .fps29_97, .fps30,
                                       .fps50, dropFrame ? .fps59_94DF : .fps59_94, .fps60]
        guard let best = candidates.min(by: { abs($0.exact - fps) < abs($1.exact - fps) }),
              abs(best.exact - fps) / best.exact < 0.01 else { return nil }
        // 23.976 vs 24 and 29.97 vs 30 are 0.1% apart: take whichever is genuinely closer.
        return best
    }

    /// Frame duration as a rational (value / timescale seconds): 1001/30000 for 29.97.
    public var frameDuration: (value: Int64, timescale: Int32) {
        isFractional ? (1001, Int32(nominal * 1000)) : (1, Int32(nominal))
    }

    /// The digits HyperDecks use for this rate in a video format name ("2997", "25").
    var formatDigits: String {
        switch self {
        case .fps23_976: return "2398"
        case .fps29_97, .fps29_97DF: return "2997"
        case .fps59_94, .fps59_94DF: return "5994"
        default: return String(nominal)
        }
    }
}

public enum RecorderFormat {
    /// A HyperDeck-style video format name, e.g. "1080p2997" or "1080i5994", so the rest of
    /// Understudy reads the recorder's rate the same way it reads a deck's. Interlaced formats are
    /// named by field rate, like the decks' (`rate` is always the frame rate); only 25, 29.97 and
    /// 30 frames have interlaced names.
    public static func videoFormat(height: Int, rate: FrameRate, scan: RecorderScan = .progressive) -> String {
        if scan.isInterlaced, let fields = fieldRateDigits(rate) { return "\(height)i\(fields)" }
        return "\(height)p\(rate.formatDigits)"
    }

    private static func fieldRateDigits(_ rate: FrameRate) -> String? {
        switch rate {
        case .fps25: return "50"
        case .fps29_97, .fps29_97DF: return "5994"
        case .fps30: return "60"
        default: return nil
        }
    }

    /// Timecode for a duration in frames (durations never drop labels).
    public static func duration(frames: Int, nominal: Int) -> Timecode {
        let f = max(0, frames)
        return Timecode(hours: f / (nominal * 3600), minutes: (f / (nominal * 60)) % 60,
                        seconds: (f / nominal) % 60, frames: f % nominal)
    }

    /// Timecode frame index (at `rate`) for show code at `ltcFrames` on the `ltcRate` clock.
    public static func timecodeIndex(ltcFrames: Double, ltcRate: FrameRate, rate: FrameRate) -> Int {
        Int((ltcFrames / ltcRate.exact * rate.exact).rounded())
    }

    /// Time of day as a timecode frame index, for a take started with no show code (as a deck's
    /// internal clock would stamp it).
    public static func timeOfDayIndex(_ date: Date, rate: FrameRate, calendar: Calendar = .current) -> Int {
        clockIndex(seconds: date.timeIntervalSince(calendar.startOfDay(for: date)), rate: rate)
    }

    /// Timecode frame index whose label reads clock time `seconds` (since midnight). Drop-frame and
    /// whole rates count real frames, which keeps their labels on the clock. Non-drop 23.976, 29.97
    /// and 59.94 count `nominal` labels per labelled second, so the take starts on the clock's time
    /// (counting real frames would put them 3.6 s an hour behind it).
    public static func clockIndex(seconds: Double, rate: FrameRate) -> Int {
        let perSecond = rate.isFractional && !rate.isDropFrame ? Double(rate.nominal) : rate.exact
        return Int((seconds * perSecond).rounded())
    }
}

/// What a take is stamped with at REC: show code, or (with none) the time of day.
public struct RecorderStartCode: Equatable, Sendable {
    /// Show code as real seconds since 00:00:00:00 (LTC frames ÷ LTC rate), or clock seconds since midnight.
    public var seconds: Double
    /// `seconds` is the time of day, not show code.
    public var isClockTime: Bool

    public init(seconds: Double, isClockTime: Bool) {
        self.seconds = seconds
        self.isClockTime = isClockTime
    }

    public static func clock(_ date: Date, calendar: Calendar = .current) -> RecorderStartCode {
        RecorderStartCode(seconds: date.timeIntervalSince(calendar.startOfDay(for: date)), isClockTime: true)
    }

    /// Timecode frame index at `rate`, `elapsed` seconds after REC (when the first frame came in).
    public func index(at rate: FrameRate, after elapsed: Double = 0) -> Int {
        let t = seconds + elapsed
        return isClockTime ? RecorderFormat.clockIndex(seconds: t, rate: rate) : Int((t * rate.exact).rounded())
    }
}

// MARK: - Colour, scan and pixel formats

/// A picture's colour tags, by their Core Video / AVFoundation names
/// (kCVImageBufferColorPrimaries_ITU_R_709_2 is "ITU_R_709_2", and so on).
public struct RecorderColor: Codable, Equatable, Sendable {
    public var primaries: String
    public var transfer: String
    public var matrix: String

    public init(primaries: String, transfer: String, matrix: String) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
    }

    public static let rec709 = RecorderColor(primaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2")
    /// SD 525-line (NTSC family): SMPTE C primaries, BT.601 matrix.
    public static let rec601NTSC = RecorderColor(primaries: "SMPTE_C", transfer: "ITU_R_709_2", matrix: "ITU_R_601_4")
    /// SD 625-line (PAL family): EBU 3213 primaries, BT.601 matrix.
    public static let rec601PAL = RecorderColor(primaries: "EBU_3213", transfer: "ITU_R_709_2", matrix: "ITU_R_601_4")

    /// What an untagged picture is: Rec. 709 at 720 lines and up, BT.601 below (NDI's rule, and SD
    /// video's), with PAL primaries for 576 lines and NTSC's otherwise.
    public static func standard(height: Int) -> RecorderColor {
        if height >= 720 { return .rec709 }
        return height >= 576 ? .rec601PAL : .rec601NTSC
    }

    /// Tags the writer can carry into a file.
    static let writablePrimaries: Set<String> = ["ITU_R_709_2", "SMPTE_C", "EBU_3213", "P3_D65", "ITU_R_2020"]
    static let writableTransfer: Set<String> = ["ITU_R_709_2", "SMPTE_ST_2084_PQ", "ITU_R_2100_HLG"]
    static let writableMatrix: Set<String> = ["ITU_R_709_2", "ITU_R_601_4", "ITU_R_2020"]

    /// The tags a buffer carries, each one missing or unwritable taken from `standard(height:)`.
    public static func from(primaries: String?, transfer: String?, matrix: String?, height: Int) -> RecorderColor {
        let d = standard(height: height)
        return RecorderColor(
            primaries: primaries.flatMap { writablePrimaries.contains($0) ? $0 : nil } ?? d.primaries,
            transfer: transfer.flatMap { writableTransfer.contains($0) ? $0 : nil } ?? d.transfer,
            matrix: matrix.flatMap { writableMatrix.contains($0) ? $0 : nil } ?? d.matrix)
    }
}

/// Progressive, or interlaced (both fields woven into each frame) and which field comes first.
public enum RecorderScan: String, Codable, Sendable {
    case progressive
    /// Top (first spatial) line belongs to the earlier field: HD 1080i and PAL.
    case topFieldFirst
    /// NTSC-family SD (480i/486i) usually.
    case bottomFieldFirst

    public var isInterlaced: Bool { self != .progressive }
}

/// Which pixel format to ask a capture device for.
public enum RecorderPixelFormat {
    public static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    /// 8-bit 4:2:0 video range ('420v'): what the H.264/HEVC hardware encoders take as is.
    public static let yuv420v = code("420v")
    /// 8-bit 4:2:2 ('2vuy', UYVY).
    public static let yuv422 = code("2vuy")
    /// 8-bit 4:2:2 ('yuvs', YUY2).
    public static let yuv422yuvs = code("yuvs")
    /// 10-bit 4:2:2 biplanar video range ('x422').
    public static let yuv422x10 = code("x422")
    /// Formats a 10-bit source arrives in.
    static let tenBit: Set<UInt32> = [code("v210"), code("x422"), code("x420"), code("x444"), code("p210"), code("p010")]

    /// For ProRes keep 4:2:2, and 10 bits when the device sends them; for H.264/HEVC 4:2:0.
    /// `native` is the device's own format, `available` what its output offers.
    public static func choose(native: UInt32, available: [UInt32], proRes: Bool) -> UInt32? {
        var wanted: [UInt32] = []
        if proRes {
            if tenBit.contains(native) { wanted.append(yuv422x10) }
            wanted += [yuv422, yuv422yuvs]
        }
        wanted.append(yuv420v)
        return wanted.first { available.contains($0) } ?? available.first
    }

    public static func name(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii) ?? "\(code)"
    }
}

// MARK: - Frame clock

/// Places arriving frames on the recording's frame grid.
///
/// The file runs at a fixed rate with no gaps in its timeline, so frame N is always
/// start timecode + N. Frames normally take the next slot; when the source falls more than
/// `slack` frames behind real time (frames lost upstream, or this Mac too busy) the clock jumps
/// ahead and counts the missing slots as dropped, and when it runs more than `slack` frames ahead
/// (a source faster than the recording rate, or a burst) the extra frame is skipped. Small jitter
/// in arrival times never moves a frame.
public struct RecorderFrameClock: Sendable {
    public let fps: Double
    public var slack: Double

    /// Source time of frame 0.
    public private(set) var startTime: Double?
    /// Slot of the last frame placed (-1 before the first).
    public private(set) var lastIndex = -1
    /// Slots left empty because no frame arrived for them (the previous frame holds over).
    public private(set) var dropped = 0
    /// Frames skipped because their slot was already filled.
    public private(set) var skipped = 0

    public init(fps: Double, slack: Double = 1.5) {
        self.fps = fps
        self.slack = slack
    }

    /// Frames placed so far, including held-over slots: the recording's length in frames.
    public var length: Int { lastIndex + 1 }

    /// Where a frame arriving at source time `time` goes, or nil to leave it out.
    public mutating func place(at time: Double) -> Int? {
        guard let start = startTime else {
            startTime = time
            lastIndex = 0
            return 0
        }
        let expected = lastIndex + 1
        let real = (time - start) * fps
        let drift = real - Double(expected)
        if drift < -slack {
            skipped += 1
            return nil
        }
        var index = expected
        if drift > slack {
            index = Int(real.rounded())
            dropped += index - expected
        }
        lastIndex = index
        return index
    }

    /// The writer couldn't take this frame: its slot stays empty (held over) and counts as dropped.
    public mutating func unplace(_ index: Int) {
        guard index == lastIndex else { return }
        dropped += 1
    }
}

// MARK: - Takes

/// One recording the recorder made: what a HyperDeck would list as a clip.
public struct RecorderTake: Codable, Equatable, Sendable, Identifiable {
    /// Clip id, counting up from 1 like a deck's.
    public var id: Int
    /// File name, e.g. "ME 1_0001.mov".
    public var name: String
    public var path: String
    /// Timecode stamped on the first frame, as a frame index at `rate`.
    public var startFrame: Int
    /// Length in timecode frames at `rate`.
    public var frames: Int
    /// Timecode rate (the video rate, or its LTC rate when deck timecode runs at LTC rate).
    public var rate: FrameRate
    public var videoFormat: String
    public var codec: RecorderCodec
    public var createdAt: Date
    public var droppedFrames: Int

    public init(id: Int, name: String, path: String, startFrame: Int, frames: Int, rate: FrameRate,
                videoFormat: String, codec: RecorderCodec, createdAt: Date = Date(), droppedFrames: Int = 0) {
        self.id = id
        self.name = name
        self.path = path
        self.startFrame = startFrame
        self.frames = frames
        self.rate = rate
        self.videoFormat = videoFormat
        self.codec = codec
        self.createdAt = createdAt
        self.droppedFrames = droppedFrames
    }

    /// As a deck clip (start and duration timecode), so takes, maps and the viewer treat it like one.
    public var clip: DeckClip {
        DeckClip(id: id, start: Timecode(frameIndex: startFrame, rate: rate),
                 duration: RecorderFormat.duration(frames: frames, nominal: rate.nominal), name: name)
    }
}

/// The recorder's clip list, oldest first.
public struct RecorderTakeList: Codable, Equatable, Sendable {
    public var takes: [RecorderTake] = []

    public init(takes: [RecorderTake] = []) { self.takes = takes }

    public var nextID: Int { (takes.map(\.id).max() ?? 0) + 1 }

    /// The deck way: `<prefix>_0001.mov`, then `_0002` … for every take with that prefix, skipping
    /// names already used here or `taken` on disk.
    public func nextName(prefix: String, ext: String = "mov", taken: (String) -> Bool = { _ in false }) -> String {
        let clean = Self.safeFileName(prefix)
        let used = Set(takes.map(\.name))
        var n = 1
        while true {
            let name = String(format: "%@_%04d.%@", clean, n, ext)
            if !used.contains(name) && !taken(name) { return name }
            n += 1
        }
    }

    public mutating func add(_ take: RecorderTake) {
        takes.append(take)
        takes.sort { $0.id < $1.id }
    }

    /// Takes whose files are still there, as deck clips.
    public func clips(fileExists: (String) -> Bool) -> [DeckClip] {
        takes.filter { fileExists($0.path) }.map(\.clip)
    }

    public func take(named name: String) -> RecorderTake? { takes.last { $0.name == name } }

    /// Slashes and colons can't be in a file name; an empty prefix becomes "Recorder".
    public static func safeFileName(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return t.isEmpty ? "Recorder" : t
    }
}

// MARK: - Health

/// What the recorder shows about itself, worst first.
public struct RecorderWarning: Equatable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case note, caution, alarm
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public var level: Level
    public var text: String

    public init(_ level: Level, _ text: String) {
        self.level = level
        self.text = text
    }
}

public struct RecorderHealth: Equatable, Sendable {
    public var sourceOpen = false
    public var recording = false
    /// Seconds since the last frame arrived (nil: none yet).
    public var secondsSinceFrame: Double?
    /// Slots with no frame (source or this Mac fell behind) in the take so far.
    public var droppedFrames = 0
    /// Frames the encoder couldn't take in time (counted in `droppedFrames` too).
    public var encoderDrops = 0
    /// Encoder drops in the last few seconds: still happening.
    public var recentEncoderDrops = 0
    /// Extra frames left out (source faster than the recording rate).
    public var skippedFrames = 0
    /// How fast the file is growing, bytes per second.
    public var bytesPerSecond: Double?
    /// Free space where the file is going.
    public var freeBytes: Int64?
    /// Expected rate before recording starts (for time left on disk).
    public var estimatedBytesPerSecond: Double?
    public var softwareEncoder = false
    /// The source sends alpha; the codecs here have none, so it isn't recorded.
    public var alphaDropped = false
    /// The source is interlaced but the codec (H.264/HEVC) writes progressive frames.
    public var interlacedAsProgressive = false
    /// The source's fields reach the recorder de-interlaced (an NDI sender sending separate fields).
    public var sourceDeinterlaced = false

    public init() {}

    /// Recording time left on the disk at the current (or expected) data rate.
    public var secondsLeft: Int? {
        guard let free = freeBytes, let rate = bytesPerSecond ?? estimatedBytesPerSecond, rate > 0 else { return nil }
        return Int(Double(free) / rate)
    }

    public static let noSignalAfter = 1.0

    public var warnings: [RecorderWarning] {
        var out: [RecorderWarning] = []
        if sourceOpen {
            if let s = secondsSinceFrame {
                if s > Self.noSignalAfter { out.append(.init(recording ? .alarm : .caution, "NO SIGNAL")) }
            } else {
                out.append(.init(.caution, "WAITING FOR PICTURE"))
            }
        }
        if recentEncoderDrops > 0 {
            out.append(.init(.alarm, "ENCODER OR DISK FALLING BEHIND"))
        }
        if droppedFrames > 0 {
            out.append(.init(recording ? .alarm : .caution, "\(droppedFrames) FRAME\(droppedFrames == 1 ? "" : "S") DROPPED"))
        }
        if skippedFrames > 0 {
            out.append(.init(.note, "\(skippedFrames) EXTRA SOURCE FRAME\(skippedFrames == 1 ? "" : "S") LEFT OUT"))
        }
        if let left = secondsLeft {
            if left < 120 {
                out.append(.init(.alarm, "DISK: \(Self.minutes(left)) LEFT"))
            } else if left < 600 {
                out.append(.init(.caution, "DISK: \(Self.minutes(left)) LEFT"))
            }
        }
        if interlacedAsProgressive {
            out.append(.init(.caution, "INTERLACED SOURCE RECORDED AS PROGRESSIVE: USE PRORES TO KEEP FIELDS"))
        }
        if sourceDeinterlaced {
            out.append(.init(.note, "SOURCE SENDS SEPARATE FIELDS: RECORDED DE-INTERLACED"))
        }
        if alphaDropped {
            out.append(.init(.note, "SOURCE ALPHA NOT RECORDED"))
        }
        if softwareEncoder {
            out.append(.init(.note, "SOFTWARE ENCODER: HEAVY ON THIS MAC"))
        }
        return out.sorted { $0.level > $1.level }
    }

    static func minutes(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) S" : "\(seconds / 60) MIN"
    }

    /// "18.4 MB/s".
    public static func rateText(_ bytesPerSecond: Double?) -> String {
        guard let b = bytesPerSecond else { return "—" }
        return String(format: "%.1f MB/s", b / 1_000_000)
    }
}
