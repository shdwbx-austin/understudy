import Testing
@testable import UnderstudyCore

/// One engine step against a simulated deck: it plays once it's been told to (the engine is
/// chasing), as a real deck's transport reports.
private func simStep(_ s: inout DeckChaseState, ltc: LTCSnapshot, input: DeckChaseInput, now: Double,
                     settings: ChaseSettings) -> [ChaseAction] {
    var input = input
    if case .playing = s.phase { input.deckIsPlaying = true }
    return ChaseEngine.step(&s, ltc: ltc, input: input, now: now, settings: settings)
}

struct ChaseEngineTests {
    private var settings: ChaseSettings {
        // The park-ahead path (fast pickup has its own tests below).
        var s = ChaseSettings()
        s.fastStart = false
        s.prerollSeconds = 1.0
        s.cueSettleSeconds = 0.3
        return s
    }

    private func ltc(_ t: Double, rolling: Bool = true) -> LTCSnapshot {
        LTCSnapshot(rolling: rolling, position: rolling ? 1000 + t * 30 : nil, jumped: false, fps: 30)
    }

    @Test func cuesAheadThenFiresPlayOnTime() {
        var state = DeckChaseState()
        let input = DeckChaseInput(startLatencyFrames: 3, coverage: nil, observedError: nil, deckIsPlaying: false)
        var cueAt: Double?
        var playAt: Double?
        for step in 0..<200 {
            let t = Double(step) * 0.01
            for action in simStep(&state, ltc: ltc(t), input: input, now: t, settings: settings) {
                switch action {
                case .cue(let target):
                    #expect(target == 1030)
                    cueAt = t
                case .play: playAt = t
                case .cueAndPlay: Issue.record("park-ahead path sent a fast start")
                case .stop: Issue.record("unexpected stop")
                case .learnOffset, .trimOffset: Issue.record("unexpected offset change")
                }
            }
        }
        #expect(cueAt == 0)
        // Fires when LTC reaches 1030 - 3 frames = 0.9 s.
        #expect(abs((playAt ?? -1) - 0.9) <= 0.011)
        guard case .playing = state.phase else {
            Issue.record("not playing")
            return
        }
    }

    /// Found on a real HyperDeck: pre-roll 0.5 s with a 0.5 s settle never leaves the deck time to
    /// arm, so every cue was abandoned and re-cued a second later and the deck never played; the
    /// picture stepped forward once a second instead.
    @Test func shortPrerollStillPlaysInsteadOfRecueingForever() {
        var short = ChaseSettings()
        short.fastStart = false
        short.prerollSeconds = 0.5
        short.cueSettleSeconds = 0.5
        var state = DeckChaseState()
        let input = DeckChaseInput(startLatencyFrames: 0, coverage: nil, observedError: nil, deckIsPlaying: false)
        var cues = 0
        var played = false
        for step in 0..<500 {
            let t = Double(step) * 0.01
            for action in simStep(&state, ltc: ltc(t), input: input, now: t, settings: short) {
                if case .cue = action { cues += 1 }
                if action == .play { played = true }
            }
        }
        #expect(played)
        #expect(cues == 1)
    }

    @Test func effectivePrerollCoversSettleAndStartLatency() {
        var s = ChaseSettings()
        s.prerollSeconds = 0.5
        s.cueSettleSeconds = 0.5
        // 0.5 s settle + 3 frames of start latency + 1 frame + margin, at 30 fps.
        let floor: Double = 0.5 + 4.0 / 30.0 + 0.25
        #expect(ChaseEngine.effectivePreroll(s, startLatencyFrames: 3, fps: 30) >= floor - 1e-9)
        s.prerollSeconds = 2
        #expect(ChaseEngine.effectivePreroll(s, startLatencyFrames: 3, fps: 30) == 2)
    }

    /// Measured on a HyperDeck Studio 4K Pro: it starts about 3–4 frames late, so with a 0 play offset
    /// every play sat steadily behind code, tripped the drift check and was re-parked: a stutter
    /// every few seconds. A steady, consistent lag is a start delay: learn it once instead.
    @Test func steadyLagIsLearnedOnceInsteadOfRelocking() {
        var state = DeckChaseState()
        state.phase = .playing(since: 0, segment: nil)
        var learned: [Double] = []
        var t = 1.0
        for k in 0..<12 {
            let jitter = [0.0, 0.6, -0.5, 0.3][k % 4]
            let input = DeckChaseInput(startLatencyFrames: 0, coverage: nil, observedError: -3.5 + jitter, deckIsPlaying: true)
            for action in simStep(&state, ltc: ltc(t), input: input, now: t, settings: settings) {
                if case .learnOffset(let by) = action { learned.append(by) }
            }
            t += 0.1
            if state.phase == .idle { break }
        }
        #expect(learned.count == 1)
        #expect(abs((learned.first ?? 0) - 3.5) < 0.6)
        #expect(state.phase == .idle)
        #expect(state.relocks == 0)
    }

