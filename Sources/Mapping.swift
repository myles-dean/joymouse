import Foundation

// Report 0x05 button bits (dword at offset 4), per ndeadly hid_reports.md.
enum Button: String, CaseIterable, Codable {
    // Right Joy-Con
    case r, zr, a, b, x, y, plus, home, c, stickR, slR, srR
    // Left Joy-Con
    case l, zl, up, down, left, right, minus, capture, stickL, slL, srL

    var bit: Int {
        switch self {
        case .y: 0; case .x: 1; case .b: 2; case .a: 3; case .srR: 4; case .slR: 5; case .r: 6; case .zr: 7
        case .minus: 8; case .plus: 9; case .stickR: 10; case .stickL: 11; case .home: 12; case .capture: 13; case .c: 14
        case .down: 16; case .up: 17; case .right: 18; case .left: 19; case .srL: 20; case .slL: 21; case .l: 22; case .zl: 23
        }
    }

    var side: Side {
        switch self {
        case .r, .zr, .a, .b, .x, .y, .plus, .home, .c, .stickR, .slR, .srR: .right
        default: .left
        }
    }

    var label: String {
        switch self {
        case .r: "R"; case .zr: "ZR"; case .a: "A"; case .b: "B"; case .x: "X"; case .y: "Y"
        case .plus: "+"; case .home: "Home"; case .c: "C"; case .stickR: "Stick Press"
        case .slR: "SL"; case .srR: "SR"
        case .l: "L"; case .zl: "ZL"; case .up: "Up"; case .down: "Down"; case .left: "Left"; case .right: "Right"
        case .minus: "−"; case .capture: "Capture"; case .stickL: "Stick Press"; case .slL: "SL"; case .srL: "SR"
        }
    }

    static func on(_ side: Side) -> [Button] { allCases.filter { $0.side == side } }
}

enum Action: String, CaseIterable, Codable {
    case none
    case leftClick, rightClick, middleClick, doubleClick, back, forward
    case scrollUp, scrollDown, precision, pausePointer
    case missionControl, appSwitcher, escape, returnKey, space, tab, delete
    case upArrow, downArrow, leftArrow, rightArrow

    var label: String {
        switch self {
        case .none: "Nothing"
        case .leftClick: "Left Click"; case .rightClick: "Right Click"; case .middleClick: "Middle Click"
        case .doubleClick: "Double Click"; case .back: "Back (⌘[)"; case .forward: "Forward (⌘])"
        case .scrollUp: "Scroll Up"; case .scrollDown: "Scroll Down"
        case .precision: "Precision (slow pointer while held)"; case .pausePointer: "Freeze Pointer (while held)"
        case .missionControl: "Mission Control"; case .appSwitcher: "App Switcher (⌘Tab)"
        case .escape: "Escape"; case .returnKey: "Return"; case .space: "Space"; case .tab: "Tab"; case .delete: "Delete"
        case .upArrow: "↑"; case .downArrow: "↓"; case .leftArrow: "←"; case .rightArrow: "→"
        }
    }

    // Menu grouping (a separator goes before each group's first entry).
    static let groups: [[Action]] = [
        [.none],
        [.leftClick, .rightClick, .middleClick, .doubleClick, .back, .forward],
        [.scrollUp, .scrollDown, .precision, .pausePointer],
        [.missionControl, .appSwitcher, .escape, .returnKey, .space, .tab, .delete],
        [.upArrow, .downArrow, .leftArrow, .rightArrow],
    ]
}

enum StickMode: String, Codable, CaseIterable {
    case scroll, pointer, off
    var label: String { switch self { case .scroll: "Scroll"; case .pointer: "Move Pointer"; case .off: "Off" } }
}

struct Settings: Codable, Equatable {
    var mapping: [Button: Action] = Settings.defaultMapping
    var opticalEnabled = true
    var pointerSpeed: Double = 1.0
    var invertX = false
    var invertY = false
    var swapXY = false
    var stickMode: StickMode = .scroll
    var outputEnabled = true
    var smoothingOff: Bool? = nil     // optional so older saved settings still decode
    var idleMinutes: Int? = nil       // nil = 5 (default), 0 = never
    var batterySaver: Bool? = nil     // true = normal (slower) Bluetooth link instead of low latency

    var sleepAfter: Int { idleMinutes ?? 5 }
    static let sleepChoices: [(String, Int)] = [("2 Minutes", 2), ("5 Minutes", 5), ("10 Minutes", 10), ("30 Minutes", 30), ("Never", 0)]
    var known: [String: Side] = [:]   // peripheral UUID → side

    static let defaultMapping: [Button: Action] = [
        // Right Joy-Con: R = left click, ZR = right click.
        .r: .leftClick, .zr: .rightClick,
        .a: .returnKey, .b: .escape, .x: .missionControl, .y: .space,
        .stickR: .middleClick, .slR: .back, .srR: .forward,
        .plus: .none, .home: .none, .c: .none,
        // Left Joy-Con mirrors it: L = left click, ZL = right click.
        .l: .leftClick, .zl: .rightClick,
        .up: .upArrow, .down: .downArrow, .left: .leftArrow, .right: .rightArrow,
        .stickL: .middleClick, .slL: .back, .srL: .forward,
        .minus: .none, .capture: .none,
    ]

    static let speeds: [(String, Double)] = [("Slow", 0.5), ("Normal", 1.0), ("Fast", 1.6), ("Very Fast", 2.5)]

    private static let key = "settings.v1"

    static func load() -> Settings {
        // Settings saved under the old bundle ID (local.joymouse) carry over once.
        if UserDefaults.standard.data(forKey: key) == nil,
           let old = UserDefaults(suiteName: "local.joymouse")?.data(forKey: key) {
            UserDefaults.standard.set(old, forKey: key)
        }
        guard let data = UserDefaults.standard.data(forKey: key),
              var s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        for b in Button.allCases where s.mapping[b] == nil { s.mapping[b] = defaultMapping[b] ?? Action.none }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Settings.key) }
    }
}
