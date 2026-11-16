import Foundation

/// How hard the audio hits, hop by hop: the rise in energy (log) in a low band (kicks), a high
/// band (hats, snares, clicks) and the whole signal. Feed mono samples in any size of chunk.
public struct OnsetEnvelope: Sendable {
    public let sampleRate: Double
    public let hop: Int
    /// Attack strength per hop, all bands together.
    public private(set) var flux: [Float] = []
    /// Attack strength in the low band only (for finding beat one).
    public private(set) var low: [Float] = []

    private let lowCoeff: Float
    private let highCoeff: Float
    private var lp: Float = 0
    private var lp2: Float = 0
    private var eLow: Float = 0
    private var eHigh: Float = 0
    private var eAll: Float = 0
    private var filled = 0
    private var previous: (Float, Float, Float)?

    public init(sampleRate: Double, hop: Int = 512) {
        self.sampleRate = sampleRate
        self.hop = max(64, hop)
        lowCoeff = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
        highCoeff = Float(1 - exp(-2 * Double.pi * 2500 / sampleRate))
    }

    public var hopSeconds: Double { Double(hop) / sampleRate }

    public mutating func feed(_ samples: UnsafePointer<Float>, count: Int) {
        for i in 0..<count {
            let x = samples[i]
            lp += lowCoeff * (x - lp)
            lp2 += highCoeff * (x - lp2)
            let high = x - lp2
            eLow += lp * lp
            eHigh += high * high
            eAll += x * x
            filled += 1
            if filled == hop { closeHop() }
        }
    }

    public mutating func feed(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { if let base = $0.baseAddress { feed(base, count: $0.count) } }
    }

    private mutating func closeHop() {
        let n = Float(hop)
        let now = (log1p(1000 * eLow / n), log1p(1000 * eHigh / n), log1p(1000 * eAll / n))
        if let p = previous {
            let l = max(0, now.0 - p.0), h = max(0, now.1 - p.1), a = max(0, now.2 - p.2)
            flux.append(l + h + a)
            low.append(l)
        } else {
            flux.append(0)
            low.append(0)
        }
        previous = now
        eLow = 0; eHigh = 0; eAll = 0
        filled = 0
    }
}

/// A song's tempo as heard in its audio.
public struct TempoEstimate: Codable, Equatable, Sendable {
    /// Quarter notes per minute.
    public var bpm: Double
    /// Seconds into the file of the first beat.
    public var firstBeat: Double
    /// Seconds into the file of a likely bar start (beat one); a guess, right more often than not.
    public var downbeat: Double
    /// How clearly the beats stand out: how much harder they land at their best timing than at
    /// an average one (noise ~2; a click track 30+; at least 3 counts as confident).
    public var strength: Double
    /// The channel it came from (nil = all the music channels together).
    public var channel: Int?
    /// The next likeliest tempos (often half, double, or 3:4 of it), best first.
    public var alternatives: [Double]?

    public var isConfident: Bool { strength >= TempoDetector.confident }

    public init(bpm: Double, firstBeat: Double, downbeat: Double, strength: Double, channel: Int? = nil) {
        self.bpm = bpm
        self.firstBeat = firstBeat
        self.downbeat = downbeat
        self.strength = strength
        self.channel = channel
    }
}

public enum TempoDetector {
    public static let confident = 3.0
    // Tuning, checked against Apple Loops layered into songs (other settings did no better).
    static let priorCentre = 115.0
    static let priorWidth = 0.9
    static let wHalf = 0.75
    static let wBar = 0.75
    static let wTwo = 0.0
    static let wSub = 0.35

    /// The tempo of an onset envelope. `hint` (e.g. a BPM in the file name) is trusted for the
    /// tempo and only refined a little; the beats' positions come from the audio either way.
    public static func estimate(_ envelope: OnsetEnvelope, beatsPerBar: Int = 4, hint: Double? = nil,
                                minBPM: Double = 55, maxBPM: Double = 210) -> TempoEstimate? {
        estimate(flux: envelope.flux, low: envelope.low, hopSeconds: envelope.hopSeconds,
                 beatsPerBar: beatsPerBar, hint: hint, minBPM: minBPM, maxBPM: maxBPM)
    }