    @Test func erraticErrorStillRelocksWithBackoff() {
        var state = DeckChaseState()
        state.phase = .playing(since: 0, segment: nil)
        var learned = false
        for (k, error) in [-2.0, 4.0, -6.0, 5.0].enumerated() {
            let t = 1 + Double(k) * 0.1
            let input = DeckChaseInput(startLatencyFrames: 0, coverage: nil, observedError: error, deckIsPlaying: true)
            for action in simStep(&state, ltc: ltc(t), input: input, now: t, settings: settings) {
                if case .learnOffset = action { learned = true }
            }
        }
        #expect(!learned)
        #expect(state.phase == .idle)
        #expect(state.relocks == 1)
    }

    /// Seen on the same deck: playing 3 s behind code for 5.6 s, because earlier re-locks had
    /// grown the back-off. A deck that far off is re-parked after two readings, back-off unchanged.
    @Test func farOffDeckIsReparkedPromptly() {
        var state = DeckChaseState()
        state.phase = .playing(since: 0, segment: nil)
        state.relocks = 3
        let input = DeckChaseInput(startLatencyFrames: 0, coverage: nil, observedError: -92, deckIsPlaying: true)
        _ = simStep(&state, ltc: ltc(1.0), input: input, now: 1.0, settings: settings)
        #expect(state.phase != .idle)
        _ = simStep(&state, ltc: ltc(1.1), input: input, now: 1.1, settings: settings)
        #expect(state.phase == .idle)
        #expect(state.relocks == 3)
    }

    @Test func stopsWhenCodeStops() {
        var state = DeckChaseState()
        state.phase = .playing(since: 0, segment: nil)
        let input = DeckChaseInput(startLatencyFrames: 0, coverage: nil, observedError: nil, deckIsPlaying: true)
        #expect(simStep(&state, ltc: ltc(5, rolling: false), input: input, now: 5, settings: settings) == [.stop])
        #expect(state.phase == .idle)
    }

    @Test func driftTriggersRelock() {
        var state = DeckChaseState()
        state.phase = .playing(since: 0, segment: nil)
        state.lastCueTime = 0
        let drifting = DeckChaseInput(startLatencyFrames: 0, coverage: nil, observedError: 4, deckIsPlaying: true)
        for k in 0..<settings.driftStrikes {
            let t = 2 + Double(k) * 0.1
            _ = simStep(&state, ltc: ltc(t), input: drifting, now: t, settings: settings)
        }
        #expect(state.phase == .idle)
        let actions = simStep(&state, ltc: ltc(3), input: drifting, now: 3, settings: settings)
        #expect(actions == [.cue(target: 1120)])
    }

    @Test func repeatedRelocksBackOff() {
        var state = DeckChaseState()
        let drifting = DeckChaseInput(startLatencyFrames: 0, coverage: nil, observedError: 4, deckIsPlaying: true)
        var cues: [Double] = []
        var t = 0.0
        while t < 40 {
            for action in simStep(&state, ltc: ltc(t), input: drifting, now: t, settings: settings) {
                if case .cue = action { cues.append(t) }
            }
            t += 0.05
        }
        // Gaps between cues grow (1 s, 2 s, 4 s, … plus cue/play time) instead of re-cueing every couple of seconds.
        let gaps = zip(cues.dropFirst(), cues).map { $0 - $1 }
        #expect(cues.count < 12)
        #expect((gaps.last ?? 0) > (gaps.first ?? 0) + 5)
    }

    @Test func holdsOutsideTakeRange() {
        var state = DeckChaseState()
        let input = DeckChaseInput(startLatencyFrames: 0, coverage: [2000..<3000], observedError: nil, deckIsPlaying: false)
        #expect(simStep(&state, ltc: ltc(0), input: input, now: 0, settings: settings) == [])
        #expect(state.phase == .outOfRange)
        // Preroll is 30 frames, so the deck can cue once LTC passes 1970 (t ≈ 32.33 s).
        #expect(simStep(&state, ltc: ltc(32.4), input: input, now: 32.4, settings: settings) == [.cue(target: 2002)])
    }

    @Test func stopsAtGapInRecordedCode() {
        var state = DeckChaseState()
        state.phase = .playing(since: 0, segment: 0)
        let input = DeckChaseInput(startLatencyFrames: 0, coverage: [1000..<1100, 1200..<1300], observedError: nil, deckIsPlaying: true)
        // LTC 1105 (t = 3.5 s) is past the first stretch and not recorded.
        #expect(simStep(&state, ltc: ltc(3.5), input: input, now: 3.5, settings: settings) == [.stop])
        #expect(state.phase == .outOfRange)
        // Code reaches the second stretch: cue into it.
        #expect(simStep(&state, ltc: ltc(6), input: input, now: 6, settings: settings) == [.cue(target: 1210)])
    }

