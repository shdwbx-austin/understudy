import Foundation

public struct LTCFrame: Equatable, Sendable {
    public var timecode: Timecode
    public var dropFrameFlag: Bool
    /// Absolute sample index (since decoder start) of the edge that ended this frame,
    /// i.e. the moment the *next* frame begins.
    public var boundarySample: Int64

    public init(timecode: Timecode, dropFrameFlag: Bool, boundarySample: Int64) {
        self.timecode = timecode
        self.dropFrameFlag = dropFrameFlag
        self.boundarySample = boundarySample
    }
}

/// Biphase-mark SMPTE LTC decoder. Polarity independent, adapts to 23.976–30 fps and moderate varispeed.
/// Not thread safe: feed it from a single audio thread.
public final class LTCDecoder {
    public let sampleRate: Double
    public private(set) var bitPeriod: Double
    public private(set) var sampleCount: Int64 = 0

    private let minPeriod: Double
    private let maxPeriod: Double
    private var sign = 0
    private var samplesSinceEdge = 0
    private var halfPending = false
    private var firstHalf = 0
    private var peak: Float = 0
    private var ring = [UInt8](repeating: 0, count: 80)
    private var head = 0
    private var filled = 0

    static let syncWord: [UInt8] = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1]

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        bitPeriod = sampleRate / (25 * 80)
        minPeriod = sampleRate / (30 * 80) * 0.5
        maxPeriod = sampleRate / ((24000.0 / 1001.0) * 80) * 2
    }

    /// Frame rate implied by the measured bit period (coarse; use the DF flag and settings for the exact rate).
    public var estimatedFrameRate: Double { sampleRate / (bitPeriod * 80) }

    public func reset() {
        bitPeriod = sampleRate / (25 * 80)
        sign = 0
        samplesSinceEdge = 0
        halfPending = false
        peak = 0
        head = 0
        filled = 0
    }

    public func process(_ samples: UnsafePointer<Float>, count: Int, onFrame: (LTCFrame) -> Void) {
        for i in 0..<count {
            let x = samples[i]
            sampleCount += 1
            samplesSinceEdge += 1
            peak = max(abs(x), peak * 0.9995)
            let threshold = max(Float(0.002), peak * 0.15)
            let newSign: Int
            if sign >= 0 && x < -threshold {
                newSign = -1
            } else if sign <= 0 && x > threshold {
                newSign = 1
            } else {
                continue
            }
            if sign == 0 {
                sign = newSign
                samplesSinceEdge = 0
                continue
            }
            sign = newSign
            let interval = samplesSinceEdge
            samplesSinceEdge = 0
            edge(interval: interval, onFrame: onFrame)
        }
    }

    private func edge(interval: Int, onFrame: (LTCFrame) -> Void) {
        let iv = Double(interval)
        if iv > maxPeriod * 2 {
            // Dropout or silence: resynchronise.
            halfPending = false
            filled = 0
            head = 0
            return
        }
        if iv > 0.75 * bitPeriod {
            halfPending = false
            push(0, onFrame: onFrame)
            bitPeriod = clamp(bitPeriod * 0.9 + iv * 0.1)
        } else if halfPending {
            halfPending = false
            push(1, onFrame: onFrame)
            bitPeriod = clamp(bitPeriod * 0.9 + Double(interval + firstHalf) * 0.1)
        } else {
            halfPending = true
            firstHalf = interval
        }
    }

    private func clamp(_ v: Double) -> Double { min(maxPeriod, max(minPeriod, v)) }

    private func bit(_ k: Int) -> Int { Int(ring[(head + k) % 80]) }

    private func push(_ value: UInt8, onFrame: (LTCFrame) -> Void) {
        if filled < 80 {
            ring[(head + filled) % 80] = value
            filled += 1
        } else {
            ring[head] = value
            head = (head + 1) % 80
        }
        guard filled == 80 else { return }
        for k in 0..<16 where bit(64 + k) != Int(Self.syncWord[k]) { return }

        func field(_ start: Int, _ length: Int) -> Int {
            var v = 0
            for i in 0..<length { v |= bit(start + i) << i }
            return v
        }
        let frames = field(0, 4) + 10 * field(8, 2)
        let seconds = field(16, 4) + 10 * field(24, 3)
        let minutes = field(32, 4) + 10 * field(40, 3)
        let hours = field(48, 4) + 10 * field(56, 2)
        guard frames < 30, seconds < 60, minutes < 60, hours < 24 else { return }
        onFrame(LTCFrame(
            timecode: Timecode(hours: hours, minutes: minutes, seconds: seconds, frames: frames),
            dropFrameFlag: bit(10) == 1,
            boundarySample: sampleCount
        ))
    }
}

