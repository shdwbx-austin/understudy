import SwiftUI
import UnderstudyCore

/// Part of a song's waveform: `from`…`to` seconds of its audio across the view's width, drawn as
/// one low/high pair per screen pixel (not per point), outlined as a single filled shape so it
/// reads as a smooth envelope at every zoom.
struct WaveformView: View, Equatable {
    let peaks: WaveformPeaks
    let from: Double
    let to: Double
    let color: Color

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.peaks === b.peaks && a.from == b.from && a.to == b.to && a.color == b.color
    }

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0, to > from else { return }
            context.fill(Self.shape(peaks, from: from, to: to, size: size, scale: context.environment.displayScale),
                         with: .color(color))
        }
        .allowsHitTesting(false)
    }

    /// The waveform's outline: along the highs left to right, back along the lows. Never thinner
    /// than a pixel, so silence still shows as a line.
    nonisolated static func shape(_ peaks: WaveformPeaks, from: Double, to: Double, size: CGSize, scale: CGFloat) -> Path {
        let scale = max(1, scale)
        let count = min(16_384, max(1, Int((size.width * scale).rounded(.up))))
        let columns = peaks.columns(from: from, to: to, count: count)
        let mid = size.height / 2
        let step = size.width / CGFloat(count)
        let half = 0.5 / scale
        var tops = [CGFloat](repeating: 0, count: count), bottoms = tops
        for i in 0..<count {
            var top = mid - CGFloat(columns.highs[i]) * mid
            var bottom = mid - CGFloat(columns.lows[i]) * mid
            if bottom - top < 2 * half {
                let centre = (top + bottom) / 2
                top = centre - half
                bottom = centre + half
            }
            tops[i] = top
            bottoms[i] = bottom
        }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: tops[0]))
        for i in 0..<count { path.addLine(to: CGPoint(x: (CGFloat(i) + 0.5) * step, y: tops[i])) }
        path.addLine(to: CGPoint(x: size.width, y: tops[count - 1]))
        path.addLine(to: CGPoint(x: size.width, y: bottoms[count - 1]))
        for i in stride(from: count - 1, through: 0, by: -1) { path.addLine(to: CGPoint(x: (CGFloat(i) + 0.5) * step, y: bottoms[i])) }
        path.addLine(to: CGPoint(x: 0, y: bottoms[0]))
        path.closeSubpath()
        return path
    }
}
