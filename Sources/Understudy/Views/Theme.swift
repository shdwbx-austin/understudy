import AppKit
import SwiftUI

/// Shdwbx house style for a dark control room.
///
/// Swiss grid: flush left, hairline rules instead of boxes, one type family for words and
/// numerals (Neue Haas Grotesk Display) and Space Mono for data. Colour is black, off-white
/// (#F4F5F5) and signal red; amber only for warnings. Falls back to Helvetica Neue and the
/// system monospace when the brand fonts aren't installed.
enum Theme {
    // MARK: Colour
    static let ink = Color.black
    static let paper = Color(red: 244 / 255, green: 245 / 255, blue: 245 / 255)
    static let grey = Color(white: 0.56)
    static let quiet = Color(white: 0.36)
    static let rule = Color(white: 0.20)
    static let fill = Color(white: 0.07)
    static let signal = Color(red: 0.89, green: 0.12, blue: 0.10)   // record, alarm
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.16)     // warnings only

    // Old names, still used by a few views.
    static var background: Color { ink }
    static var dim: Color { grey }
    static var record: Color { signal }
    static var caution: Color { amber }
    static var live: Color { paper }
    static var panel: Color { fill }

    // MARK: Grid
    static let marginLeading: CGFloat = 48
    static let marginTrailing: CGFloat = 32
    static let gutter: CGFloat = 24
    static let unit: CGFloat = 8

    // MARK: Type
    enum Weight: String {
        case thin = "25Th", light = "45Lt", regular = "55Rg", medium = "65Md", bold = "75Bd"

        var system: Font.Weight {
            switch self {
            case .thin: return .thin
            case .light: return .light
            case .regular: return .regular
            case .medium: return .medium
            case .bold: return .bold
            }
        }
    }

    private static let hasHaas = NSFont(name: "NHaasGroteskDSPro-55Rg", size: 12) != nil
    /// The Text cut is drawn for small sizes; the Display cut crowds below ~17 pt.
    private static let hasHaasText = NSFont(name: "NHaasGroteskTXPro-55Rg", size: 12) != nil
    private static let hasSpaceMono = NSFont(name: "SpaceMono-Regular", size: 12) != nil

    /// Neue Haas Grotesk Display, with tabular figures so numbers don't jitter.
    static func grotesk(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        if hasHaasText, size < 17, weight == .regular || weight == .light {
            return .custom("NHaasGroteskTXPro-55Rg", size: size).monospacedDigit()
        }
        if hasHaas { return .custom("NHaasGroteskDSPro-\(weight.rawValue)", size: size).monospacedDigit() }
        if NSFont(name: "HelveticaNeue", size: size) != nil {
            return .custom(helvetica(weight), size: size).monospacedDigit()
        }
        return .system(size: size, weight: weight.system).monospacedDigit()
    }

    private static func helvetica(_ weight: Weight) -> String {
        switch weight {
        case .thin: return "HelveticaNeue-Thin"
        case .light: return "HelveticaNeue-Light"
        case .regular: return "HelveticaNeue"
        case .medium: return "HelveticaNeue-Medium"
        case .bold: return "HelveticaNeue-Bold"
        }
    }

    /// Space Mono for data: addresses, formats, readouts.
    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        if hasSpaceMono { return .custom(bold ? "SpaceMono-Bold" : "SpaceMono-Regular", size: size) }
        return .system(size: size, weight: bold ? .bold : .regular, design: .monospaced)
    }

    /// Back-compat for views that asked for the display face.
    static func display(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        let w: Weight
        switch weight {
        case .thin, .ultraLight: w = .thin
        case .light: w = .light
        case .medium, .semibold: w = .medium
        case .bold, .heavy, .black: w = .bold
        default: w = .regular
        }
        return grotesk(size, w)
    }
}

// MARK: - Building blocks

/// A full-width hairline.
struct Rule: View {
    var color: Color = Theme.rule
    var body: some View {
        Rectangle().fill(color).frame(height: 1)
    }
}

/// A vertical hairline.
struct VRule: View {
    var body: some View {
        Rectangle().fill(Theme.rule).frame(width: 1)
    }
}

/// Numbered section head: "03  DECKS ———————— trailing".
struct SectionHead<Trailing: View>: View {
    let index: Int
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(String(format: "%02d", index))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.quiet)
                    .frame(width: 32, alignment: .leading)
                Text(title.uppercased())
                    .font(Theme.mono(10, bold: true))
                    .tracking(1.6)
                    .foregroundStyle(Theme.grey)
                Spacer(minLength: Theme.gutter)
                trailing
            }
            Rule()
        }
    }
}

extension SectionHead where Trailing == EmptyView {
    init(index: Int, title: String) {
        self.init(index: index, title: title) { EmptyView() }
    }
}

/// Back-compat: un-numbered section title.
struct SectionTitle: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text.uppercased())
                .font(Theme.mono(10, bold: true))
                .tracking(1.6)
                .foregroundStyle(Theme.grey)
            Rule()
        }
    }
}

/// Small uppercase label above or beside a value.
struct Label8: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.mono(9))
            .tracking(1.2)
            .foregroundStyle(Theme.quiet)
    }
}

/// Status dot: filled when `on`, hollow ring when off.
struct StatusDot: View {
    let color: Color
    var filled = true
    var body: some View {
        Circle()
            .fill(filled ? color : .clear)
            .overlay(Circle().stroke(color, lineWidth: 1))
            .frame(width: 7, height: 7)
    }
}

/// Text-only button in the house style: uppercase mono, underlined on hover.
struct TextButton: View {
    let title: String
    var color: Color = Theme.paper
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(Theme.mono(10, bold: true))
                .tracking(1.2)
                .foregroundStyle(color)
                .underline(hover)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Horizontal peak meter, −60…0 dBFS: off-white, amber above −12, red above −3.
struct LevelMeter: View {
    let db: Float

    var body: some View {
        GeometryReader { geo in
            let fraction = CGFloat(max(0, min(1, (db + 60) / 60)))
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.rule)
                Rectangle().fill(color).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityLabel(Text(LevelMeter.label(db)))
    }

    private var color: Color {
        if db > -3 { return Theme.signal }
        if db > -12 { return Theme.amber }
        return Theme.paper
    }

    static func label(_ db: Float) -> String {
        db <= -59.5 ? "−∞ dB" : String(format: "%.0f dB", db)
    }
}