/// Minimal LTC generator. Used by tests; also handy for bench checks.
public enum LTCEncoder {
    public static func bits(for tc: Timecode, rate: FrameRate) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 80)
        func put(_ start: Int, _ value: Int, _ count: Int) {
            for i in 0..<count { b[start + i] = UInt8((value >> i) & 1) }
        }
        put(0, tc.frames % 10, 4)
        put(8, tc.frames / 10, 2)
        b[10] = rate.isDropFrame ? 1 : 0
        put(16, tc.seconds % 10, 4)
        put(24, tc.seconds / 10, 3)
        put(32, tc.minutes % 10, 4)
        put(40, tc.minutes / 10, 3)
        put(48, tc.hours % 10, 4)
        put(56, tc.hours / 10, 2)
        for (i, v) in LTCDecoder.syncWord.enumerated() { b[64 + i] = v }
        let parityBit = rate.nominal == 25 ? 59 : 27
        if b.reduce(0, { $0 + Int($1) }) % 2 == 1 { b[parityBit] = 1 }
        return b
    }

    /// Renders `frameCount` frames starting at `start`. `rate` must be an LTC rate (≤ 30 fps).
    public static func render(start: Timecode, frameCount: Int, rate: FrameRate, sampleRate: Double, amplitude: Float = 0.5) -> [Float] {
        let samplesPerBit = sampleRate / (rate.exact * 80)
        var out: [Float] = []
        out.reserveCapacity(Int(Double(frameCount * 80) * samplesPerBit) + 16)
        var level: Float = 1
        var carry = 0.0
        let startIndex = start.frameIndex(at: rate)
        for f in 0..<frameCount {
            let tc = Timecode(frameIndex: startIndex + f, rate: rate)
            for b in bits(for: tc, rate: rate) {
                level = -level
                carry += samplesPerBit
                let n = Int(carry.rounded())
                carry -= Double(n)
                for i in 0..<n {
                    if b == 1 && i == n / 2 { level = -level }
                    out.append(level * amplitude)
                }
            }
        }
        return out
    }
}

/// Turns decoded LTC frames into a continuously readable show clock.
///
/// When frames stop arriving the clock keeps counting (freewheels) for `freewheel` seconds, so a
/// brief LTC dropout doesn't stop recording logs or playback. A held (repeating) frame still stops
/// it at once, since that's how most generators signal a deliberate stop.
public struct LTCClock: Sendable {
    public var rate: FrameRate
    /// LTC is considered present if a frame arrived within this time.
    public var signalTimeout: Double = 0.25
    /// How long to keep counting after the last frame. Values below `signalTimeout` mean no freewheel.
    public var freewheel: Double = 2.0
    public private(set) var lastTimecode: Timecode?
    public private(set) var lastDropFrameFlag = false

    private var anchorFrame: Int?
    private var anchorTime: Double = 0
    private var stationary = false
    private var pendingJump = false

    public init(rate: FrameRate, freewheel: Double = 2.0) {
        self.rate = rate
        self.freewheel = freewheel
    }

    private var rollWindow: Double { max(signalTimeout, freewheel) }

    /// - Parameters:
    ///   - timecode: the decoded frame label.
    ///   - boundaryTime: host time (seconds) at which that frame ended.
    public mutating func ingest(_ timecode: Timecode, dropFrameFlag: Bool, boundaryTime: Double) {
        let next = timecode.frameIndex(at: rate) + 1
        if let anchor = anchorFrame, boundaryTime - anchorTime < rollWindow {
            stationary = next == anchor
            let expected = Double(anchor) + (boundaryTime - anchorTime) * rate.exact
            if !stationary && abs(Double(next) - expected) > 2.5 { pendingJump = true }
        } else {
            stationary = false
        }
        anchorFrame = next
        anchorTime = boundaryTime
        lastTimecode = timecode
        lastDropFrameFlag = dropFrameFlag
    }

    public func isRolling(at now: Double) -> Bool {
        anchorFrame != nil && !stationary && now - anchorTime < rollWindow
    }

    /// Rolling on the clock's own count because LTC has gone missing.
    public func isFreewheeling(at now: Double) -> Bool {
        isRolling(at: now) && now - anchorTime >= signalTimeout
    }

    /// Fractional LTC frame index at `now`, or nil when code is not rolling.
    public func position(at now: Double) -> Double? {
        guard isRolling(at: now), let anchor = anchorFrame else { return nil }
        return Double(anchor) + (now - anchorTime) * rate.exact
    }

    public func timecode(at now: Double) -> Timecode? {
        if let p = position(at: now) { return Timecode(frameIndex: Int(p.rounded(.down)), rate: rate) }
        return lastTimecode
    }

    public mutating func snapshot(at now: Double) -> LTCSnapshot {
        let jumped = pendingJump
        pendingJump = false
        let pos = position(at: now)
        return LTCSnapshot(rolling: pos != nil, position: pos, jumped: jumped, fps: rate.exact)
    }
}