    public static func estimate(flux: [Float], low: [Float], hopSeconds: Double, beatsPerBar: Int = 4,
                                hint: Double? = nil, minBPM: Double = 55, maxBPM: Double = 210) -> TempoEstimate? {
        let n = flux.count
        guard n > 0, Double(n) * hopSeconds >= 6 else { return nil }
        let o = normalized(flux, hopSeconds: hopSeconds)
        let mean = o.reduce(0, +) / Float(n)
        guard mean > 0 else { return nil }

        // 1. Candidates: the strongest repeats in the attacks (autocorrelation peaks), each with
        // the tempos it's most often confused with (double, half, 3:2, 2:3).
        let maxLag = min(n - 1, Int((60 / minBPM / hopSeconds * 8).rounded(.up)))
        var ac = [Double](repeating: 0, count: maxLag + 1)
        for lag in 1...maxLag {
            var sum: Float = 0
            for i in 0..<(n - lag) { sum += o[i] * o[i + lag] }
            ac[lag] = Double(sum) / Double(n - lag)
        }
        func acAt(_ lag: Double) -> Double {
            let i = Int(lag)
            guard i >= 1, i + 1 <= maxLag else { return 0 }
            let f = lag - Double(i)
            return ac[i] * (1 - f) + ac[i + 1] * f
        }
        var candidates: [Double] = []
        if let hint, hint > 0 {
            candidates = [hint]
        } else {
            let lagMin = max(2, Int((60 / maxBPM / hopSeconds).rounded(.down)))
            let lagMax = min(maxLag - 1, Int((60 / minBPM / hopSeconds).rounded(.up)))
            guard lagMax > lagMin + 2 else { return nil }
            let peaks = (lagMin + 1..<lagMax).filter { ac[$0] > ac[$0 - 1] && ac[$0] >= ac[$0 + 1] }
                .sorted { ac[$0] > ac[$1] }.prefix(6)
            for lag in peaks {
                let bpm = 60 / (Double(lag) * hopSeconds)
                for ratio in [1.0, 2, 0.5, 1.5, 2.0 / 3, 4.0 / 3, 0.75] {
                    let c = bpm * ratio
                    if c >= minBPM, c <= maxBPM, !candidates.contains(where: { abs($0 / c - 1) < 0.01 }) { candidates.append(c) }
                }
            }
        }
        guard !candidates.isEmpty else { return nil }

        // 2. Which candidate is the beat: the music repeats every beat, every 2 and every 4 (a
        // bar), so the right tempo lines up at all three; a 3:2 or 4:3 mistake only at some.
        func metre(_ bpm: Double) -> Double {
            let lag = 60 / bpm / hopSeconds
            return acAt(lag) + wHalf * acAt(2 * lag) + wBar * acAt(4 * lag) + wTwo * acAt(8 * lag) + wSub * acAt(lag / 2)
        }
        let ranked = candidates.map { c in (c, metre(c) * (hint == nil ? prior(c) : 1)) }.sorted { $0.1 > $1.1 }

        // 3. Refine the best few: the tempo and phase whose beats land hardest on the attacks,
        // over the whole song (finer than the autocorrelation's whole-hop steps).
        var best: (score: Double, bpm: Double, phase: Double) = (-1, ranked[0].0, 0)
        let leader = ranked[0].1
        for (c, m) in ranked.prefix(3) where m >= leader * 0.92 || c == ranked[0].0 {
            let found = refine(o, around: c, span: hint == nil ? 0.015 : 0.01, hopSeconds: hopSeconds)
            let score = metre(found.bpm) * (hint == nil ? prior(found.bpm) : 1)
            if score > best.score { best = (score, found.bpm, found.phase) }
        }
        let strength = contrast(o, bpm: best.bpm, hopSeconds: hopSeconds)
        // Runners-up, for offering in Tempo…: distinct from the winner and each other.
        var alternatives: [Double] = []
        for (c, _) in ranked.prefix(6) where alternatives.count < 2 && hint == nil {
            guard abs(c / best.bpm - 1) > 0.03 else { continue }
            let fine = refine(o, around: c, span: 0.015, hopSeconds: hopSeconds).bpm
            let r = abs(fine - fine.rounded()) < 0.12 ? fine.rounded() : (fine * 100).rounded() / 100
            if abs(r / best.bpm - 1) > 0.03, !alternatives.contains(where: { abs(r / $0 - 1) < 0.03 }) { alternatives.append(r) }
        }

        // 4. Whole numbers when it's that close (most show tracks are).
        var bpm = best.bpm
        if abs(bpm - bpm.rounded()) < 0.12 { bpm = bpm.rounded() }
        let period = 60 / bpm / hopSeconds
        let phase = best.phase.truncatingRemainder(dividingBy: period)

        // 5. Beat one: of the beats in a bar, the one with the most low end (kick on one).
        let perBar = max(1, beatsPerBar)
        var bars = [Double](repeating: 0, count: perBar)
        var k = 0
        while phase + Double(k) * period < Double(n - 1) {
            bars[k % perBar] += Double(sample(low, at: phase + Double(k) * period))
            k += 1
        }
        let one = bars.indices.max { bars[$0] < bars[$1] } ?? 0
        // Hop i covers samples i·hop…(i+1)·hop; an attack is heard in the middle of that.
        let first = (phase + 0.5) * hopSeconds
        var estimate = TempoEstimate(bpm: bpm, firstBeat: first, downbeat: first + Double(one) * period * hopSeconds,
                                     strength: strength)
        estimate.alternatives = hint == nil && !alternatives.isEmpty ? alternatives : nil
        return estimate
    }

