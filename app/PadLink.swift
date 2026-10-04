// One TCP connection to padd. A reader thread routes replies; calls are thread-safe (client.PadLink in Python).

import Darwin
import Foundation

enum PadError: Error, CustomStringConvertible {
    case busy(String)
    case failed(String)
    case humanHasControl

    var description: String {
        switch self {
        case .busy(let message): return "busy: \(message)"
        case .failed(let message): return message
        case .humanHasControl: return "a human is holding keys in the viewer window; try again when released"
        }
    }
}

func errnoText() -> String { String(cString: strerror(errno)) }

/// Shown when neither PS5_HOST nor --host gave the console's address.
let missingHost = "No console address: set the PS5's IP address in Settings (⌘,), or PS5_HOST / --host."
/// The UserDefaults key for the console address saved in Settings.
let savedHostKey = "consoleHost"

/// TCP connect with a timeout; returns a blocking socket with TCP_NODELAY.
func connectTCP(host: String, port: UInt16, timeout: Double) throws -> Int32 {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                         ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var info: UnsafeMutablePointer<addrinfo>?
    guard !host.isEmpty else { throw PadError.failed(missingHost) }
    let rc = getaddrinfo(host, String(port), &hints, &info)
    guard rc == 0, let addr = info else { throw PadError.failed("cannot resolve \(host): \(String(cString: gai_strerror(rc)))") }
    defer { freeaddrinfo(info) }
    let fd = socket(addr.pointee.ai_family, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else { throw PadError.failed("socket: \(errnoText())") }
    var one: Int32 = 1
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    if connect(fd, addr.pointee.ai_addr, addr.pointee.ai_addrlen) != 0 {
        guard errno == EINPROGRESS else {
            let text = errnoText(); close(fd)
            throw PadError.failed("connect \(host):\(port): \(text)")
        }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, Int32(timeout * 1000))
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        if ready <= 0 || err != 0 {
            close(fd)
            throw PadError.failed("connect \(host):\(port): \(ready <= 0 ? "timed out" : String(cString: strerror(err)))")
        }
    }
    _ = fcntl(fd, F_SETFL, flags)
    return fd
}

final class PadLink {
    let host: String
    let port: UInt16
    private(set) var hello: Hello!
    private let fd: Int32
    private let timeout: Double
    private let sendLock = NSLock()
    private let cond = NSCondition()
    private var acks: [UInt32: Int32] = [:]
    private var replies: [UInt8: [[UInt8]]] = [:]
    private var seq: UInt32 = 0
    private var reader = FrameReader()
    private(set) var closed = false
    private(set) var error: String?

    init(host: String, port: UInt16, timeout: Double = 3.0) throws {
        self.host = host
        self.port = port
        self.timeout = timeout
        fd = try connectTCP(host: host, port: port, timeout: timeout)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var chunk = [UInt8](repeating: 0, count: 4096)
        var messages: [(UInt8, [UInt8])] = []
        do {
            while messages.isEmpty {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { throw PadError.failed(n == 0 ? "padd closed the connection during HELLO" : "HELLO: \(errnoText())") }
                messages = try reader.feed(chunk[0..<n])
            }
        } catch {
            Darwin.close(fd)
            throw error
        }
        let (kind, payload) = messages[0]
        if kind == PMCP.Kind.error.rawValue {
            Darwin.close(fd)
            let (code, message) = decodeError(payload)
            throw code == PMCP.ErrorCode.busy.rawValue ? PadError.busy(message) : PadError.failed(message)
        }
        guard kind == PMCP.Kind.hello.rawValue, payload.count >= 20 else {
            Darwin.close(fd)
            throw PadError.failed("expected HELLO, got type \(kind)")
        }
        hello = decodeHello(payload)
        var none = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
        for message in messages.dropFirst() { dispatch(message.0, message.1) }
        Thread.detachNewThread { self.readLoop() }
        if hello.flags & PMCP.flagUserName != 0 {
            hello.userName = try? getUserName(timeout: 1)
        }
    }

    func nextSeq() -> UInt32 {
        cond.lock(); defer { cond.unlock() }
        seq &+= 1
        return seq
    }

