import Foundation

public struct LTCSnapshot: Equatable, Sendable {
    public var rolling: Bool
    /// Fractional LTC frame index, nil when not rolling.
    public var position: Double?
    /// True once after timecode jumped while rolling.
    public var jumped: Bool
    public var fps: Double

    public init(rolling: Bool, position: Double?, jumped: Bool, fps: Double) {
        self.rolling = rolling
        self.position = position
        self.jumped = jumped
        self.fps = fps
    }
}

public struct ChaseSettings: Codable, Equatable, Sendable {
    /// How far ahead of incoming code the decks are parked before they roll.
    public var prerollSeconds: Double = 1.5
    /// Time allowed for a deck to finish locating after a goto.
    public var cueSettleSeconds: Double = 0.5
    /// Allowed deck error before a strike, in LTC frames.
    public var toleranceFrames: Double = 1.5
    /// Consecutive out-of-tolerance readings before re-locking.
    public var driftStrikes: Int = 4
    /// Minimum time between cues on the same deck.
    public var recueCooldownSeconds: Double = 1.0
    /// Ignore drift readings right after play while the deck settles.
    public var playGraceSeconds: Double = 0.75

    public init() {}

    /// Missing fields fall back to defaults, so older saved settings keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChaseSettings()
        prerollSeconds = (try? c.decodeIfPresent(Double.self, forKey: .prerollSeconds)) ?? d.prerollSeconds
        cueSettleSeconds = (try? c.decodeIfPresent(Double.self, forKey: .cueSettleSeconds)) ?? d.cueSettleSeconds
        toleranceFrames = (try? c.decodeIfPresent(Double.self, forKey: .toleranceFrames)) ?? d.toleranceFrames
        driftStrikes = (try? c.decodeIfPresent(Int.self, forKey: .driftStrikes)) ?? d.driftStrikes
        recueCooldownSeconds = (try? c.decodeIfPresent(Double.self, forKey: .recueCooldownSeconds)) ?? d.recueCooldownSeconds
        playGraceSeconds = (try? c.decodeIfPresent(Double.self, forKey: .playGraceSeconds)) ?? d.playGraceSeconds
    }
}

public enum ChasePhase: Equatable, Sendable {
    case idle
    case outOfRange
    case cueing(target: Int, since: Double)
    case armed(target: Int)
    /// `segment` is the coverage entry being played, nil when coverage is unbounded.
    case playing(since: Double, segment: Int?)

    public var label: String {
        switch self {
        case .idle: return "WAITING"
        case .outOfRange: return "NO MEDIA AT TC"
        case .cueing: return "CUEING"
        case .armed: return "ARMED"
        case .playing: return "CHASING"
        }
    }
}

public enum ChaseAction: Equatable, Sendable {
    /// Park the deck on LTC frame `target` (LTC frame index).
    case cue(target: Int)
    case play
    case stop
    /// The deck sat steadily off by a consistent amount: a start delay. Add `by` frames to its
    /// play offset (the same value Calibrate sets) and re-park once.
    case learnOffset(by: Double)
}

public struct DeckChaseState: Equatable, Sendable {
    public var phase: ChasePhase = .idle
    public var strikes = 0
    public var lastCueTime = -Double.infinity
    public var lastErrorFrames: Double?
    /// Drift re-locks in a row; each doubles the wait before the next cue (a persistent error,
    /// e.g. a wrong deck timecode setting, must not re-cue every few seconds forever).
    public var relocks = 0
    /// Out-of-tolerance readings in the current run of strikes (most recent last, at most 8).
    public var recentErrors: [Double] = []
    /// Start delays learned on this take; after a few, a persistent error is treated as a fault.
    public var learned = 0

    public init() {}
}

public struct DeckChaseInput: Sendable {
    /// Frames to fire `play` early to absorb the deck's start latency.
    public var startLatencyFrames: Double
    /// Stretches of show code (LTC frames) recorded in the selected take, non-overlapping.
    /// nil = unbounded.
    public var coverage: [Range<Double>]?
    /// Fresh deck error since the last step (deck minus LTC, LTC frames), if any.
    public var observedError: Double?
    public var deckIsPlaying: Bool

    public init(startLatencyFrames: Double, coverage: [Range<Double>]?, observedError: Double?, deckIsPlaying: Bool) {
        self.startLatencyFrames = startLatencyFrames
        self.coverage = coverage
        self.observedError = observedError
        self.deckIsPlaying = deckIsPlaying
    }
}