    @Test func reparksWhenCodeRunsIntoAnotherRecordedStretch() {
        var state = DeckChaseState()
        state.phase = .playing(since: 0, segment: 0)
        // Two adjacent stretches recorded at different points of the clip (code jumped while recording).
        let input = DeckChaseInput(startLatencyFrames: 0, coverage: [1000..<1100, 1100..<1300], observedError: nil, deckIsPlaying: true)
        #expect(simStep(&state, ltc: ltc(3.5), input: input, now: 3.5, settings: settings) == [])
        #expect(state.phase == .idle)
        #expect(simStep(&state, ltc: ltc(3.51), input: input, now: 3.51, settings: settings) == [.cue(target: 1135)])
    }

    @Test func playingRecordsWhichStretch() {
        var state = DeckChaseState()
        let input = DeckChaseInput(startLatencyFrames: 0, coverage: [900..<1010, 1020..<2000], observedError: nil, deckIsPlaying: false)
        for step in 0..<200 {
            let t = Double(step) * 0.01
            _ = simStep(&state, ltc: ltc(t), input: input, now: t, settings: settings)
        }
        #expect(state.phase == .playing(since: 1.0, segment: 1))
    }

    // MARK: Fast pickup

    private func fastActions(from t0: Double, to t1: Double, latency: Double, state: inout DeckChaseState,
                             ltcAt: (Double) -> LTCSnapshot) -> [(Double, ChaseAction)] {
        var out: [(Double, ChaseAction)] = []
        let input = DeckChaseInput(startLatencyFrames: latency, coverage: nil, observedError: nil, deckIsPlaying: false)
        var t = t0
        while t <= t1 + 1e-9 {
            for a in simStep(&state, ltc: ltcAt(t), input: input, now: t, settings: ChaseSettings()) { out.append((t, a)) }
            t += 0.005   // the app's tick
        }
        return out
    }

    /// Measured on a HyperDeck Studio 4K Pro: goto ~30 ms, then ~55 ms to roll (play offset 2 at 30 fps).
    /// The deck must be sent goto-and-play within a tick or two of code starting, aimed at the
    /// frame code will be on when it rolls.
    @Test func fastPickupStartsTheDeckAtOnce() {
        #expect(ChaseSettings().fastStart)
        var state = DeckChaseState()
        let actions = fastActions(from: 0, to: 1, latency: 2, state: &state, ltcAt: { self.ltc($0) })
        #expect(actions.count == 1)
        guard let (t, action) = actions.first, case .cueAndPlay(let target) = action else {
            Issue.record("no fast start: \(actions)")
            return
        }
        // Lead 2 + 0.02 × 30 = 2.6 frames: aimed at 1003, sent when code reaches 1000.4 (t ≈ 0.013).
        #expect(target == 1003)
        #expect(t <= 0.045)
        let codeAtSend = 1000 + t * 30
        #expect(abs((codeAtSend + 2.6) - Double(target)) <= 0.2)   // lands on time to within a fifth of a frame
        guard case .playing = state.phase else { Issue.record("not chasing"); return }
    }

    /// A timeline that starts slightly in the future (its audio lead) reads as code just before the
    /// playhead: the deck is sent at once and rolls as the timeline does.
    @Test func fastPickupFromATimelineStart() {
        var state = DeckChaseState()
        let actions = fastActions(from: 0, to: 0.3, latency: 2, state: &state,
                                  ltcAt: { LTCSnapshot(rolling: true, position: 2000 + ($0 - 0.12) * 30, jumped: false, fps: 30) })
        guard let (t, action) = actions.first, case .cueAndPlay(let target) = action else {
            Issue.record("no fast start")
            return
        }
        // Code is 1996.4 at t = 0; aimed at 2000 (1996.4 + 2.6 lead + margin, rounded up) and sent
        // when code is 2.6 frames short of it, so the deck rolls on 2000 as the timeline starts (t = 0.12).
        #expect(target == 2000)
        #expect(abs((t + 2.6 / 30) - 0.12) <= 0.006)
        #expect(actions.count == 1)
    }

