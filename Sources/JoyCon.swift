// Connection, command queue and pairing flow adapted from WaveBird
// (github.com/murphyjt/wavebird, MIT, (c) 2026 Joshua Murphy). See THIRD_PARTY_NOTICES.md.
import AppKit
import CoreBluetooth

// Log: stderr + ~/Library/Logs/JoyMouse.log (trimmed at launch past 512 KB).
private let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/JoyMouse.log")
private let logHandle: FileHandle? = {
    if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int, size > 512_000 {
        try? FileManager.default.removeItem(at: logURL)
    }
    if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
    let h = try? FileHandle(forWritingTo: logURL)
    h?.seekToEndOfFile()
    return h
}()
private let logTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
func log(_ s: String) {
    let line = "\(logTime.string(from: Date())) \(s)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    logHandle?.write(line.data(using: .utf8)!)
}

extension Timer {
    // Scheduled in the common modes, so it keeps firing while a menu is open.
    static func common(withTimeInterval t: TimeInterval, repeats: Bool, block: @escaping (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: t, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

protocol JoyConDelegate: AnyObject {
    func joyConChanged()
    func joyCon(_ jc: JoyCon, report: Report, dt: Double)
}

// One connected Joy-Con 2.
final class JoyCon: NSObject, CBPeripheralDelegate {
    let peripheral: CBPeripheral
    var side: Side
    var ready = false
    var calibration: StickCal?
    var batteryMV = 0
    var colors: [UInt32]?
    var lastReport: Report?
    var lastReportTime: TimeInterval = 0
    var lastActivity = ProcessInfo.processInfo.systemUptime
    weak var delegate: JoyConDelegate?

    private var writeChar: CBCharacteristic?
    private var inputChar: CBCharacteristic?
    private var responseChars: [CBCharacteristic] = []
    private var queue: [(Data, (Data?) -> Void)] = []
    private var pending: (request: Data, done: (Data?) -> Void, token: Int)?
    private var token = 0
    private var batteryTimer: Timer?
    private var lastRaw: Data?

    init(peripheral: CBPeripheral, side: Side) {
        self.peripheral = peripheral
        self.side = side
        super.init()
        peripheral.delegate = self
    }

    deinit { batteryTimer?.invalidate() }

    var name: String { side == .right ? "Joy-Con 2 (R)" : "Joy-Con 2 (L)" }

    // Rough Li-ion curve (resting voltage → %); good to ~10%.
    var batteryPercent: Int? {
        guard batteryMV > 3000, batteryMV < 4500 else { return nil }
        let curve: [(Int, Int)] = [(3100, 0), (3300, 3), (3500, 6), (3600, 12), (3700, 30), (3750, 42), (3800, 55),
                                   (3900, 70), (4000, 83), (4100, 95), (4150, 100)]
        let v = batteryMV
        if v <= curve[0].0 { return 0 }
        for i in 1..<curve.count where v <= curve[i].0 {
            let (v0, p0) = curve[i - 1], (v1, p1) = curve[i]
            return p0 + (p1 - p0) * (v - v0) / (v1 - v0)
        }
        return 100
    }

    // Report 0x05 byte 0x21: 0 on battery, rises (settles at 0x34) on USB power, 0x20 when full.
    var charging: Bool { (lastRaw?.count ?? 0) > 0x21 && lastRaw![0x21] != 0 }

    // The Joy-Con's accent: the most saturated of its factory colours (body and buttons are greys).
    var accentColor: NSColor? {
        guard let colors else { return nil }
        let ns = colors.map { NSColor(srgbRed: CGFloat($0 >> 16 & 0xFF) / 255, green: CGFloat($0 >> 8 & 0xFF) / 255,
                                      blue: CGFloat($0 & 0xFF) / 255, alpha: 1) }
        return ns.max { $0.saturationComponent * $0.brightnessComponent < $1.saturationComponent * $1.brightnessComponent }
    }

    func buzz() { send(NS2.connectionVibration) }

    func didConnect() {
        peripheral.discoverServices([CBUUID(string: NS2.service)])
    }

    // MARK: GATT discovery

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == CBUUID(string: NS2.service) }) else {
            log("service not found: \(error?.localizedDescription ?? "-")")
            return
        }
        p.discoverCharacteristics(nil, for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        func find(_ s: String) -> CBCharacteristic? { chars.first { $0.uuid == CBUUID(string: s) } }
        writeChar = find(NS2.commandWrite)
        inputChar = find(NS2.input05)
        responseChars = [NS2.response1, NS2.response2L, NS2.response2R].compactMap(find)
        guard writeChar != nil, inputChar != nil else { log("missing characteristics"); return }
        for c in responseChars { p.setNotifyValue(true, for: c) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.runInit() }
    }

    // MARK: commands

    private func send(_ cmd: Data, _ done: @escaping (Data?) -> Void = { _ in }) {
        queue.append((cmd, done))
        pump()
    }

    private func pump() {
        guard pending == nil, !queue.isEmpty, let w = writeChar else { return }
        let (cmd, done) = queue.removeFirst()
        token += 1
        let t = token
        pending = (cmd, done, t)
        peripheral.writeValue(cmd, for: w, type: .withoutResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let p = self.pending, p.token == t else { return }
            self.pending = nil
            p.done(nil)
            self.pump()
        }
    }

    private func runInit() {
        send(NS2.handshake)
        send(NS2.firmwareInfo) { r in
            // [8+3] controller type: 0 = Joy-Con L, 1 = Joy-Con R
            if let r, r.count > 11 { self.side = r[11] == 0x00 ? .left : (r[11] == 0x01 ? .right : self.side) }
        }
        send(NS2.factoryRead) { r in
            if let r { self.colors = NS2.colors(Data(r.dropFirst(16))) }
            log("\(self.name) colours \(self.colors?.map { String(format: "#%06X", $0) }.joined(separator: " ") ?? "none")")
        }
        send(NS2.stickCalibrationRead) { r in
            if let r { self.calibration = StickCal.parse(r.dropFirst(16)) }
        }
        send(NS2.pairingInfoRead) { r in
            let hosts = r.map { Pairing.storedHosts(Data($0.dropFirst(16))) } ?? []
            guard let host = Pairing.hostAddress() else { log("no host Bluetooth address: can't pair"); return }
            if hosts.contains(host) {
                log("\(self.name) already paired with this Mac")
            } else {
                self.pair(host: host)
            }
        }
        send(NS2.connectionVibration)
        send(NS2.playerLED(0x01))
        send(NS2.setFeatureMask(NS2.features))
        send(NS2.enableFeatures(NS2.features)) { _ in
            if let c = self.inputChar { self.peripheral.setNotifyValue(true, for: c) }
            self.ready = true
            self.lastActivity = ProcessInfo.processInfo.systemUptime
            log("\(self.name) ready (stick cal: \(self.calibration != nil))")
            self.delegate?.joyConChanged()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.readBattery() }
            self.batteryTimer = Timer.common(withTimeInterval: 60, repeats: true) { [weak jc = self] _ in jc?.readBattery() }
        }
    }

    private func readBattery() {
        send(NS2.batteryVoltage) { r in
            guard let r, r.count >= 10 else { return }
            let mv = Int(r[8]) | Int(r[9]) << 8
            if self.batteryMV != mv, let rep = self.lastRaw, rep.count > 0x24 {
                log("battery raw reply \(r.map { String(format: "%02x", $0) }.joined(separator: " ")); report[0x1F..0x23] \(rep[0x1F...0x23].map { String(format: "%02x", $0) }.joined(separator: " "))")
            }
            let old = self.batteryPercent
            self.batteryMV = mv
            if self.batteryPercent != old {
                log("\(self.name) battery \(mv) mV ≈ \(self.batteryPercent.map(String.init) ?? "?")%")
                self.delegate?.joyConChanged()
            }
        }
    }

    // Nintendo's own key exchange over the command channel. Once this Mac is in
    // the controller's flash, a woken Joy-Con broadcasts this Mac's address and we reconnect.
    private func pair(host: [UInt8]) {
        log("pairing \(name) with this Mac")
        let a1 = Pairing.random16(), a2 = Pairing.random16()
        var ltk: [UInt8] = []
        // These get queued ahead of the rest of init (we're inside a completion).
        queue.insert(contentsOf: [
            (Pairing.exchangeAddresses(host), { r in if r == nil { log("pairing: no reply to addresses") } }),
            (Pairing.exchangeKeys(a1), { r in
                guard let r, r.count >= 8 + 17 else { log("pairing: no key"); return }
                let b1 = Array(r.dropFirst(9).prefix(16)).reversed()
                ltk = zip(a1, b1).map { $0 ^ $1 }
            }),
            (Pairing.confirmLTK(a2), { r in
                guard let r, r.count >= 8 + 17, ltk.count == 16 else { log("pairing: no confirmation"); return }
                let b2 = Array(r.dropFirst(9).prefix(16))
                if Pairing.aes128ECB(key: ltk, block: a2) != b2 { log("pairing: LTK mismatch") }
            }),
            (Pairing.finalise, { r in log(r == nil ? "pairing: finalise timed out" : "paired with this Mac") }),
        ], at: 0)
    }

    // MARK: notifications

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let v = c.value else { return }
        if c == inputChar {
            guard let r = Report.parse(v, side: side) else { return }
            lastRaw = v
            let now = ProcessInfo.processInfo.systemUptime
            let dt = lastReportTime == 0 ? 0 : min(0.1, now - lastReportTime)
            lastReportTime = now
            if let last = lastReport, last.buttons != r.buttons || last.mouseX != r.mouseX || last.mouseY != r.mouseY
                || abs(last.stickRaw.x - r.stickRaw.x) > 150 || abs(last.stickRaw.y - r.stickRaw.y) > 150 {
                lastActivity = now
            }
            delegate?.joyCon(self, report: r, dt: dt)
            lastReport = r
            return
        }
        if let pend = pending, NS2.matches(request: pend.request, response: v) {
            pending = nil
            pend.done(v)
            pump()
        }
    }
}

