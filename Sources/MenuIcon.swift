import AppKit

// The menu bar pointer, from the SVG artwork (viewBox 504 x 612, stroke 58.2222).
// Template images, so macOS tints them for light/dark menu bars.
enum MenuIcon {
    static let empty = make(filled: false)
    static let filled = make(filled: true)

    private static func pointer() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 29.1094, y: 71.8034))
        p.line(to: NSPoint(x: 29.1094, y: 539.687))
        p.curve(to: NSPoint(x: 98.2353, y: 572.91), controlPoint1: NSPoint(x: 29.1094, y: 575.362), controlPoint2: NSPoint(x: 70.3771, y: 595.197))
        p.line(to: NSPoint(x: 235.789, y: 462.868))
        p.curve(to: NSPoint(x: 262.367, y: 453.544), controlPoint1: NSPoint(x: 243.333, y: 456.832), controlPoint2: NSPoint(x: 252.706, y: 453.544))
        p.line(to: NSPoint(x: 431.408, y: 453.544))
        p.curve(to: NSPoint(x: 460.595, y: 380.04), controlPoint1: NSPoint(x: 469.919, y: 453.544), controlPoint2: NSPoint(x: 488.616, y: 406.46))
        p.line(to: NSPoint(x: 100.844, y: 40.8466))
        p.curve(to: NSPoint(x: 29.1094, y: 71.8034), controlPoint1: NSPoint(x: 73.7013, y: 15.2548), controlPoint2: NSPoint(x: 29.1094, y: 34.4983))
        p.close()
        p.lineWidth = 58.2222
        p.lineJoinStyle = .round
        return p
    }

    private static func make(filled: Bool) -> NSImage {
        let height: CGFloat = 16
        let size = NSSize(width: height * 504 / 612, height: height)
        let img = NSImage(size: size, flipped: true) { rect in   // flipped: SVG's y points down
            let t = NSAffineTransform()
            t.scaleX(by: rect.width / 504, yBy: rect.height / 612)
            let path = t.transform(pointer())
            path.lineWidth = 58.2222 * rect.height / 612
            if filled {
                NSColor.black.withAlphaComponent(0.65).setFill()
                path.fill()
            }
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "JoyMouse"
        return img
    }
}