/// Decks can't chase code natively, so each one is parked ahead of incoming LTC, fired on time,
/// then watched and re-parked if it drifts. Pure function: easy to test, no I/O.
public enum ChaseEngine {
    /// Pre-roll actually used. Never shorter than the deck's settle time after a goto plus its start
    /// latency and a margin: with less, every cue is abandoned before the deck can arm, and the deck
    /// is re-parked about once a second without ever playing.
    /// A deck this far off (LTC frames) is re-parked after two readings, not four.
    public static func farFrames(_ settings: ChaseSettings) -> Double { max(9, settings.toleranceFrames * 6) }
    /// Most start delays learned per take before a persistent error counts as a fault again.
    public static let maxLearned = 3

    public static func effectivePreroll(_ settings: ChaseSettings, startLatencyFrames: Double, fps: Double) -> Double {
        let needed = settings.cueSettleSeconds + (max(0, startLatencyFrames) + 1) / max(fps, 1) + 0.25
        return max(settings.prerollSeconds, needed)
    }

    public static func step(
        _ s: inout DeckChaseState,
        ltc: LTCSnapshot,
        input: DeckChaseInput,
        now: Double,
        settings: ChaseSettings
    ) -> [ChaseAction] {
        func segment(at x: Double) -> Int? { input.coverage?.firstIndex { $0.contains(x) } }
        func covered(_ x: Double) -> Bool { input.coverage == nil || segment(at: x) != nil }

        guard ltc.rolling, let pos = ltc.position else {
            switch s.phase {
            case .idle:
                return []
            case .outOfRange:
                s.phase = .idle
                return []
            default:
                s.phase = .idle
                s.strikes = 0
                return [.stop]
            }
        }

        if ltc.jumped, s.phase != .idle {
            s.phase = .idle
            s.strikes = 0
            s.lastCueTime = -.infinity
        }

        switch s.phase {
        case .idle, .outOfRange:
            let preroll = effectivePreroll(settings, startLatencyFrames: input.startLatencyFrames, fps: ltc.fps)
            let target = Int(pos.rounded(.down) + (preroll * ltc.fps).rounded())
            if !covered(Double(target)) {
                let wasOut = s.phase == .outOfRange
                s.phase = .outOfRange
                return (!wasOut && input.deckIsPlaying) ? [.stop] : []
            }
            let cooldown = settings.recueCooldownSeconds * pow(2, Double(min(s.relocks, 4)))
            guard now - s.lastCueTime >= cooldown else { return [] }
            s.phase = .cueing(target: target, since: now)
            s.lastCueTime = now
            s.strikes = 0
            return [.cue(target: target)]

        case let .cueing(target, since):
            if pos >= Double(target) - input.startLatencyFrames - 1 {
                // Deck took too long to park; try again with a fresh target.
                s.phase = .idle
                return []
            }
            if now - since >= settings.cueSettleSeconds {
                s.phase = .armed(target: target)
            }
            return []

        case let .armed(target):
            let fireAt = Double(target) - input.startLatencyFrames
            guard pos >= fireAt else { return [] }
            if pos > fireAt + 2 {
                s.phase = .idle
                return []
            }
            s.phase = .playing(since: now, segment: segment(at: Double(target)))
            return [.play]

        case let .playing(since, index):
            if let coverage = input.coverage {
                // Ran past the end of the recorded stretch being played.
                let ranOff = index.map { !coverage.indices.contains($0) || pos >= coverage[$0].upperBound } ?? true
                if ranOff {
                    if covered(pos) {
                        // Show code continues into a different recorded stretch: park there.
                        s.phase = .idle
                        s.strikes = 0
                        return []
                    }
                    s.phase = .outOfRange
                    return [.stop]
                }
            }
            guard let error = input.observedError, now - since >= settings.playGraceSeconds else { return [] }
            s.lastErrorFrames = error
            let off = abs(error) > settings.toleranceFrames
            s.strikes = off ? s.strikes + 1 : 0
            s.recentErrors = off ? Array((s.recentErrors + [error]).suffix(8)) : []
            if s.strikes == 0, now - since > 10 { s.relocks = 0 }   // holding fine: forgive past re-locks

            // Far off (a jump the deck missed, a stale play): re-park now, without growing the back-off.
            let far = farFrames(settings)
            if s.strikes >= 2, s.recentErrors.suffix(2).allSatisfy({ abs($0) > far }) {
                s.phase = .idle
                s.strikes = 0
                s.recentErrors = []
                return []
            }

            guard s.strikes >= settings.driftStrikes else { return [] }
            let sorted = s.recentErrors.sorted()
            let mid = sorted.count / 2
            let median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
            let spread = (sorted.last ?? 0) - (sorted.first ?? 0)
            s.phase = .idle
            s.strikes = 0
            s.recentErrors = []
            // Steady and consistent: the deck starts late (or early) by this much. Learn it once.
            if spread <= 3, abs(median) <= far, s.learned < maxLearned {
                s.learned += 1
                return [.learnOffset(by: -median)]
            }
            s.relocks += 1
            return []
        }
    }
}
