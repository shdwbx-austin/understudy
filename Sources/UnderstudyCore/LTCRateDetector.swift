import Foundation

/// Works out the show timecode rate from incoming LTC.
///
/// The rate family comes from how fast frames arrive, timed on the audio sample clock, which is
/// precise enough to tell 23.976 from 24 and 29.97 from 30 (0.1% apart) within a couple of seconds.
/// Drop-frame comes from the LTC drop-frame flag. Gaps in the code restart the measurement, and a
/// changed rate has to hold for `confirmSeconds` before it replaces the current one.
public struct LTCRateDetector: Sendable {
    /// The rate in use, nil until enough code has arrived.
    public private(set) var detected: FrameRate?
    /// Frames per second measured over the current run of code.
    public private(set) var measuredFPS: Double?

    /// Seconds of unbroken code needed for a measurement.
    public var minimumRun: Double = 2.0
    /// Seconds a different rate must persist before switching to it.
    public var confirmSeconds: Double = 2.0
    /// A longer pause between frames restarts the measurement.
    public var maxGap: Double = 0.1
    /// Long runs are measured in windows of this length, so a change of source is noticed.
    public var window: Double = 10.0

    /// Seconds a first rate must hold before it's trusted.
    public var firstLockSeconds: Double = 0.5
    /// Frame intervals longer than this include a missed frame and are left out of the measurement
    /// (the longest real interval, 23.976 fps, is 0.0417 s).
    private static let longestFrame = 0.05

    private var runStart: Double?
    private var intervalSum = 0.0
    private var intervals = 0
    private var runFrames = 0
    private var dropFlags = 0
    private var lastTime: Double?
    private var pending: (rate: FrameRate, since: Double)?

    public init() {}

    /// - Parameters:
    ///   - dropFrameFlag: the frame's LTC drop-frame bit.
    ///   - time: when the frame ended, in seconds on a steady clock (ideally audio sample time).
    public mutating func ingest(dropFrameFlag: Bool, time: Double) {
        let previous = lastTime
        if let last = previous, time <= last || time - last > maxGap {
            runStart = nil
        }
        lastTime = time
        guard let start = runStart else {
            startRun(at: time, dropFrameFlag: dropFrameFlag)
            return
        }
        runFrames += 1
        if dropFrameFlag { dropFlags += 1 }
        // Average the frame-to-frame interval, skipping any that span a missed frame: counting
        // frames received over elapsed time reads low after a single dropout (30 → 29.97).
        if let previous {
            let dt = time - previous
            if dt > 0, dt <= Self.longestFrame {
                intervalSum += dt
                intervals += 1
            }
        }

        let span = time - start
        guard span >= minimumRun, intervals >= 20, intervalSum > 0 else { return }
        let fps = Double(intervals) / intervalSum
        measuredFPS = fps
        if let candidate = Self.classify(fps: fps, dropFrame: dropFlags * 2 > runFrames) {
            consider(candidate, at: time)
        }
        if span >= window { startRun(at: time, dropFrameFlag: dropFrameFlag) }
    }

    private mutating func startRun(at time: Double, dropFrameFlag: Bool) {
        runStart = time
        runFrames = 1
        dropFlags = dropFrameFlag ? 1 : 0
        intervalSum = 0
        intervals = 0
    }

    private mutating func consider(_ candidate: FrameRate, at time: Double) {
        guard let current = detected else {
            // Even the first lock must hold briefly, so one odd measurement can't set the rate.
            if let p = pending, p.rate == candidate {
                if time - p.since >= firstLockSeconds {
                    detected = candidate
                    pending = nil
                }
            } else {
                pending = (candidate, time)
            }
            return
        }
        guard candidate != current else {
            pending = nil
            return
        }
        if let p = pending, p.rate == candidate {
            if time - p.since >= confirmSeconds {
                detected = candidate
                pending = nil
            }
        } else {
            pending = (candidate, time)
        }
    }

    /// Nearest LTC rate to a measured frame rate, or nil if it's not close to any.
    public static func classify(fps: Double, dropFrame: Bool) -> FrameRate? {
        let rates: [FrameRate] = [.fps23_976, .fps24, .fps25, .fps29_97, .fps30]
        guard let nearest = rates.min(by: { abs($0.exact - fps) < abs($1.exact - fps) }),
              abs(nearest.exact - fps) < 0.25
        else { return nil }
        if dropFrame, nearest.nominal == 30 { return .fps29_97DF }
        return nearest
    }
}
