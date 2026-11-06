// Draws the DMG window background: the social-preview gradient, an arrow from
// the app to Applications, and a hint line. Writes 1x and 2x PNGs.
//   swiftc Tools/dmg-background.swift -o build/dmg-bg && build/dmg-bg build && cp build/dmg-bg.png Resources/dmg-background.png
// Only the 1x image is used: Finder on macOS 26 ignores a Retina TIFF's DPI and
// draws the 2x image at double size.
import AppKit

let size = NSSize(width: 640, height: 400)          // DMG window content size, in points
let appX: CGFloat = 170, appsX: CGFloat = 470, iconY: CGFloat = 185   // icon centres (top-left origin)

func draw(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    // A flipped context (y runs down, like Finder's icon positions) so text still draws upright.
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: size.height * scale)
    cg.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

    // Diagonal gradient: cyan top-left → violet bottom-right (sampled from the social preview).
    let gradient = NSGradient(colors: [NSColor(srgbRed: 0x89 / 255.0, green: 0xE7 / 255.0, blue: 0xED / 255.0, alpha: 1),
                                       NSColor(srgbRed: 0x9E / 255.0, green: 0x95 / 255.0, blue: 0xFB / 255.0, alpha: 1)])!
    gradient.draw(in: NSRect(origin: .zero, size: size), angle: atan2(size.height, size.width) * 180 / .pi)

    // Arrow between the two icons.
    let arrow = NSBezierPath()
    let x0 = appX + 82, x1 = appsX - 82, y = iconY
    arrow.move(to: NSPoint(x: x0, y: y)); arrow.line(to: NSPoint(x: x1, y: y))
    arrow.move(to: NSPoint(x: x1 - 14, y: y - 14)); arrow.line(to: NSPoint(x: x1, y: y)); arrow.line(to: NSPoint(x: x1 - 14, y: y + 14))
    arrow.lineWidth = 5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.85).setStroke()
    arrow.stroke()

    // Hint under the icon labels.
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let text = NSAttributedString(string: "Drag JoyMouse into Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        .paragraphStyle: style,
    ])
    text.draw(in: NSRect(x: 0, y: 318, width: size.width, height: 24))

    NSGraphicsContext.restoreGraphicsState()
    // Tag the pixels as sRGB so Finder shows the sampled colours exactly.
    let tagged = rep.retagging(with: .sRGB) ?? rep
    try! tagged.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
draw(scale: 1, to: "\(dir)/dmg-bg.png")
draw(scale: 2, to: "\(dir)/dmg-bg@2x.png")