    @Test func fastPickupAfterAJump() {
        var state = DeckChaseState()
        _ = fastActions(from: 0, to: 2, latency: 2, state: &state, ltcAt: { self.ltc($0) })
        // Code jumps to 5000 at t = 2: the deck is re-sent within a tick, cooldown or not.
        let jumpInput = DeckChaseInput(startLatencyFrames: 2, coverage: nil, observedError: nil, deckIsPlaying: true)
        let jumped = LTCSnapshot(rolling: true, position: 5000, jumped: true, fps: 30)
        var sent: [ChaseAction] = simStep(&state, ltc: jumped, input: jumpInput, now: 2.0, settings: ChaseSettings())
        var t = 2.005
        while sent.isEmpty, t < 2.1 {
            sent = simStep(&state, ltc: LTCSnapshot(rolling: true, position: 5000 + (t - 2) * 30, jumped: false, fps: 30),
                                    input: jumpInput, now: t, settings: ChaseSettings())
            t += 0.005
        }
        guard case .cueAndPlay(let target) = sent.first else { Issue.record("no re-start after jump"); return }
        #expect(target == 5003)
        #expect(t - 2 <= 0.05)
    }

    @Test func fastPickupStillLearnsAStartDelay() {
        var state = DeckChaseState()
        _ = fastActions(from: 0, to: 0.1, latency: 0, state: &state, ltcAt: { self.ltc($0) })
        // The deck runs a steady 2 frames late (start delay not learned yet).
        var learned: Double?
        var t = 1.0
        while t < 2.0, learned == nil {
            let input = DeckChaseInput(startLatencyFrames: 0, coverage: nil, observedError: -2, deckIsPlaying: true)
            for a in simStep(&state, ltc: ltc(t), input: input, now: t, settings: ChaseSettings()) {
                if case .learnOffset(let by) = a { learned = by }
            }
            t += 0.1
        }
        #expect(learned == 2)
    }

    /// A deck that stops by itself mid-chase (seen once on a HyperDeck Studio 4K Pro) is started
    /// again within a tick, not after drift readings and the cooldown (about 0.7 s).
    @Test func deckThatStopsByItselfIsRestartedAtOnce() {
        var state = DeckChaseState()
        _ = fastActions(from: 0, to: 1.3, latency: 2, state: &state, ltcAt: { self.ltc($0) })
        guard case .playing = state.phase else { Issue.record("not chasing"); return }
        let stopped = DeckChaseInput(startLatencyFrames: 2, coverage: nil, observedError: nil, deckIsPlaying: false)
        var restart: Double?
        var t = 1.3
        while restart == nil, t < 1.5 {
            for a in ChaseEngine.step(&state, ltc: ltc(t), input: stopped, now: t, settings: ChaseSettings()) {
                if case .cueAndPlay = a { restart = t }
            }
            t += 0.005
        }
        #expect(restart != nil && restart! - 1.3 <= 0.045)   // the next whole frame it can reach
        // A deck that keeps stopping (e.g. off the end of its clip) backs off instead of being re-fired every tick.
        var refires = 0
        t = 1.4
        while t < 3.0 {
            for a in ChaseEngine.step(&state, ltc: ltc(t), input: stopped, now: t, settings: ChaseSettings()) {
                if case .cueAndPlay = a { refires += 1 }
            }
            t += 0.005
        }
        #expect(refires <= 1)
    }

    /// Holding steadily 0.7 frames ahead (inside tolerance): trims the play offset, no re-park.
    @Test func smallSteadyErrorTrimsTheOffset() {
        var state = DeckChaseState()
        _ = fastActions(from: 0, to: 0.1, latency: 2, state: &state, ltcAt: { self.ltc($0) })
        var trims: [Double] = []
        var other: [ChaseAction] = []
        var t = 1.0
        var flip = false
        while t < 4.0 {
            flip.toggle()
            let input = DeckChaseInput(startLatencyFrames: 2, coverage: nil, observedError: flip ? 0.5 : 0.9, deckIsPlaying: true)
            for a in ChaseEngine.step(&state, ltc: ltc(t), input: input, now: t, settings: ChaseSettings()) {
                if case .trimOffset(let by) = a { trims.append(by) } else { other.append(a) }
            }
            t += 0.1
        }
        #expect(trims.first == -0.7)
        #expect(other.isEmpty)
        guard case .playing = state.phase else { Issue.record("re-parked"); return }
        // Within a quarter frame: left alone.
        var quiet = DeckChaseState()
        _ = fastActions(from: 0, to: 0.1, latency: 2, state: &quiet, ltcAt: { self.ltc($0) })
        t = 1.0
        var any = false
        while t < 4.0 {
            let input = DeckChaseInput(startLatencyFrames: 2, coverage: nil, observedError: 0.25, deckIsPlaying: true)
            if !ChaseEngine.step(&quiet, ltc: ltc(t), input: input, now: t, settings: ChaseSettings()).isEmpty { any = true }
            t += 0.1
        }
        #expect(!any)
    }
}