    /// The strongest of several channels' estimates (a click channel wins when there is one);
    /// the mix is preferred unless a channel is clearly stronger.
    public static func best(mix: TempoEstimate?, channels: [Int: TempoEstimate]) -> TempoEstimate? {
        var winner = mix
        for (channel, e) in channels.sorted(by: { $0.key < $1.key }) {
            var e = e
            e.channel = channel
            if e.strength > (winner?.strength ?? 0) * 1.15 { winner = e }
        }
        return winner
    }

    // MARK: Pieces

    /// Attacks above their local average (so a loud chorus doesn't swamp a quiet verse), scaled.
    private static func normalized(_ flux: [Float], hopSeconds: Double) -> [Float] {
        let n = flux.count
        let half = max(1, Int(0.4 / hopSeconds))
        var prefix = [Float](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + flux[i] }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let a = max(0, i - half), b = min(n, i + half + 1)
            let local = (prefix[b] - prefix[a]) / Float(b - a)
            out[i] = max(0, flux[i] - local)
        }
        let peak = out.max() ?? 0
        if peak > 0 { for i in 0..<n { out[i] /= peak } }
        return out
    }

    /// Common tempos are likelier: a broad bell around 115 BPM, on a log scale.
    private static func prior(_ bpm: Double) -> Double {
        let x = log2(bpm / priorCentre) / priorWidth
        return exp(-0.5 * x * x)
    }

    /// Mean attack strength on the beats, for the best phase, over tempos within `span` of
    /// `bpm` (as a fraction), 0.01 BPM apart.
    private static func refine(_ o: [Float], around bpm: Double, span: Double, hopSeconds: Double) -> (score: Double, bpm: Double, phase: Double) {
        let n = o.count
        let lo = bpm * (1 - span), hi = bpm * (1 + span)
        let steps = span == 0 ? 0 : Int(((hi - lo) / 0.01).rounded())
        var best: (score: Double, bpm: Double, phase: Double) = (-1, bpm, 0)
        // Coarse phases first (a quarter hop apart is plenty: a hop is ~10 ms).
        for s in 0...steps {
            let candidate = steps == 0 ? bpm : lo + Double(s) * (hi - lo) / Double(steps)
            let period = 60 / candidate / hopSeconds
            guard period >= 2 else { continue }
            var phase = 0.0
            while phase < period {
                var sum: Float = 0
                var count = 0
                var t = phase
                while t < Double(n - 1) {
                    sum += sample(o, at: t)
                    count += 1
                    t += period
                }
                if count > 0 {
                    let score = Double(sum) / Double(count)
                    if score > best.score { best = (score, candidate, phase) }
                }
                phase += 0.5
            }
        }
        return best
    }

    /// How much harder the beats land at their best phase than at an average one, at this tempo:
    /// steady music lines up at one phase and not the others; noise lines up nowhere.
    private static func contrast(_ o: [Float], bpm: Double, hopSeconds: Double) -> Double {
        let n = o.count
        let period = 60 / bpm / hopSeconds
        guard period >= 2 else { return 0 }
        var scores: [Double] = []
        var phase = 0.0
        while phase < period {
            var sum: Float = 0
            var count = 0
            var t = phase
            while t < Double(n - 1) { sum += sample(o, at: t); count += 1; t += period }
            if count > 0 { scores.append(Double(sum) / Double(count)) }
            phase += 0.5
        }
        let mean = scores.reduce(0, +) / Double(max(1, scores.count))
        return mean > 0 ? (scores.max() ?? 0) / mean : 0
    }

    /// Linear interpolation between hops.
    private static func sample(_ a: [Float], at t: Double) -> Float {
        let i = Int(t)
        guard i >= 0, i + 1 < a.count else { return i >= 0 && i < a.count ? a[i] : 0 }
        let f = Float(t - Double(i))
        return a[i] * (1 - f) + a[i + 1] * f
    }
}
