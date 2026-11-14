import Testing
@testable import UnderstudyCore

struct ChaseEngineTests {
    private var settings: ChaseSettings {
        var s = ChaseSettings()
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
            for action in ChaseEngine.step(&state, ltc: ltc(t), input: input, now: t, settings: settings) {
                switch action {
                case .cue(let target):
                    #expect(target == 1030)
                    cueAt = t
                case .play: playAt = t
                case .stop: Issue.record("unexpected stop")
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

    @Test func stopsWhenCodeStops() {
        var state = DeckChaseState()
        state.phase = .playing(since: 0, segment: nil)
        let input = DeckChaseInput(startLatencyFrames: 0, coverage: nil, observedError: nil, deckIsPlaying: true)
        #expect(ChaseEngine.step(&state, ltc: ltc(5, rolling: false), input: input, now: 5, settings: settings) == [.stop])
        #expect(state.phase == .idle)
    }

    @Test func driftTriggersRelock() {
        var state = DeckChaseState()
        state.phase = .playing(since: 0, segment: nil)
        state.lastCueTime = 0
        let drifting = DeckChaseInput(startLatencyFrames: 0, coverage: nil, observedError: 4, deckIsPlaying: true)
        for k in 0..<settings.driftStrikes {
            let t = 2 + Double(k) * 0.1
            _ = ChaseEngine.step(&state, ltc: ltc(t), input: drifting, now: t, settings: settings)
        }
        #expect(state.phase == .idle)
        let actions = ChaseEngine.step(&state, ltc: ltc(3), input: drifting, now: 3, settings: settings)
        #expect(actions == [.cue(target: 1120)])
    }

    @Test func repeatedRelocksBackOff() {
        var state = DeckChaseState()
        let drifting = DeckChaseInput(startLatencyFrames: 0, coverage: nil, observedError: 4, deckIsPlaying: true)
        var cues: [Double] = []
        var t = 0.0
        while t < 40 {
            for action in ChaseEngine.step(&state, ltc: ltc(t), input: drifting, now: t, settings: settings) {
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
        #expect(ChaseEngine.step(&state, ltc: ltc(0), input: input, now: 0, settings: settings) == [])
        #expect(state.phase == .outOfRange)
        // Preroll is 30 frames, so the deck can cue once LTC passes 1970 (t ≈ 32.33 s).
        #expect(ChaseEngine.step(&state, ltc: ltc(32.4), input: input, now: 32.4, settings: settings) == [.cue(target: 2002)])
    }

    @Test func stopsAtGapInRecordedCode() {
        var state = DeckChaseState()
        state.phase = .playing(since: 0, segment: 0)
        let input = DeckChaseInput(startLatencyFrames: 0, coverage: [1000..<1100, 1200..<1300], observedError: nil, deckIsPlaying: true)
        // LTC 1105 (t = 3.5 s) is past the first stretch and not recorded.
        #expect(ChaseEngine.step(&state, ltc: ltc(3.5), input: input, now: 3.5, settings: settings) == [.stop])
        #expect(state.phase == .outOfRange)
        // Code reaches the second stretch: cue into it.
        #expect(ChaseEngine.step(&state, ltc: ltc(6), input: input, now: 6, settings: settings) == [.cue(target: 1210)])
    }

    @Test func reparksWhenCodeRunsIntoAnotherRecordedStretch() {
        var state = DeckChaseState()
        state.phase = .playing(since: 0, segment: 0)
        // Two adjacent stretches recorded at different points of the clip (code jumped while recording).
        let input = DeckChaseInput(startLatencyFrames: 0, coverage: [1000..<1100, 1100..<1300], observedError: nil, deckIsPlaying: true)
        #expect(ChaseEngine.step(&state, ltc: ltc(3.5), input: input, now: 3.5, settings: settings) == [])
        #expect(state.phase == .idle)
        #expect(ChaseEngine.step(&state, ltc: ltc(3.51), input: input, now: 3.51, settings: settings) == [.cue(target: 1135)])
    }

    @Test func playingRecordsWhichStretch() {
        var state = DeckChaseState()
        let input = DeckChaseInput(startLatencyFrames: 0, coverage: [900..<1010, 1020..<2000], observedError: nil, deckIsPlaying: false)
        for step in 0..<200 {
            let t = Double(step) * 0.01
            _ = ChaseEngine.step(&state, ltc: ltc(t), input: input, now: t, settings: settings)
        }
        #expect(state.phase == .playing(since: 1.0, segment: 1))
    }
}
