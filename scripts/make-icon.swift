// Draws Understudy's app icon and writes Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift            # writes the .icns (needs Neue Haas Grotesk Display installed)
//   swift scripts/make-icon.swift preview    # also leaves the 1024 px PNG in dist/
//
// A black tile on Apple's icon grid (824 px body on a 1024 canvas) with a hairline edge,
// a lowercase u in Neue Haas Grotesk Display, and the green the show clock turns on lock.
import AppKit
import CoreText

let canvas: CGFloat = 1024
let body: CGFloat = 824
let inset = (canvas - body) / 2
let radius: CGFloat = 185.4

let ink = NSColor.black
let paper = NSColor(red: 244 / 255, green: 245 / 255, blue: 245 / 255, alpha: 1)
let lock = NSColor(red: 0.24, green: 0.86, blue: 0.52, alpha: 1)

func render(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    let scale = CGFloat(size) / canvas
    cg.scaleBy(x: scale, y: scale)

    let tile = CGRect(x: inset, y: inset, width: body, height: body)
    let shape = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Tile with Apple's soft drop shadow.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    cg.addPath(shape)
    cg.setFillColor(ink.cgColor)
    cg.fillPath()
    cg.restoreGState()

    // Hairline edge, so the black tile holds its shape on a dark Dock.
    cg.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: radius - 2, cornerHeight: radius - 2, transform: nil))
    cg.setStrokeColor(paper.withAlphaComponent(0.22).cgColor)
    cg.setLineWidth(4)
    cg.strokePath()

    cg.saveGState()
    cg.addPath(shape)
    cg.clip()

    // The u: set big on the grid's left margin and baseline, like the wordmark.
    let margin: CGFloat = 112
    let font = CTFontCreateWithName("NHaasGroteskDSPro-65Md" as CFString, 700, nil)
    precondition((CTFontCopyPostScriptName(font) as String) == "NHaasGroteskDSPro-65Md",
                 "Neue Haas Grotesk Display 65 Medium isn't installed")
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "u", attributes: [
        .font: font, .foregroundColor: paper,
    ]))
    let glyph = CTLineGetImageBounds(line, cg)
    cg.textPosition = CGPoint(x: tile.minX + margin - glyph.minX, y: tile.minY + margin - glyph.minY)
    CTLineDraw(line, cg)

    // The lock dot: top right, on the same margins.
    let dot: CGFloat = 112
    cg.setFillColor(lock.cgColor)
    cg.fillEllipse(in: CGRect(x: tile.maxX - margin - dot, y: tile.maxY - margin - dot, width: dot, height: dot))
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = render(size: points * factor).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}

if CommandLine.arguments.contains("preview") {
    try FileManager.default.createDirectory(at: root.appendingPathComponent("dist"), withIntermediateDirectories: true)
    try render(size: 1024).representation(using: .png, properties: [:])!
        .write(to: root.appendingPathComponent("dist/AppIcon-1024.png"))
}

let out = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(out.path)")
