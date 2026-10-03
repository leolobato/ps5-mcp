// PMCP wire protocol v1 (frozen; mirror of payload/protocol.h and src/ps5mcp/protocol.py, spec in docs/protocol.md).

import Foundation

enum PMCP {
    static let magic: [UInt8] = Array("PMCP".utf8)
    static let version: UInt8 = 1
    static let port: UInt16 = 9305
    static let headerBytes = 8
    static let maxPayload = 256
    static let flagPadReady: UInt32 = 0x1
    static let flagUserName: UInt32 = 0x4
    static let flagUninstall: UInt32 = 0x8

    enum Kind: UInt8 { case hello = 1, state, ping, ack, error, shutdown, getState, command, getUser }
    enum Command: UInt32 { case home = 1, launch = 2, close = 3, uninstall = 4 }
    enum ErrorCode: UInt32 { case badMagic = 1, badVersion, badLength, unknownType, busy, noPad }

    static let homeMethods = ["system", "shellcore", "suspend"]

    /// Uninstall statuses (padd 1.3), as `protocol.UNINSTALL_ERRORS` in Python.
    static let uninstallRetry: Set<Int32> = [16, 36]  // EBUSY, EINPROGRESS: SMP is busy or still deleting the source
    static func uninstallText(_ status: Int32) -> String {
        switch status {
        case 0: return "uninstall requested"
        case 5: return "ShadowMountPlus refused to delete the source (an image shared by several titles?)"
        case 16: return "busy: a game is running or ShadowMountPlus is moving files"
        case 22: return "not a title id"
        case 36: return "ShadowMountPlus is still deleting the source; try again shortly"
        case 61: return "ShadowMountPlus manages it but is not running; it would install it again"
        default: return String(format: "refused, status 0x%08X", UInt32(bitPattern: status))
        }
    }
}

/// Button bits, in the order of `protocol.BUTTONS`.
let buttonBits: [(name: String, bit: UInt32)] = [
    ("l3", 0x2), ("r3", 0x4), ("options", 0x8),
    ("up", 0x10), ("right", 0x20), ("down", 0x40), ("left", 0x80),
    ("l2", 0x100), ("r2", 0x200), ("l1", 0x400), ("r1", 0x800),
    ("triangle", 0x1000), ("circle", 0x2000), ("cross", 0x4000), ("square", 0x8000),
    ("touchpad", 0x100000),
]

func button(_ name: String) -> UInt32 { buttonBits.first { $0.name == name }!.bit }

struct BadInput: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func buttonMask(_ names: [String]) throws -> UInt32 {
    var mask: UInt32 = 0
    for name in names {
        let key = name.lowercased().replacingOccurrences(of: "dpad_", with: "").replacingOccurrences(of: "dpad-", with: "")
        guard let bit = buttonBits.first(where: { $0.name == key })?.bit else {
            throw BadInput("unknown button '\(name)'; known: \(buttonBits.map(\.name).joined(separator: ", "))")
        }
        mask |= bit
    }
    return mask
}

struct Touch: Equatable {
    var active = false
    var id: UInt8 = 0
    var x: UInt16 = 0
    var y: UInt16 = 0
}

struct PadState: Equatable {
    static let center: UInt8 = 0x80
    var buttons: UInt32 = 0
    var lx = center, ly = center, rx = center, ry = center
    var l2: UInt8 = 0, r2: UInt8 = 0
    var touch = [Touch(), Touch()]

    static let neutral = PadState()
    var isNeutral: Bool { self == .neutral }

    /// Buttons OR'd; axes from whichever side is further from rest; triggers max (PadState.merged in Python).
    func merged(_ other: PadState) -> PadState {
        func axis(_ a: UInt8, _ b: UInt8) -> UInt8 {
            abs(Int(a) - Int(PadState.center)) >= abs(Int(b) - Int(PadState.center)) ? a : b
        }
        var out = self
        out.buttons |= other.buttons
        out.lx = axis(lx, other.lx); out.ly = axis(ly, other.ly)
        out.rx = axis(rx, other.rx); out.ry = axis(ry, other.ry)
        out.l2 = max(l2, other.l2); out.r2 = max(r2, other.r2)
        if !touch.contains(where: \.active) { out.touch = other.touch }
        return out
    }

