import Foundation

// MARK: - Waveform peaks

/// A song's waveform at every zoom: the lowest and highest sample in each short slice of the file
/// (a few hundred slices a second), and coarser copies of it, each half as fine as the one before
/// (mip levels). Drawing asks for one low/high pair per pixel column (`columns`), which reads the
/// level closest to the column width, so a whole 2-hour show and a 4-second close-up cost about
/// the same. Values are -1…1, scaled so the loudest sample in the file is 1 (quiet songs still
/// read), and kept as 8 bits each.
///
/// Immutable, so views can share one and compare it by identity.
public final class WaveformPeaks: Sendable {
    /// One level of detail: `framesPerBucket` frames of audio in each low/high pair.
    public struct Level: Sendable, Equatable {
        public let framesPerBucket: Int
        public let lows: [Int8]
        public let highs: [Int8]
        public var count: Int { lows.count }
    }

    public let sampleRate: Double
    /// Frames of audio the waveform covers.
    public let frameCount: Int
    /// The finest level first; each next one has half as many buckets, down to a handful.
    public let levels: [Level]

    public var framesPerBucket: Int { levels[0].framesPerBucket }
    public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }

    /// `lows` and `highs` are the finest level, one pair per `framesPerBucket` frames (the last may
    /// be short); the coarser levels are built from them.
    public init(sampleRate: Double, framesPerBucket: Int, frameCount: Int, lows: [Int8], highs: [Int8]) {
        precondition(lows.count == highs.count && framesPerBucket > 0)
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        var levels = [Level(framesPerBucket: framesPerBucket, lows: lows, highs: highs)]
        while let last = levels.last, last.count > Self.coarsestBuckets {
            let n = (last.count + 1) / 2
            var lo = [Int8](repeating: 0, count: n), hi = [Int8](repeating: 0, count: n)
            last.lows.withUnsafeBufferPointer { l in
                last.highs.withUnsafeBufferPointer { h in
                    for j in 0..<n {
                        let a = 2 * j, b = min(2 * j + 1, last.count - 1)
                        lo[j] = min(l[a], l[b])
                        hi[j] = max(h[a], h[b])
                    }
                }
            }
            levels.append(Level(framesPerBucket: last.framesPerBucket * 2, lows: lo, highs: hi))
        }
        self.levels = levels
    }

    /// Levels stop halving once this few buckets are left.
    static let coarsestBuckets = 16

    /// Slice length for a sample rate: a power of two giving about 400 buckets a second (128 frames
    /// at 44.1 and 48 kHz, 256 at 96 kHz). The timeline's closest zoom shows a few seconds across a
    /// window, so this is about a bucket per screen pixel there; finer than that is interpolated.
    public static func framesPerBucket(sampleRate: Double) -> Int {
        var n = 16
        while Double(n) < sampleRate / 400 { n *= 2 }
        return n
    }

    // MARK: Drawing

    /// The low and high of the audio under each of `count` equal columns from `from` to `to`
    /// seconds into the file, -1…1. Columns wider than a bucket take the lowest and highest of the
    /// buckets they touch, from the coarsest level that still has a bucket per column; columns
    /// narrower than the finest bucket are interpolated between buckets, so a close-up is a smooth
    /// envelope rather than a staircase. Columns outside the file are 0.
    public func columns(from: Double, to: Double, count: Int) -> WaveformColumns {
        var out = WaveformColumns(lows: [Float](repeating: 0, count: max(0, count)),
                                  highs: [Float](repeating: 0, count: max(0, count)))
        let base = levels[0]
        guard count > 0, to > from, base.count > 0, sampleRate > 0 else { return out }
        let start = from * sampleRate
        let perColumn = (to - from) * sampleRate / Double(count)
        let unit: Float = 1 / 127

        if perColumn < Double(base.framesPerBucket) {
            // Closer than the finest level: interpolate between bucket centres.
            let fpb = Double(base.framesPerBucket)
            let last = base.count - 1
            let end = Double(frameCount)
            base.lows.withUnsafeBufferPointer { l in
                base.highs.withUnsafeBufferPointer { h in
                    for i in 0..<count {
                        let frame = start + (Double(i) + 0.5) * perColumn
                        guard frame >= 0, frame < end else { continue }
                        let c = min(max(frame / fpb - 0.5, 0), Double(last))
                        let i0 = Int(c), i1 = min(i0 + 1, last)
                        let t = Float(c - Double(i0))
                        out.lows[i] = (Float(l[i0]) * (1 - t) + Float(l[i1]) * t) * unit
                        out.highs[i] = (Float(h[i0]) * (1 - t) + Float(h[i1]) * t) * unit
                    }
                }
            }
            return out
        }

        let level = levels.last { Double($0.framesPerBucket) <= perColumn } ?? base
        let fpb = Double(level.framesPerBucket)
        level.lows.withUnsafeBufferPointer { l in
            level.highs.withUnsafeBufferPointer { h in
                for i in 0..<count {
                    let a = (start + Double(i) * perColumn) / fpb
                    let b = a + perColumn / fpb
                    let first = Int(a.rounded(.down))
                    let lo = max(0, first)
                    let hi = min(level.count, max(first + 1, Int(b.rounded(.up))))
                    guard lo < hi else { continue }
                    var low = l[lo], high = h[lo]
                    for j in (lo + 1)..<hi {
                        low = min(low, l[j])
                        high = max(high, h[j])
                    }
                    out.lows[i] = Float(low) * unit
                    out.highs[i] = Float(high) * unit
                }
            }
        }
        return out
    }

    // MARK: Cache file

    /// Bump when the file layout or how peaks are made changes: older files are then rebuilt.
    public static let formatVersion: UInt32 = 1
    private static let magic: [UInt8] = Array("USWF".utf8)
    private static let headerSize = 4 + 4 + 8 + 4 + 8 + 4

    /// The finest level as a small binary file (the coarser levels are rebuilt on load): "USWF",
    /// format version, sample rate, frames per bucket, frame count, bucket count, then a low and a
    /// high byte per bucket. Little-endian.
    public func encoded() -> Data {
        let base = levels[0]
        var data = Data(capacity: Self.headerSize + base.count * 2)
        data.append(contentsOf: Self.magic)
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        put(Self.formatVersion)
        put(sampleRate.bitPattern)
        put(UInt32(base.framesPerBucket))
        put(Int64(frameCount))
        put(UInt32(base.count))
        var pairs = [Int8](repeating: 0, count: base.count * 2)
        for i in 0..<base.count {
            pairs[2 * i] = base.lows[i]
            pairs[2 * i + 1] = base.highs[i]
        }
        pairs.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// Reads `encoded()`; nil for anything else, including another format version.
    public convenience init?(encoded data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerSize, Array(bytes[0..<4]) == Self.magic else { return nil }
        func get<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
            var v: T = 0
            withUnsafeMutableBytes(of: &v) { $0.copyBytes(from: bytes[offset..<offset + MemoryLayout<T>.size]) }
            return T(littleEndian: v)
        }
        guard get(4, UInt32.self) == Self.formatVersion else { return nil }
        let sampleRate = Double(bitPattern: get(8, UInt64.self))
        let fpb = Int(get(16, UInt32.self))
        let frames = get(20, Int64.self)
        let count = Int(get(28, UInt32.self))
        guard sampleRate.isFinite, sampleRate > 0, fpb > 0, frames >= 0,
              count == (Int(frames) + fpb - 1) / fpb, bytes.count == Self.headerSize + count * 2 else { return nil }
        var lows = [Int8](repeating: 0, count: count), highs = [Int8](repeating: 0, count: count)
        for i in 0..<count {
            lows[i] = Int8(bitPattern: bytes[Self.headerSize + 2 * i])
            highs[i] = Int8(bitPattern: bytes[Self.headerSize + 2 * i + 1])
        }
        self.init(sampleRate: sampleRate, framesPerBucket: fpb, frameCount: Int(frames), lows: lows, highs: highs)
    }
}

