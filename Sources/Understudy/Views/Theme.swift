import AppKit
import SwiftUI

/// Shdwbx house format, inverted for a dark control room: #F4F5F5 on black,
/// Space Mono for data, Neue Haas Grotesk Display for headings (system fallbacks if not installed).
enum Theme {
    static let paper = Color(red: 244.0 / 255, green: 245.0 / 255, blue: 245.0 / 255)
    static let background = Color.black
    static let panel = Color(white: 0.06)
    static let rule = Color(white: 0.24)
    static let dim = Color(white: 0.52)
    static let record = Color(red: 0.94, green: 0.20, blue: 0.17)
    static let live = Color(red: 0.22, green: 0.84, blue: 0.47)
    static let caution = Color(red: 1.0, green: 0.72, blue: 0.22)

    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        let name = bold ? "SpaceMono-Bold" : "SpaceMono-Regular"
        if NSFont(name: name, size: size) != nil { return .custom(name, size: size) }
        return .system(size: size, weight: bold ? .bold : .regular, design: .monospaced)
    }

    static func display(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        let family = "Neue Haas Grotesk Display Pro"
        if NSFontManager.shared.availableMembers(ofFontFamily: family) != nil {
            return .custom(family, size: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }
}

struct Rule: View {
    var body: some View {
        Rectangle().fill(Theme.rule).frame(height: 1)
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text.uppercased())
                .font(Theme.mono(11, bold: true))
                .tracking(1.5)
                .foregroundStyle(Theme.dim)
            Rule()
        }
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}