    // JSON form used by the app API: raw protocol values. `buttons` may also be a list of names.
    init() {}

    init(json: [String: Any]) throws {
        if let names = json["buttons"] as? [String] {
            buttons = try buttonMask(names)
        } else if let raw = json["buttons"] {
            guard let value = raw as? Int, value >= 0, value <= Int(UInt32.max) else { throw BadInput("bad buttons") }
            buttons = UInt32(value)
        }
        func byte(_ key: String, _ fallback: UInt8) throws -> UInt8 {
            guard let raw = json[key] else { return fallback }
            guard let value = raw as? Int, (0...255).contains(value) else { throw BadInput("\(key) must be 0..255") }
            return UInt8(value)
        }
        lx = try byte("lx", lx); ly = try byte("ly", ly); rx = try byte("rx", rx); ry = try byte("ry", ry)
        l2 = try byte("l2", 0); r2 = try byte("r2", 0)
        if let points = json["touch"] as? [[String: Any]] {
            for (i, point) in points.prefix(2).enumerated() {
                touch[i] = Touch(active: point["active"] as? Bool ?? false, id: UInt8(point["id"] as? Int ?? 0),
                                 x: UInt16(clamping: point["x"] as? Int ?? 0), y: UInt16(clamping: point["y"] as? Int ?? 0))
            }
        }
    }

    var json: [String: Any] {
        var out: [String: Any] = ["buttons": Int(buttons), "lx": Int(lx), "ly": Int(ly), "rx": Int(rx), "ry": Int(ry),
                                  "l2": Int(l2), "r2": Int(r2)]
        if touch.contains(where: \.active) {
            out["touch"] = touch.map { ["active": $0.active, "id": Int($0.id), "x": Int($0.x), "y": Int($0.y)] }
        }
        return out
    }
}

struct Hello {
    var proto: UInt16, payloadVersion: UInt16, padHandle: Int32, userID: Int32, flags: UInt32, addStatus: UInt32
    var userName: String? = nil
    var padReady: Bool { flags & PMCP.flagPadReady != 0 }
    var versionString: String { "\(payloadVersion >> 8).\(payloadVersion & 0xFF)" }
    var json: [String: Any] {
        ["protocol": Int(proto), "payload_version": Int(payloadVersion), "pad_handle": Int(padHandle),
         "user_id": Int(userID), "user_name": userName as Any? ?? NSNull(), "flags": Int(flags), "add_status": Int(addStatus)]
    }
}

struct Pong {
    var token: UInt32, proto: UInt16, payloadVersion: UInt16, uptimeMS: UInt64, padHandle: Int32, flags: UInt32
    var reportsSent: UInt64, reportFailures: UInt32, neutralEvents: UInt32
    var json: [String: Any] {
        ["token": Int(token), "protocol": Int(proto), "payload_version": Int(payloadVersion), "uptime_ms": uptimeMS,
         "pad_handle": Int(padHandle), "flags": Int(flags), "reports_sent": reportsSent,
         "report_failures": Int(reportFailures), "neutral_events": Int(neutralEvents)]
    }
}

// MARK: - encoding

struct Bytes {
    var data = [UInt8]()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data += [UInt8(v & 0xFF), UInt8(v >> 8)] }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { data.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
}

struct Cursor {
    let data: [UInt8]
    var at = 0
    mutating func u8() -> UInt8 { defer { at += 1 }; return data[at] }
    mutating func u16() -> UInt16 { UInt16(u8()) | UInt16(u8()) << 8 }
    mutating func u32() -> UInt32 { UInt32(u16()) | UInt32(u16()) << 16 }
    mutating func u64() -> UInt64 { UInt64(u32()) | UInt64(u32()) << 32 }
    mutating func i32() -> Int32 { Int32(bitPattern: u32()) }
}

