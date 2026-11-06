import CommonCrypto
import Foundation
import IOBluetooth
import Security

// Joy-Con 2 BLE protocol pieces, adapted from WaveBird
// (github.com/murphyjt/wavebird, MIT, (c) 2026 Joshua Murphy), which credits
// ndeadly/switch2_controller_research, libsdl-org/SDL and darthcloud/BlueRetro.

enum NS2 {
    static let vendorID: UInt16 = 0x057E
    static let pidJoyConR: UInt16 = 0x2066
    static let pidJoyConL: UInt16 = 0x2067

    static let service = "AB7DE9BE-89FE-49AD-828F-118F09DF7FD0"
    static let input05 = "AB7DE9BE-89FE-49AD-828F-118F09DF7FD2"      // handle 0x000A
    static let commandWrite = "649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005" // handle 0x0014
    static let response1 = "C765A961-D9D8-4D36-A20A-5315B111836A"    // handle 0x001A
    static let response2L = "63A3810F-AEC7-474B-9010-3D52403CB996"   // handle 0x001E (L)
    static let response2R = "640CA58E-0E88-410C-A7F3-426FAF2B690B"   // handle 0x001E (R)

    // [cmd, 0x91, 0x01, sub, 0x00, len, 0x00, 0x00, payload...]
    static func frame(_ cmd: UInt8, _ sub: UInt8, _ payload: [UInt8] = []) -> Data {
        Data([cmd, 0x91, 0x01, sub, 0x00, UInt8(payload.count), 0x00, 0x00] + payload)
    }

    static let handshake = frame(0x07, 0x01)
    static let firmwareInfo = frame(0x10, 0x01)
    static func flashRead(_ address: UInt32) -> Data {
        frame(0x02, 0x04, [0x40, 0x7E, 0x00, 0x00,
                           UInt8(address & 0xFF), UInt8((address >> 8) & 0xFF),
                           UInt8((address >> 16) & 0xFF), UInt8((address >> 24) & 0xFF)])
    }
    static let factoryRead = flashRead(0x13000)          // serial + colours
    // Four 0xRRGGBB at 0x19/0x1C/0x1F/0x22 of that block (body, buttons, then two more); nil if unset.
    static func colors(_ block: Data) -> [UInt32]? {
        let b = Array(block)
        guard b.count >= 0x25 else { return nil }
        let c: [UInt32] = (0..<4).map { (k: Int) -> UInt32 in
            let o = 0x19 + 3 * k
            let r = UInt32(b[o]), g = UInt32(b[o + 1]), bl = UInt32(b[o + 2])
            return (r << 16) | (g << 8) | bl
        }
        return c.allSatisfy { $0 == 0xFFFFFF } ? nil : c
    }
    static let stickCalibrationRead = flashRead(0x13080) // each Joy-Con keeps its stick in this slot
    static let pairingInfoRead = flashRead(0x1FA000)
    static let batteryVoltage = frame(0x0B, 0x03)   // reply: [8..9] mV, little-endian
    static let connectionVibration = frame(0x0A, 0x02, [0x03, 0, 0, 0])
    static func playerLED(_ mask: UInt8) -> Data { frame(0x09, 0x07, [mask, 0, 0, 0, 0, 0, 0, 0]) }

    // Feature bits: 0x01 buttons, 0x02 analog sticks, 0x10 optical mouse (Joy-Con only).
    static let features: UInt8 = 0x01 | 0x02 | 0x10
    static func setFeatureMask(_ f: UInt8) -> Data { frame(0x0C, 0x02, [f, 0, 0, 0]) }
    static func enableFeatures(_ f: UInt8) -> Data { frame(0x0C, 0x04, [f, 0, 0, 0]) }

    // Responses echo cmd (byte 0) and subcmd (byte 3).
    static func matches(request: Data, response: Data) -> Bool {
        request.count >= 4 && response.count >= 4 && request[0] == response[0] && request[3] == response[3]
    }
}


// MARK: - Report 0x05

struct StickCal {
    var nX: Int, nY: Int, maxX: Int, maxY: Int, minX: Int, minY: Int