/// One low/high pair per pixel column, -1…1.
public struct WaveformColumns: Sendable, Equatable {
    public var lows: [Float]
    public var highs: [Float]
}

/// Builds a `WaveformPeaks` as a file streams past, a chunk at a time, so a long song never has to
/// be in memory at once.
public struct WaveformBuilder: Sendable {
    public let sampleRate: Double
    public let framesPerBucket: Int
    private var lows: [Float] = []
    private var highs: [Float] = []
    private var low = Float.infinity
    private var high = -Float.infinity
    private var inBucket = 0
    private var frames = 0

    /// `expectedFrames` (the file's length, if known) only reserves room.
    public init(sampleRate: Double, framesPerBucket: Int? = nil, expectedFrames: Int = 0) {
        self.sampleRate = sampleRate
        self.framesPerBucket = max(1, framesPerBucket ?? WaveformPeaks.framesPerBucket(sampleRate: sampleRate))
        let buckets = expectedFrames / self.framesPerBucket + 1
        lows.reserveCapacity(buckets)
        highs.reserveCapacity(buckets)
    }

    /// Each frame's lowest and highest sample across the channels drawn, in order.
    public mutating func add(lows frameLows: UnsafeBufferPointer<Float>, highs frameHighs: UnsafeBufferPointer<Float>) {
        precondition(frameLows.count == frameHighs.count)
        var i = 0
        let n = frameLows.count
        while i < n {
            let take = min(framesPerBucket - inBucket, n - i)
            for j in i..<(i + take) {
                low = min(low, frameLows[j])
                high = max(high, frameHighs[j])
            }
            i += take
            inBucket += take
            if inBucket == framesPerBucket { closeBucket() }
        }
        frames += n
    }

    /// One channel: each sample is both the frame's low and high.
    public mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        add(lows: samples, highs: samples)
    }

    private mutating func closeBucket() {
        lows.append(low)
        highs.append(high)
        low = .infinity
        high = -.infinity
        inBucket = 0
    }

    /// The finished waveform, scaled so the loudest sample is 1.
    public func finish() -> WaveformPeaks {
        var b = self
        if b.inBucket > 0 { b.closeBucket() }
        var top: Float = 0
        for i in b.lows.indices { top = max(top, abs(b.lows[i]), abs(b.highs[i])) }
        let scale: Float = top > 0 ? 127 / top : 0
        func q(_ v: Float) -> Int8 { Int8(max(-127, min(127, (v * scale).rounded()))) }
        return WaveformPeaks(sampleRate: sampleRate, framesPerBucket: framesPerBucket, frameCount: b.frames,
                             lows: b.lows.map(q), highs: b.highs.map(q))
    }
}
