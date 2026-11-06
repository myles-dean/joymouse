import AppKit
import CoreGraphics

// Posts synthetic mouse / keyboard events. Needs Accessibility permission.
final class Output {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var held: [CGMouseButton: Int] = [:]       // press counts, so two buttons can share one mouse button
    private var lastClick: [CGMouseButton: (time: TimeInterval, pos: CGPoint, count: Int)] = [:]
    private var cmdHeldForSwitcher = 0

    var anyHeld: Bool { held.values.contains { $0 > 0 } }

    // MARK: pointer

    private var virtualPos: CGPoint?
    private var deltaCarry = (x: 0.0, y: 0.0)

    // Moves by fractional amounts: the position we post keeps its sub-pixel part
    // (the window server accepts fractional cursor positions, like a trackpad).
    func move(dx: Double, dy: Double) {
        guard dx != 0 || dy != 0 else { return }
        let cur = CGEvent(source: nil)?.location ?? .zero
        // Our own position, unless something else (a real mouse) moved the cursor.
        let base = virtualPos.map { hypot($0.x - cur.x, $0.y - cur.y) < 1.5 ? $0 : cur } ?? cur
        let next = clamp(CGPoint(x: base.x + dx, y: base.y + dy))
        virtualPos = next
        let (type, button): (CGEventType, CGMouseButton) =
            (held[.left] ?? 0) > 0 ? (.leftMouseDragged, .left) :
            (held[.right] ?? 0) > 0 ? (.rightMouseDragged, .right) :
            (held[.center] ?? 0) > 0 ? (.otherMouseDragged, .center) : (.mouseMoved, .left)
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: next, mouseButton: button) else { return }
        // Integer deltas for apps that read them (games); carry the remainder.
        deltaCarry.x += dx; deltaCarry.y += dy
        let ix = deltaCarry.x.rounded(.towardZero), iy = deltaCarry.y.rounded(.towardZero)
        deltaCarry.x -= ix; deltaCarry.y -= iy
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(ix))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(iy))
        e.post(tap: .cghidEventTap)
    }

    func scroll(dx: Double, dy: Double) {
        let x = Int32(dx.rounded()), y = Int32(dy.rounded())
        guard x != 0 || y != 0 else { return }
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let rects = ids.map { CGDisplayBounds($0) }
        if rects.contains(where: { $0.contains(p) }) { return p }
        // Off every screen: pull it onto the nearest one.
        var best = p, bestDist = Double.infinity
        for r in rects {
            let q = CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < bestDist { best = q; bestDist = d }
        }
        return best
    }

    // MARK: buttons

    func mouse(_ button: CGMouseButton, down: Bool) {
        let n = held[button] ?? 0
        if down {
            held[button] = n + 1
            guard n == 0 else { return }
        } else {
            guard n > 0 else { return }
            held[button] = n - 1
            guard n == 1 else { return }
        }
        let pos = CGEvent(source: nil)?.location ?? .zero
        let type: CGEventType
        switch button {
        case .left: type = down ? .leftMouseDown : .leftMouseUp
        case .right: type = down ? .rightMouseDown : .rightMouseUp
        default: type = down ? .otherMouseDown : .otherMouseUp
        }
        var count = 1
        let now = ProcessInfo.processInfo.systemUptime
        if down {
            if let last = lastClick[button], now - last.time < NSEvent.doubleClickInterval,
               hypot(last.pos.x - pos.x, last.pos.y - pos.y) < 6 {
                count = last.count + 1
            }
            lastClick[button] = (now, pos, count)
        } else {
            count = lastClick[button]?.count ?? 1
        }
        post(type, button, pos, count)
    }

    func doubleClick() {
        let pos = CGEvent(source: nil)?.location ?? .zero
        for n in 1...2 {
            post(.leftMouseDown, .left, pos, n)
            post(.leftMouseUp, .left, pos, n)
        }
    }

    private func post(_ type: CGEventType, _ button: CGMouseButton, _ pos: CGPoint, _ clicks: Int) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pos, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        e.post(tap: .cghidEventTap)
    }

    func releaseAll() {
        for (b, n) in held where n > 0 {
            held[b] = 1
            mouse(b, down: false)
        }
        while cmdHeldForSwitcher > 0 { appSwitcher(down: false) }
    }

    // MARK: keys

    func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    func tap(_ code: CGKeyCode, flags: CGEventFlags = []) {
        key(code, down: true, flags: flags)
        key(code, down: false, flags: flags)
    }

    // ⌘ stays down while the button is held: press shows the switcher, release picks the app.
    func appSwitcher(down: Bool) {
        if down {
            if cmdHeldForSwitcher == 0 { key(55, down: true, flags: .maskCommand) }
            cmdHeldForSwitcher += 1
            tap(48, flags: .maskCommand)
        } else if cmdHeldForSwitcher > 0 {
            cmdHeldForSwitcher -= 1
            if cmdHeldForSwitcher == 0 { key(55, down: false) }
        }
    }
}