func encode(_ kind: PMCP.Kind, _ payload: [UInt8] = []) -> [UInt8] {
    precondition(payload.count <= PMCP.maxPayload)
    var b = Bytes()
    b.data = PMCP.magic
    b.u8(PMCP.version)
    b.u8(kind.rawValue)
    b.u16(UInt16(payload.count))
    return b.data + payload
}

func encodeState(seq: UInt32, _ s: PadState) -> [UInt8] {
    var b = Bytes()
    b.u32(seq); b.u32(s.buttons)
    for v in [s.lx, s.ly, s.rx, s.ry, s.l2, s.r2, 0, 0] { b.u8(v) }
    for t in s.touch { b.u8(t.active ? 1 : 0); b.u8(t.id); b.u16(t.x); b.u16(t.y) }
    assert(b.data.count == 28)
    return encode(.state, b.data)
}

func decodeState(_ payload: [UInt8]) -> PadState {
    var c = Cursor(data: payload)
    _ = c.u32()
    var s = PadState()
    s.buttons = c.u32()
    s.lx = c.u8(); s.ly = c.u8(); s.rx = c.u8(); s.ry = c.u8(); s.l2 = c.u8(); s.r2 = c.u8()
    _ = c.u16()
    for i in 0..<2 { s.touch[i] = Touch(active: c.u8() != 0, id: c.u8(), x: c.u16(), y: c.u16()) }
    return s
}

func encodePing(_ token: UInt32) -> [UInt8] {
    var b = Bytes(); b.u32(token); return encode(.ping, b.data)
}

func encodeCommand(seq: UInt32, _ op: PMCP.Command, _ arg: String) throws -> [UInt8] {
    let raw = Array(arg.utf8)
    if raw.count > 31 { throw BadInput("command argument longer than 31 bytes") }
    var b = Bytes(); b.u32(seq); b.u32(op.rawValue)
    b.data += raw + [UInt8](repeating: 0, count: 32 - raw.count)
    assert(b.data.count == 40)
    return encode(.command, b.data)
}

func decodeHello(_ p: [UInt8]) -> Hello {
    var c = Cursor(data: p)
    return Hello(proto: c.u16(), payloadVersion: c.u16(), padHandle: c.i32(), userID: c.i32(), flags: c.u32(),
                 addStatus: c.u32())
}

func decodePong(_ p: [UInt8]) -> Pong {
    var c = Cursor(data: p)
    return Pong(token: c.u32(), proto: c.u16(), payloadVersion: c.u16(), uptimeMS: c.u64(), padHandle: c.i32(),
                flags: c.u32(), reportsSent: c.u64(), reportFailures: c.u32(), neutralEvents: c.u32())
}

func decodeAck(_ p: [UInt8]) -> (seq: UInt32, status: Int32) {
    var c = Cursor(data: p)
    return (c.u32(), c.i32())
}

func decodeError(_ p: [UInt8]) -> (code: UInt32, message: String) {
    var c = Cursor(data: p)
    return (c.u32(), String(decoding: p.dropFirst(4), as: UTF8.self))
}

struct ProtocolError: Error, CustomStringConvertible { let description: String }

/// Incremental decoder: feed bytes, get (type, payload) messages.
struct FrameReader {
    private var buffer = [UInt8]()

    mutating func feed(_ bytes: ArraySlice<UInt8>) throws -> [(UInt8, [UInt8])] {
        buffer += bytes
        var messages: [(UInt8, [UInt8])] = []
        while buffer.count >= PMCP.headerBytes {
            if Array(buffer[0..<4]) != PMCP.magic { throw ProtocolError(description: "bad magic") }
            if buffer[4] != PMCP.version { throw ProtocolError(description: "unsupported protocol version \(buffer[4])") }
            let length = Int(buffer[6]) | Int(buffer[7]) << 8
            if length > PMCP.maxPayload { throw ProtocolError(description: "payload too long") }
            if buffer.count < PMCP.headerBytes + length { break }
            messages.append((buffer[5], Array(buffer[PMCP.headerBytes..<PMCP.headerBytes + length])))
            buffer.removeFirst(PMCP.headerBytes + length)
        }
        return messages
    }
}