    private func dispatch(_ kind: UInt8, _ payload: [UInt8]) {
        cond.lock()
        defer { cond.broadcast(); cond.unlock() }
        switch PMCP.Kind(rawValue: kind) {
        case .ack where payload.count >= 8:
            let (seq, status) = decodeAck(payload)
            acks[seq] = status
            if acks.count > 512 {  // streamed states are rarely awaited
                for old in acks.keys.sorted().prefix(256) { acks.removeValue(forKey: old) }
            }
        case .error where payload.count >= 4:
            let (code, message) = decodeError(payload)
            error = "\(PMCP.ErrorCode(rawValue: code).map { "\($0)" } ?? String(code)): \(message)"
        default:
            replies[kind, default: []].append(payload)
        }
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                if n < 0 { cond.lock(); error = error ?? errnoText(); cond.unlock() }
                break
            }
            do {
                for (kind, payload) in try reader.feed(chunk[0..<n]) { dispatch(kind, payload) }
            } catch {
                cond.lock(); self.error = self.error ?? "\(error)"; cond.unlock()
                break
            }
        }
        cond.lock()
        closed = true
        cond.broadcast()
        cond.unlock()
    }

    private func send(_ bytes: [UInt8]) throws {
        cond.lock()
        let isClosed = closed, reason = error
        cond.unlock()
        if isClosed { throw PadError.failed(reason ?? "connection closed") }
        sendLock.lock(); defer { sendLock.unlock() }
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 {
                let text = errnoText()
                cond.lock(); closed = true; cond.unlock()
                throw PadError.failed(text)
            }
            offset += n
        }
    }

    private func wait<T>(_ timeout: Double?, _ take: () -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(timeout ?? self.timeout)
        cond.lock(); defer { cond.unlock() }
        while true {
            if let value = take() { return value }
            if closed { throw PadError.failed(error ?? "connection closed") }
            if !cond.wait(until: deadline) { throw PadError.failed("timed out waiting for padd") }
        }
    }

    @discardableResult
    func sendState(_ state: PadState, wait: Bool = false, timeout: Double? = nil) throws -> Int32 {
        let seq = nextSeq()
        try send(encodeState(seq: seq, state))
        return wait ? try waitAck(seq, timeout: timeout) : 0
    }

    func waitAck(_ seq: UInt32, timeout: Double? = nil) throws -> Int32 {
        try wait(timeout) { acks.removeValue(forKey: seq) }
    }

    private func request(_ bytes: [UInt8], reply kind: PMCP.Kind, timeout: Double?) throws -> [UInt8] {
        cond.lock(); replies[kind.rawValue] = nil; cond.unlock()
        try send(bytes)
        return try wait(timeout) {
            guard var list = replies[kind.rawValue], !list.isEmpty else { return nil }
            let first = list.removeFirst()
            replies[kind.rawValue] = list
            return first
        }
    }

    func ping(timeout: Double? = nil) throws -> Pong {
        let reply = try request(encodePing(nextSeq()), reply: .ping, timeout: timeout)
        guard reply.count >= 40 else { throw PadError.failed("short PONG") }
        return decodePong(reply)
    }

    private func getUserName(timeout: Double) throws -> String? {
        let reply = try request(encode(.getUser), reply: .getUser, timeout: timeout)
        guard reply.count == 72 else { throw PadError.failed("invalid GET_USER reply") }
        var cursor = Cursor(data: reply)
        let status = cursor.i32(), userID = cursor.i32()
        guard status == 0, userID == hello.userID else { return nil }
        let name = String(decoding: reply.dropFirst(8).prefix(while: { $0 != 0 }), as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    func getState(timeout: Double? = nil) throws -> PadState {
        decodeState(try request(encode(.getState), reply: .state, timeout: timeout))
    }

    func command(_ op: PMCP.Command, _ arg: String = "", timeout: Double = 10) throws -> Int32 {
        let seq = nextSeq()
        try send(try encodeCommand(seq: seq, op, arg))
        return try waitAck(seq, timeout: timeout)
    }

    private var released = false

    func close() {
        cond.lock()
        closed = true
        let release = !released
        released = true
        cond.broadcast()
        cond.unlock()
        guard release else { return }
        shutdown(fd, SHUT_RDWR)
        // The reader thread sees EOF; the descriptor is released once, after it has stopped reading.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { Darwin.close(self.fd) }
    }
}
