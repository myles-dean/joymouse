import AppKit
import ApplicationServices
import QuartzCore
import ServiceManagement

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, JoyConDelegate {
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private let manager = JoyConManager()
    private let out = Output()
    private var settings = Settings.load()

    private var precisionHeld = 0
    private var freezeHeld = 0
    private var opticalLast: [UUID: (UInt16, UInt16)] = [:]
    private var carry = (sx: 0.0, sy: 0.0)

    // Smoothing: reports arrive every ~8-15 ms; the pointer is moved on every
    // display frame instead, spreading each report's motion until the next one
    // is due (about one report of added latency, no visible steps).
    private var pending = (x: 0.0, y: 0.0)
    private var reportInterval = 1.0 / 90
    private var lastReportAt: CFTimeInterval = 0
    private var link: CADisplayLink?
    private var activity: NSObjectProtocol?
    private var blinkTimer: Timer?
    private var menuOpen = false
    private var menuState = ""

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        item.menu = menu
        updateIcon()

        manager.delegate = self
        manager.known = { [unowned self] in settings.known }
        manager.remember = { [unowned self] id, side in
            if settings.known[id.uuidString] != side { settings.known[id.uuidString] = side; settings.save() }
        }
        manager.idleMinutes = { [unowned self] in settings.sleepAfter }
        manager.lowLatency = { [unowned self] in settings.batterySaver != true }
        manager.enabled = true

        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.out.releaseAll()
            self?.manager.disconnectAll()
        }
    }

    // MARK: input

    func joyConChanged() {
        for d in manager.devices.values where d.ready { manager.remember(d.peripheral.identifier, d.side) }
        if manager.devices.isEmpty { out.releaseAll(); precisionHeld = 0; freezeHeld = 0; pending = (0, 0) }
        // Keep macOS from napping/throttling this windowless app while a Joy-Con is in use.
        if manager.devices.isEmpty, let a = activity {
            ProcessInfo.processInfo.endActivity(a); activity = nil; link?.isPaused = true
        } else if !manager.devices.isEmpty, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Joy-Con pointer")
        }
        updateIcon()
        refreshOpenMenu()
    }

    func joyCon(_ jc: JoyCon, report r: Report, dt: Double) {
        let id = jc.peripheral.identifier
        let prev = jc.lastReport?.buttons ?? 0
        guard settings.outputEnabled else { opticalLast[id] = nil; return }

        // Buttons
        let changed = prev ^ r.buttons
        if changed != 0 {
            for b in Button.on(jc.side) where (changed >> b.bit) & 1 != 0 {
                perform(settings.mapping[b] ?? .none, down: (r.buttons >> b.bit) & 1 != 0)
            }
        }

        let speed = settings.pointerSpeed * (precisionHeld > 0 ? 0.3 : 1)
        var dx = 0.0, dy = 0.0

        // Optical sensor: absolute 16-bit counters, so take the wrapping difference.
        if settings.opticalEnabled {
            if let (lx, ly) = opticalLast[id] {
                var mx = Double(Int16(bitPattern: r.mouseX &- lx))
                var my = Double(Int16(bitPattern: r.mouseY &- ly))
                if abs(mx) > 3000 || abs(my) > 3000 { mx = 0; my = 0 }   // resync glitch, not motion
                if settings.swapXY { swap(&mx, &my) }
                if settings.invertX { mx = -mx }
                if settings.invertY { my = -my }
                dx += mx * speed
                dy += my * speed
            }
            opticalLast[id] = (r.mouseX, r.mouseY)
        }

        // Stick
        if settings.stickMode != .off, dt > 0 {
            let (sx, sy) = stick(jc, r)
            let mag = hypot(sx, sy)
            if mag > 0.18 {
                let k = pow((mag - 0.18) / 0.82, 2) / mag
                if settings.stickMode == .pointer {
                    dx += sx * k * 1400 * speed * dt
                    dy -= sy * k * 1400 * speed * dt
                } else {
                    carry.sx += sx * k * 1600 * dt
                    carry.sy += sy * k * 1600 * dt
                }
            }
        }

        let now = CACurrentMediaTime()
        if dt > 0 { reportInterval += (min(0.05, dt) - reportInterval) * 0.1 }
        lastReportAt = now
        if freezeHeld == 0, dx != 0 || dy != 0 {
            if settings.smoothingOff == true {
                out.move(dx: dx, dy: dy)
            } else {
                pending.x += dx; pending.y += dy
                startLink()
            }
        }
        let isx = carry.sx.rounded(.towardZero), isy = carry.sy.rounded(.towardZero)
        carry.sx -= isx; carry.sy -= isy
        out.scroll(dx: -isx, dy: isy)
    }

    private func startLink() {
        if link == nil {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            link = screen?.displayLink(target: self, selector: #selector(frame(_:)))
            link?.add(to: .main, forMode: .common)
        }
        link?.isPaused = false
    }

    @objc private func frame(_ l: CADisplayLink) {
        let frameDt = max(0.002, l.targetTimestamp - l.timestamp)
        let remaining = reportInterval - (CACurrentMediaTime() - lastReportAt)
        let f = remaining <= frameDt ? 1 : frameDt / remaining
        let mx = pending.x * f, my = pending.y * f
        pending.x -= mx; pending.y -= my
        if freezeHeld == 0 { out.move(dx: mx, dy: my) }
        if abs(pending.x) < 0.01, abs(pending.y) < 0.01, CACurrentMediaTime() - lastReportAt > 0.25 {
            pending = (0, 0)
            l.isPaused = true   // idle: no frame callbacks until the next motion
        }
    }

    private func stick(_ jc: JoyCon, _ r: Report) -> (Double, Double) {
        let (x, y) = r.stickRaw
        if let c = jc.calibration {
            return (c.axis(x, c.nX, c.maxX, c.minX), c.axis(y, c.nY, c.maxY, c.minY))
        }
        return (max(-1, min(1, Double(x - 2048) / 1500)), max(-1, min(1, Double(y - 2048) / 1500)))
    }

    private func perform(_ a: Action, down: Bool) {
        switch a {
        case .none: break
        case .leftClick: out.mouse(.left, down: down)
        case .rightClick: out.mouse(.right, down: down)
        case .middleClick: out.mouse(.center, down: down)
        case .doubleClick: if down { out.doubleClick() }
        case .back: if down { out.tap(33, flags: .maskCommand) }
        case .forward: if down { out.tap(30, flags: .maskCommand) }
        case .scrollUp: if down { out.scroll(dx: 0, dy: 60) }
        case .scrollDown: if down { out.scroll(dx: 0, dy: -60) }
        case .precision: precisionHeld = max(0, precisionHeld + (down ? 1 : -1))
        case .pausePointer: freezeHeld = max(0, freezeHeld + (down ? 1 : -1))
        case .missionControl: if down { out.tap(126, flags: .maskControl) }
        case .appSwitcher: out.appSwitcher(down: down)
        case .escape: out.key(53, down: down)
        case .returnKey: out.key(36, down: down)
        case .space: out.key(49, down: down)
        case .tab: out.key(48, down: down)
        case .delete: out.key(51, down: down)
        case .upArrow: out.key(126, down: down)
        case .downArrow: out.key(125, down: down)
        case .leftArrow: out.key(123, down: down)
        case .rightArrow: out.key(124, down: down)
        }
    }

    // MARK: menu

    // Menu bar icon: outline = nothing connected, filled = a Joy-Con is connected,
    // alternating between the two = syncing.
    private func updateIcon() {
        let connected = manager.devices.values.contains { $0.ready }
        if manager.syncing {
            if blinkTimer == nil {
                var on = !connected
                item.button?.image = on ? MenuIcon.filled : MenuIcon.empty
                blinkTimer = Timer.common(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    on.toggle()
                    self?.item.button?.image = on ? MenuIcon.filled : MenuIcon.empty
                }
            }
        } else {
            blinkTimer?.invalidate(); blinkTimer = nil
            item.button?.image = connected ? MenuIcon.filled : MenuIcon.empty
        }
    }

    func menuWillOpen(_ m: NSMenu) { menuOpen = true }
    func menuDidClose(_ m: NSMenu) { menuOpen = false }

    // What the menu shows that can change on its own: rebuild an open menu only when this
    // changes, so a submenu you're browsing isn't closed by unrelated updates.
    private var currentMenuState: String {
        let devices = manager.devices.values.map { "\($0.peripheral.identifier)\($0.ready)\($0.side)\($0.batteryPercent ?? -1)\($0.charging)\($0.colors ?? [])" }.sorted()
        return "\(manager.bluetoothState.rawValue)|\(manager.syncing)|\(AXIsProcessTrusted())|\(devices)"
    }

    private func refreshOpenMenu() {
        guard menuOpen, currentMenuState != menuState else { return }
        menuNeedsUpdate(menu)
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        menuState = currentMenuState
        m.removeAllItems()
        handlers.removeAll()   // the old items are gone; their closures go with them

        // Status
        let ready = manager.devices.values.filter { $0.ready }.sorted { $0.side.rawValue > $1.side.rawValue }
        if manager.bluetoothState == .poweredOff {
            m.addItem(disabled("Bluetooth is off"))
        } else if manager.bluetoothState == .unauthorized {
            m.addItem(action("Allow Bluetooth in System Settings…") { Self.openSettings("Privacy_Bluetooth") })
        } else if ready.isEmpty {
            m.addItem(disabled(manager.devices.isEmpty ? "No Joy-Con connected" : "Connecting…"))
        }
        for d in ready {
            let battery = (d.batteryPercent.map { " · Battery \($0)%" } ?? " · Battery …") + (d.charging ? " ⚡︎" : "")
            // Enabled so the colour isn't dimmed; clicking buzzes that Joy-Con.
            let row = action("\(d.name)\(battery)") { d.buzz() }
            row.image = Self.dot(d.accentColor ?? .secondaryLabelColor)
            row.toolTip = "Click to buzz this Joy-Con"
            m.addItem(row)
        }

        if manager.syncing {
            m.addItem(disabled("Searching… hold the sync button on the Joy-Con"))
            m.addItem(action("Stop Searching") { [unowned self] in manager.stopSync() })
        } else {
            m.addItem(action("Sync Joy-Con 2…") { [unowned self] in manager.startSync() })
        }
        if !manager.devices.isEmpty {
            m.addItem(action("Disconnect") { [unowned self] in manager.disconnectAll() })
        }

        if !AXIsProcessTrusted() {
            m.addItem(.separator())
            m.addItem(action("⚠︎ Allow Accessibility (needed to move the pointer)…") { Self.openSettings("Privacy_Accessibility") })
        }

        m.addItem(.separator())
        m.addItem(toggle("Use as Mouse", settings.outputEnabled) { [unowned self] in
            settings.outputEnabled.toggle(); if !settings.outputEnabled { out.releaseAll() }
        })

        // Buttons
        let sides: [Side] = ready.isEmpty ? [.right, .left] : Array(Set(ready.map(\.side))).sorted { $0.rawValue > $1.rawValue }
        let buttons = NSMenu()
        for (i, side) in sides.enumerated() {
            if i > 0 { buttons.addItem(.separator()) }
            buttons.addItem(disabled(side == .right ? "Right Joy-Con" : "Left Joy-Con"))
            for b in Button.on(side) { buttons.addItem(buttonItem(b)) }
        }
        buttons.addItem(.separator())
        buttons.addItem(action("Reset to Default Layout") { [unowned self] in settings.mapping = Settings.defaultMapping })
        submenu(m, "Buttons", buttons)

        // Pointer
        let pointer = NSMenu()
        pointer.addItem(toggle("Optical Sensor (slide on a surface)", settings.opticalEnabled) { [unowned self] in settings.opticalEnabled.toggle() })
        pointer.addItem(toggle("Smooth Motion", settings.smoothingOff != true) { [unowned self] in
            settings.smoothingOff = settings.smoothingOff == true ? nil : true
        })
        pointer.addItem(.separator())
        pointer.addItem(disabled("Speed"))
        for (label, v) in Settings.speeds {
            pointer.addItem(toggle(label, settings.pointerSpeed == v, indent: 1) { [unowned self] in settings.pointerSpeed = v })
        }
        pointer.addItem(.separator())
        pointer.addItem(disabled("Stick"))
        for mode in StickMode.allCases {
            pointer.addItem(toggle(mode.label, settings.stickMode == mode, indent: 1) { [unowned self] in settings.stickMode = mode })
        }
        pointer.addItem(.separator())
        pointer.addItem(disabled("Sensor Direction"))
        pointer.addItem(toggle("Invert Horizontal", settings.invertX, indent: 1) { [unowned self] in settings.invertX.toggle() })
        pointer.addItem(toggle("Invert Vertical", settings.invertY, indent: 1) { [unowned self] in settings.invertY.toggle() })
        pointer.addItem(toggle("Swap Axes", settings.swapXY, indent: 1) { [unowned self] in settings.swapXY.toggle() })
        submenu(m, "Pointer", pointer)

        // Battery
        let battery = NSMenu()
        battery.addItem(disabled("Sleep When Idle"))
        for (label, v) in Settings.sleepChoices {
            battery.addItem(toggle(label, settings.sleepAfter == v, indent: 1) { [unowned self] in settings.idleMinutes = v })
        }
        battery.addItem(disabled("Press any button to wake it again."))
        battery.addItem(.separator())
        battery.addItem(toggle("Battery Saver (slower connection)", settings.batterySaver == true) { [unowned self] in
            settings.batterySaver = settings.batterySaver == true ? nil : true
        })
        battery.addItem(disabled("Applies the next time it connects."))
        submenu(m, "Battery", battery)

        m.addItem(.separator())
        m.addItem(action("Show Log") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/JoyMouse.log")) })
        if !settings.known.isEmpty {
            m.addItem(action("Forget Synced Joy-Cons") { [unowned self] in
                settings.known.removeAll(); manager.disconnectAll()
            })
        }
        let login = SMAppService.mainApp.status == .enabled
        m.addItem(toggle("Open at Login", login) {
            do { login ? try SMAppService.mainApp.unregister() : try SMAppService.mainApp.register() }
            catch { log("login item: \(error)") }
        })
        m.addItem(action("Quit JoyMouse", key: "q") { [unowned self] in
            out.releaseAll(); manager.disconnectAll(); NSApp.terminate(nil)
        })
    }

    private func buttonItem(_ b: Button) -> NSMenuItem {
        let current = settings.mapping[b] ?? .none
        let sub = NSMenu()
        for (i, group) in Action.groups.enumerated() {
            if i > 0 { sub.addItem(.separator()) }
            for a in group {
                sub.addItem(toggle(a.label, a == current) { [unowned self] in settings.mapping[b] = a })
            }
        }
        let item = NSMenuItem(title: b.label, action: nil, keyEquivalent: "")
        item.submenu = sub
        // Show the current action on the right, dimmed.
        let title = NSMutableAttributedString(string: b.label + "\t")
        title.append(NSAttributedString(string: current.label, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 110)]
        title.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: title.length))
        title.addAttribute(.font, value: NSFont.menuFont(ofSize: 0), range: NSRange(location: 0, length: title.length))
        item.attributedTitle = title
        item.indentationLevel = 1
        return item
    }

    // MARK: menu helpers

    private var handlers: [ObjectIdentifier: () -> Void] = [:]

    private func action(_ title: String, key: String = "", _ run: @escaping () -> Void) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: key)
        i.target = self
        handlers[ObjectIdentifier(i)] = run
        return i
    }

    private func toggle(_ title: String, _ on: Bool, indent: Int = 0, _ run: @escaping () -> Void) -> NSMenuItem {
        let i = action(title) { [unowned self] in run(); settings.save() }
        i.state = on ? .on : .off
        i.indentationLevel = indent
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func submenu(_ m: NSMenu, _ title: String, _ sub: NSMenu) {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        m.addItem(i)
    }

    @objc private func fire(_ sender: NSMenuItem) {
        handlers[ObjectIdentifier(sender)]?()
        settings.save()
    }

    private static func dot(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5)); ring.lineWidth = 0.5; ring.stroke()
            return true
        }
        img.isTemplate = false
        return img
    }

    private static func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
