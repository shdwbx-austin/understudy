import Testing
@testable import UnderstudyCore

struct PictureCheckTests {
    /// A 32×18 grid: a gradient that moves with `phase`, scaled by `brightness`.
    private func picture(_ phase: Int, brightness: Float = 1, noise: Float = 0) -> LumaGrid {
        var values: [Float] = []
        for y in 0..<18 {
            for x in 0..<32 {
                let base = Float((x + y + phase) % 32) / 32
                let jitter = noise == 0 ? 0 : Float.random(in: -noise...noise)
                values.append(max(0, min(1, base * brightness + jitter)))
            }
        }
        return LumaGrid(width: 32, height: 18, values: values)
    }

    private func black(noise: Float = 0.01) -> LumaGrid {
        LumaGrid(width: 32, height: 18, values: (0..<(32 * 18)).map { _ in Float.random(in: 0...noise) })
    }

    @Test func movingPictureIsFine() {
        var c = PictureChecker()
        var state = PictureState.noFeed
        for k in 0..<50 { state = c.update(picture(k, noise: 0.01), at: Double(k) * 0.2) }
        #expect(state == .picture)
    }

    @Test func blackAfterHoldNotDuringFade() {
        var c = PictureChecker()
        for k in 0..<10 { c.update(picture(k), at: Double(k) * 0.2) }
        // A one-second fade through black: not reported.
        for k in 10..<15 { #expect(c.update(black(), at: Double(k) * 0.2) == .picture) }
        for k in 15..<20 { c.update(picture(k), at: Double(k) * 0.2) }
        // Held black: reported after 2 s.
        var state = PictureState.picture
        for k in 20..<32 { state = c.update(black(), at: Double(k) * 0.2) }
        #expect(state == .black)
    }

    @Test func darkSceneWithHighlightsIsNotBlack() {
        var c = PictureChecker()
        var state = PictureState.picture
        for k in 0..<30 {
            var values = (0..<(32 * 18)).map { _ in Float.random(in: 0...0.02) }
            for i in stride(from: k % 7, to: values.count, by: 40) { values[i] = 0.8 }   // stage lights
            state = c.update(LumaGrid(width: 32, height: 18, values: values), at: Double(k) * 0.2)
        }
        #expect(state != .black)
    }

    @Test func stillAfterHoldIgnoringCaptureNoise() {
        var c = PictureChecker()
        var state = PictureState.picture
        for k in 0..<10 { state = c.update(picture(5, noise: 0.001), at: Double(k) * 0.2) }
        #expect(state == .picture)                     // 1.8 s: not yet
        for k in 10..<20 { state = c.update(picture(5, noise: 0.001), at: Double(k) * 0.2) }
        #expect(state == .still)                       // 3.8 s unchanged
        state = c.update(picture(9), at: 4.0)
        #expect(state == .picture)                     // moves again
    }

    @Test func smallMovementInStaticShotIsNotStill() {
        var c = PictureChecker()
        var state = PictureState.picture
        for k in 0..<30 {
            var values = picture(5).values
            let spot = (k * 3) % (32 * 18)          // a small performer moving across a static wide
            values[spot] = 1; values[(spot + 1) % values.count] = 1
            state = c.update(LumaGrid(width: 32, height: 18, values: values), at: Double(k) * 0.2)
        }
        #expect(state == .picture)
    }

    @Test func feedLostWhenFramesStop() {
        var c = PictureChecker()
        c.update(picture(0), at: 0)
        #expect(c.state(at: 1.0) == .picture)
        #expect(c.state(at: 2.5) == .noFeed)
        #expect(PictureChecker().state(at: 0) == .noFeed)
    }

    @Test func quadrants() {
        #expect(ConfidenceLayout.rect(quadrant: 0) == (0, 0, 0.5, 0.5))
        #expect(ConfidenceLayout.rect(quadrant: 1) == (0.5, 0, 0.5, 0.5))
        #expect(ConfidenceLayout.rect(quadrant: 3) == (0.5, 0.5, 0.5, 0.5))
        #expect(ConfidenceLayout.rect(quadrant: 9) == (0.5, 0.5, 0.5, 0.5))
    }
}
