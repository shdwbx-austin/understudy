import AppKit
import SwiftUI
import UnderstudyCore

/// The current waveform: analysed by `AudioAnalyzer`, drawn by `WaveformView`.
enum Render {
    static let label = "after"

    static func analyze(path: String, root: URL) -> WaveformPeaks? {
        AudioAnalyzer.analyze(path: path, rate: .fps30, root: root)?.waveform
    }

    static func sameDrawing(_ a: WaveformPeaks?, _ b: WaveformPeaks) -> Bool {
        a?.levels == b.levels && a?.frameCount == b.frameCount
    }

    /// `from`…`to` seconds of the song across `width` points, at 2× like a Retina screen.
    @MainActor static func png(_ peaks: WaveformPeaks, from: Double, to: Double, width: CGFloat, height: CGFloat, to url: URL) -> Bool {
        let view = WaveformView(peaks: peaks, from: from, to: to, color: Color.white.opacity(0.7))
            .frame(width: width, height: height)
            .background(Color(white: 0.08))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// Outlines for the overview (30 songs across 1500 points) and the workspace at every zoom,
    /// as the views build them each redraw.
    static func timeShow(_ peaks: WaveformPeaks) -> String {
        func time(_ runs: Int, _ body: () -> Void) -> Double {
            let t = Date()
            for _ in 0..<runs { body() }
            return Date().timeIntervalSince(t) / Double(runs) * 1000
        }
        let overview = time(20) {
            for _ in 0..<30 { _ = WaveformView.shape(peaks, from: 0, to: 240, size: CGSize(width: 50, height: 40), scale: 2) }
        }
        var lines = [String(format: "  overview, 30 songs: %.2f ms a redraw", overview)]
        for zoom in [1.0, 4, 32] {
            let span = 240 / zoom
            let ms = time(20) { _ = WaveformView.shape(peaks, from: 100, to: 100 + span, size: CGSize(width: 1500, height: 180), scale: 2) }
            lines.append(String(format: "  workspace %2.0f×: %.2f ms a redraw", zoom, ms))
        }
        return lines.joined(separator: "\n")
    }
}