    // 9 bytes at 0x28 of the 0x40-byte flash block, packed 12-bit pairs.
    static func parse(_ block: Data) -> StickCal? {
        let b = Array(block)
        guard b.count >= 0x28 + 9 else { return nil }
        let o = 0x28
        func pair(_ i: Int) -> (Int, Int) {
            (Int(b[i]) | (Int(b[i + 1] & 0x0F) << 8), Int(b[i + 1] >> 4) | (Int(b[i + 2]) << 4))
        }
        let n = pair(o), mx = pair(o + 3), mn = pair(o + 6)
        let cal = StickCal(nX: n.0, nY: n.1, maxX: mx.0, maxY: mx.1, minX: mn.0, minY: mn.1)
        return [cal.nX, cal.nY, cal.maxX, cal.maxY, cal.minX, cal.minY].contains(0) ? nil : cal
    }

    // -1...1
    func axis(_ raw: Int, _ neutral: Int, _ above: Int, _ below: Int) -> Double {
        let d = raw - neutral
        let v = d >= 0 ? Double(d) / Double(above) : Double(d) / Double(below)
        return max(-1, min(1, v))
    }
}

struct Report {
    var buttons: UInt32
    var stickRaw: (x: Int, y: Int)
    var mouseX: UInt16
    var mouseY: UInt16
    var batteryMV: Int

    static func parse(_ data: Data, side: Side) -> Report? {
        let b = Array(data)
        guard b.count >= 0x22 else { return nil }
        let buttons = UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24
        let s = side == .left ? 0x0A : 0x0D
        let sx = Int(b[s]) | (Int(b[s + 1] & 0x0F) << 8)
        let sy = Int(b[s + 1] >> 4) | (Int(b[s + 2]) << 4)
        return Report(
            buttons: buttons,
            stickRaw: (sx, sy),
            mouseX: UInt16(b[0x10]) | UInt16(b[0x11]) << 8,
            mouseY: UInt16(b[0x12]) | UInt16(b[0x13]) << 8,
            batteryMV: Int(b[0x1F]) | Int(b[0x20]) << 8
        )
    }
}

enum Side: String, Codable { case left = "L", right = "R" }

// MARK: - LTK pairing (cmd 0x15), so a paired Joy-Con reconnects on any button press.

enum Pairing {
    static func hostAddress() -> [UInt8]? {
        guard let raw = IOBluetoothHostController.default()?.addressAsString() else { return nil }
        let parts = raw.split { $0 == "-" || $0 == ":" }.compactMap { UInt8($0, radix: 16) }
        return parts.count == 6 ? parts : nil
    }

    // 0x1FA000 block: [0] count, host #1 at 0x08, host #2 at 0x30 (natural order).
    static func storedHosts(_ block: Data) -> [[UInt8]] {
        let b = Array(block)
        guard b.count >= 0x36, (0...2).contains(Int(b[0])) else { return [] }
        var out: [[UInt8]] = []
        if b[0] >= 1 { out.append(Array(b[0x08..<0x0E])) }
        if b[0] >= 2 { out.append(Array(b[0x30..<0x36])) }
        return out
    }

    static func exchangeAddresses(_ host: [UInt8]) -> Data {
        var second = host
        second[5] = second[5] &- 1
        return NS2.frame(0x15, 0x01, [0x00, 0x02] + host.reversed() + second.reversed())
    }
    static func exchangeKeys(_ a1: [UInt8]) -> Data { NS2.frame(0x15, 0x04, [0x00] + a1.reversed()) }
    static func confirmLTK(_ a2: [UInt8]) -> Data { NS2.frame(0x15, 0x02, [0x00] + a2.reversed()) }
    static let finalise = NS2.frame(0x15, 0x03, [0x00])

    static func random16() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &b)
        return b
    }

    static func aes128ECB(key: [UInt8], block: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: 16)
        var written = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                             key, 16, nil, block, 16, &out, 16, &written)
        return status == kCCSuccess && written == 16 ? out : nil
    }
}
