import CoreGraphics
import CoreText
import CoreVideo
import Foundation

/// What an NDI feed sends when it has no video: colour bars, the feed's name, why there's no
/// picture, and a running time-of-day clock, so a receiver can see the source is there and live.
/// Drawn at the size the feed last sent (1920×1080 until then), so receivers don't renegotiate.
final class NDITestPattern {
    /// The layout is designed at 1920×1080 and scaled to the frame.
    static let designWidth = 1920.0, designHeight = 1080.0

    let title: String
    let note: String
    let width: Int, height: Int
    private let base: CGImage?
    private var pool: CVPixelBufferPool?

    init(title: String, note: String, width: Int = 1920, height: Int = 1080) {
        self.title = title
        self.note = note
        self.width = max(16, width)
        self.height = max(16, height)
        base = Self.drawBase(title: title, note: note, width: self.width, height: self.height)
    }

    /// One frame: the bars and words, plus the time of day.
    func frame(at date: Date = Date()) -> CVPixelBuffer? {
        guard let base, let buffer = makeBuffer() else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = Self.context(on: buffer) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        Self.scale(ctx, width: width, height: height)
        let w = CGFloat(Self.designWidth)
        let clock = Self.clockFormatter.string(from: date)
        Self.draw(clock, in: ctx, font: Self.font("Menlo-Regular", 72), color: Self.paper,
                  at: CGPoint(x: w - 96, y: 190), alignRight: true)
        // Labelled, so nobody reads it as timecode.
        Self.draw("TIME OF DAY", in: ctx, font: Self.font("HelveticaNeue-Medium", 22), color: Self.grey,
                  at: CGPoint(x: w - 96, y: 278), alignRight: true)
        // A block that steps across under the clock every second: plainly moving.
        let second = Calendar.current.component(.second, from: date)
        let step = (w - 192) / 60
        ctx.setFillColor(Self.paper)
        ctx.fill(CGRect(x: 96 + CGFloat(second) * step, y: 48, width: step - 4, height: 10))
        return buffer
    }

    private func makeBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                        kCVPixelBufferWidthKey as String: width,
                                        kCVPixelBufferHeightKey as String: height,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    // MARK: Drawing

    private static let paper = CGColor(srgbRed: 0.957, green: 0.961, blue: 0.961, alpha: 1)   // #F4F5F5
    private static let grey = CGColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1)

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func context(on buffer: CVPixelBuffer) -> CGContext? {
        CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer),
                  height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// 75% bars over the top two thirds, a reverse strip, then a black band with the words.
    /// Maps the 1920×1080 design onto a `width`×`height` frame (stretched to fill, like the bars
    /// a receiver expects at that size).
    private static func scale(_ ctx: CGContext, width: Int, height: Int) {
        ctx.scaleBy(x: CGFloat(width) / designWidth, y: CGFloat(height) / designHeight)
    }

    private static func drawBase(title: String, note: String, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        scale(ctx, width: width, height: height)
        let w = CGFloat(designWidth), h = CGFloat(designHeight)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let v = 0.75
        let bars: [(Double, Double, Double)] = [(v, v, v), (v, v, 0), (0, v, v), (0, v, 0), (v, 0, v), (v, 0, 0), (0, 0, v)]
        let reverse: [(Double, Double, Double)] = [(0, 0, v), (0, 0, 0), (v, 0, v), (0, 0, 0), (0, v, v), (0, 0, 0), (v, v, v)]
        let barW = w / 7
        let barTop = h, barBottom = h * 0.36, stripBottom = h * 0.30
        for (i, c) in bars.enumerated() {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(i) * barW, y: barBottom, width: barW + 1, height: barTop - barBottom))
        }
        for (i, c) in reverse.enumerated() {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(i) * barW, y: stripBottom, width: barW + 1, height: barBottom - stripBottom))
        }
        draw(title.uppercased(), in: ctx, font: font("HelveticaNeue-Medium", 72), color: paper,
             at: CGPoint(x: 96, y: 190), alignRight: false)
        draw(note, in: ctx, font: font("HelveticaNeue-Light", 40), color: grey,
             at: CGPoint(x: 96, y: 120), alignRight: false)
        return ctx.makeImage()
    }

    private static func font(_ name: String, _ size: CGFloat) -> CTFont {
        CTFontCreateWithName(name as CFString, size, nil)
    }

    private static func draw(_ text: String, in ctx: CGContext, font: CTFont, color: CGColor, at point: CGPoint, alignRight: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: alignRight ? point.x - width : point.x, y: point.y)
        CTLineDraw(line, ctx)
    }
}
