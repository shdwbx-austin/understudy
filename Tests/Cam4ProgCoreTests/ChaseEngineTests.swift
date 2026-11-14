import XCTest
@testable import Cam4ProgCore

final class ChaseEngineTests: XCTestCase {
    private var settings: ChaseSettings {
        var s = ChaseSettings()
        s.prerollSeconds = 1.0
        s.cueSettleSeconds = 0.3
        return s
    }

    private func ltc(_ t: Double, rolling: Bool = true) -> LTCSnapshot {
        LTCSnapshot(rolling: rolling, position: rolling ? 1000 + t * 30 : nil, jumped: false, fps: 30)
    }

    func testCuesAheadThenFiresPlayOnTime() {
        var state = DeckChaseState()
        let input = DeckChaseInput(startLatencyFrames: 3, range: nil, observedError: nil, deckIsPlaying: false)
        var cueAt: Double?
        var playAt: Double?
        for step in 0..<200 {
            let t = Double(step) * 0.01
            for action in ChaseEngine.step(&state, ltc: ltc(t), input: input, now: t, settings: settings) {
                switch action {
                case .cue(let target):
                    XCTAssertEqual(target, 1030)
                    cueAt = t
                case .play: playAt = t
                case .stop: XCTFail("unexpected stop")
                }
            }
        }
        XCTAssertEqual(cueAt, 0)
        // Fires when LTC reaches 1030 - 3 frames = 0.9 s.
        XCTAssertEqual(playAt ?? -1, 0.9, accuracy: 0.011)
        if case .playing = state.phase {} else { XCTFail("not playing") }
    }

    func testStopsWhenCodeStops() {
        var state = DeckChaseState()
        state.phase = .playing(since: 0)
        let input = DeckChaseInput(startLatencyFrames: 0, range: nil, observedError: nil, deckIsPlaying: true)
        XCTAssertEqual(ChaseEngine.step(&state, ltc: ltc(5, rolling: false), input: input, now: 5, settings: settings), [.stop])
        XCTAssertEqual(state.phase, .idle)
    }

    func testDriftTriggersRelock() {
        var state = DeckChaseState()
        state.phase = .playing(since: 0)
        state.lastCueTime = 0
        let drifting = DeckChaseInput(startLatencyFrames: 0, range: nil, observedError: 4, deckIsPlaying: true)
        for k in 0..<settings.driftStrikes {
            let t = 2 + Double(k) * 0.1
            _ = ChaseEngine.step(&state, ltc: ltc(t), input: drifting, now: t, settings: settings)
        }
        XCTAssertEqual(state.phase, .idle)
        let actions = ChaseEngine.step(&state, ltc: ltc(3), input: drifting, now: 3, settings: settings)
        XCTAssertEqual(actions, [.cue(target: 1120)])
    }

    func testHoldsOutsideTakeRange() {
        var state = DeckChaseState()
        let input = DeckChaseInput(startLatencyFrames: 0, range: 2000...3000, observedError: nil, deckIsPlaying: false)
        XCTAssertEqual(ChaseEngine.step(&state, ltc: ltc(0), input: input, now: 0, settings: settings), [])
        XCTAssertEqual(state.phase, .outOfRange)
        // Preroll is 30 frames, so the deck can cue once LTC passes 1970 (t ≈ 32.33 s).
        XCTAssertEqual(ChaseEngine.step(&state, ltc: ltc(32.4), input: input, now: 32.4, settings: settings), [.cue(target: 2002)])
    }
}