// Scans, connects, remembers Joy-Cons.
final class JoyConManager: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!
    private(set) var devices: [UUID: JoyCon] = [:]
    private var connecting: [UUID: (p: CBPeripheral, side: Side, at: TimeInterval)] = [:]
    private(set) var syncing = false
    private var syncTimer: Timer?
    private var idleTimer: Timer?
    private var seenAdverts: [UUID: [UInt8]] = [:]
    private lazy var hostAddress = Pairing.hostAddress()
    var known: () -> [String: Side] = { [:] }
    var remember: (UUID, Side) -> Void = { _, _ in }
    var idleMinutes: () -> Int = { 0 }
    var lowLatency: () -> Bool = { true }
    weak var delegate: JoyConDelegate?
    var enabled = true { didSet { enabled ? start() : stop() } }

    var bluetoothState: CBManagerState { central.state }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        idleTimer = Timer.common(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.idleSweep() }
    }

    func startSync() {
        syncing = true
        syncTimer?.invalidate()
        syncTimer = Timer.common(withTimeInterval: 60, repeats: false) { [weak self] _ in
            log("sync: no Joy-Con found in 60 s")
            self?.syncing = false
            self?.delegate?.joyConChanged()
        }
        log("sync: searching")
        restartScan()
        delegate?.joyConChanged()
    }

    func stopSync() {
        syncing = false
        syncTimer?.invalidate()
        delegate?.joyConChanged()
    }

    func disconnectAll() {
        for d in devices.values { central.cancelPeripheralConnection(d.peripheral) }
        for c in connecting.values { central.cancelPeripheralConnection(c.p) }
        connecting.removeAll()
    }

    // Disconnecting lets the Joy-Con go to sleep; a button press wakes it and it reconnects.
    private func idleSweep() {
        let minutes = idleMinutes()
        guard minutes > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for d in devices.values where d.ready && now - d.lastActivity > Double(minutes * 60) {
            log("\(d.name) idle for \(minutes) min: disconnecting so it can sleep")
            central.cancelPeripheralConnection(d.peripheral)
        }
    }

    private func start() {
        guard central.state == .poweredOn, enabled else { return }
        restartScan()
    }

    private func stop() {
        central.stopScan()
        disconnectAll()
    }

    // Duplicates on: a woken Joy-Con re-advertises from a device we've already
    // seen, and with duplicate filtering macOS would never tell us again.
    private func restartScan() {
        guard central.state == .poweredOn, enabled else { return }
        central.stopScan()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func connect(_ p: CBPeripheral, side: Side) {
        guard devices[p.identifier] == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // A connect attempt that has hung for a while is restarted from the fresh advert.
        if let c = connecting[p.identifier] {
            guard now - c.at > 3 else { return }
            central.cancelPeripheralConnection(c.p)
        }
        connecting[p.identifier] = (p, side, now)
        // Lowest connection interval: more reports per second, more battery.
        let options: [String: Any] = lowLatency() ? ["kCBConnectOptionRequiresLowLatency": true] : [:]
        central.connect(p, options: options)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("bluetooth state \(c.state.rawValue), host address \(hostAddress.map { $0.map { String(format: "%02X", $0) }.joined(separator: ":") } ?? "unknown")")
        start()
        delegate?.joyConChanged()
    }

    // Manufacturer data (company 0x0553 first): [5..6] VID, [7..8] PID,
    // [0xB] 0x81 = wake, [0xC..0x11] paired host address (reversed), all zero in sync mode.
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        guard enabled, let mfg = ad[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 9 else { return }
        let b = Array(mfg)
        guard b[0] == 0x53, b[1] == 0x05 else { return }
        let vid = UInt16(b[5]) | UInt16(b[6]) << 8, pid = UInt16(b[7]) | UInt16(b[8]) << 8
        guard vid == NS2.vendorID, pid == NS2.pidJoyConR || pid == NS2.pidJoyConL else { return }
        guard devices[p.identifier] == nil else { return }
        let side: Side = pid == NS2.pidJoyConL ? .left : .right

        let advHost: [UInt8]? = b.count >= 0x12 ? Array(b[0x0C..<0x12].reversed()) : nil
        let forUs = advHost != nil && advHost == hostAddress
        if seenAdverts[p.identifier] != b {   // log each distinct advert once
            seenAdverts[p.identifier] = b
            let kind = advHost == nil || advHost!.allSatisfy({ $0 == 0 }) ? "sync" : (forUs ? "reconnect to this Mac" : "reconnect to another host")
            log("advert \(side.rawValue) \(p.identifier): \(kind)\(b.count > 0x0B && b[0x0B] == 0x81 ? " (wake)" : "") rssi \(rssi)")
        }

        // Reconnect anything that says it belongs to this Mac (even if macOS gave
        // it a new identifier), or anything at all while syncing.
        let isKnown = known()[p.identifier.uuidString] != nil
        guard syncing || forUs || isKnown else { return }
        if !syncing && !forUs && isKnown && advHost?.allSatisfy({ $0 == 0 }) == false { return } // paired elsewhere now
        connect(p, side: side)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        let side = connecting.removeValue(forKey: p.identifier)?.side ?? .right
        log("connected \(side.rawValue) \(p.identifier)")
        let jc = JoyCon(peripheral: p, side: side)
        jc.delegate = delegate
        devices[p.identifier] = jc
        remember(p.identifier, side)
        if syncing { stopSync() }
        jc.didConnect()
        delegate?.joyConChanged()
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("connect failed \(p.identifier): \(error?.localizedDescription ?? "-")")
        connecting[p.identifier] = nil
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("disconnected \(p.identifier): \(error?.localizedDescription ?? "by us")")
        devices.removeValue(forKey: p.identifier)
        connecting[p.identifier] = nil
        delegate?.joyConChanged()
        // No pending connect: the Joy-Con's own wake advert (carrying this Mac's
        // address) brings it back as soon as a button is pressed.
    }
}
