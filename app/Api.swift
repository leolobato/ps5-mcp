// Local API: <state>/capture.sock, JSON lines (docs/app-api.md). A superset of the old ps5-capture control
// socket, so `capture.NativeApp` keeps working unchanged. Requests may carry "id", which every reply echoes;
// pushed events carry "event" instead. Several clients can connect at once.

import Darwin
import Foundation

let apiVersion = 1
let maxHoldMS = 10_000
/// The PS5 drops a press that follows a release too closely, so every press ends with this much neutral.
let releaseGapSeconds = 0.06

func bindUnix(_ path: String) -> Int32 {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        say("socket path too long (\(path.utf8.count) bytes): \(path)")
        return -1
    }
    _ = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        path.withCString { strncpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, raw.count - 1) }
    }
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
        say("control socket failed: \(errnoText())")
        close(fd)
        return -1
    }
    return fd
}

final class Connection {
    let fd: Int32
    let id: Int
    private let writeLock = NSLock()
    private let lock = NSLock()
    private var layers = Set<String>()
    private var events = Set<String>()
    var keys: KeyInput!

    init(fd: Int32, id: Int) {
        self.fd = fd
        self.id = id
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else {
            say("unserialisable reply: \(object)")
            return
        }
        data.append(0x0A)
        writeLock.lock(); defer { writeLock.unlock() }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    /// The agent layer for `client` (a connection may speak for several named clients).
    func layer(_ client: String?) -> String {
        let name = "\(id):\(client ?? "default")"
        lock.lock(); layers.insert(name); lock.unlock()
        return name
    }

    func allLayers() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return layers
    }

    func subscribe(_ names: [String]) { lock.lock(); events.formUnion(names); lock.unlock() }
    func wants(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return events.contains(name) }
}

struct ApiError: Error {
    let code: String
    let message: String
}

extension Hub {
    func serveApi() {
        let fd = bindUnix(socketPath)
        guard fd >= 0 else { exit(3) }
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                let connection = self.register(client)
                Thread.detachNewThread { self.serve(connection) }
            }
        }
    }

    private func serve(_ conn: Connection) {
        defer { unregister(conn) }
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(conn.fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer += chunk[0..<n]
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[0..<newline])
                buffer.removeSubrange(0...newline)
                guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let cmd = request["cmd"] as? String else {
                    conn.send(["ok": false, "error": "bad request", "code": "bad_request"])
                    continue
                }
                handle(cmd, request, conn)
            }
        }
    }

    private func reply(_ conn: Connection, _ request: [String: Any], _ body: [String: Any]) {
        var body = body
        if let id = request["id"] { body["id"] = id }
        conn.send(body)
    }

    private func fail(_ conn: Connection, _ request: [String: Any], _ error: Error) {
        let (code, message): (String, String)
        switch error {
        case let error as ApiError: (code, message) = (error.code, error.message)
        case PadError.humanHasControl: (code, message) = ("human_has_control", "\(error)")
        case let error as BadInput: (code, message) = ("bad_request", error.description)
        default: (code, message) = ("pad_error", "\(error)")
        }
        reply(conn, request, ["ok": false, "error": message, "code": code])
    }

    /// Quick commands run in order on the connection's thread; blocking ones run concurrently.
    private func handle(_ cmd: String, _ request: [String: Any], _ conn: Connection) {
        let blocking: Set<String> = ["press", "status", "watch_change", "command", "ping", "padd_start", "padd_stop", "snapshot"]
        lease.touch(conn: conn.id)
        let work = {
            do {
                try self.run(cmd, request, conn)
            } catch {
                self.fail(conn, request, error)
            }
        }
        if blocking.contains(cmd) { DispatchQueue.global().async(execute: work) } else { work() }
    }

    private func state(_ request: [String: Any]) throws -> PadState {
        guard let json = request["state"] as? [String: Any] else { throw BadInput("missing state") }
        return try PadState(json: json)
    }

    /// Agent input needs a live link (waits up to `wait` s, as the Python server did before every tool).
    private func requireLink(_ request: [String: Any], default wait: Double) throws -> PadLink {
        do {
            return try controller.currentLink(wait: request["wait"] as? Double ?? wait)
        } catch {
            throw ApiError(code: "not_connected", message: "\(error)")
        }
    }

    private func run(_ cmd: String, _ request: [String: Any], _ conn: Connection) throws {
        switch cmd {
        case "status":
            if let wait = request["wait"] as? Double { _ = try? controller.currentLink(wait: wait) }
            reply(conn, request, status())
        case "snapshot":
            reply(conn, request, ["ok": sink.writeNow(), "path": stateDir + "/latest.jpg"])
        case "show", "hide":
            DispatchQueue.main.async { self.ui?.setVisible(cmd == "show") }
            reply(conn, request, ["ok": true])
        case "watch_change":
            // Arms change detection; answers twice: once armed, then when the frame changes or after `timeout_s`.
            let threshold = request["threshold"] as? Double ?? 6.0
            let timeout = request["timeout_s"] as? Double ?? 2.0
            let done = DispatchSemaphore(value: 0)
            var result: [String: Any] = ["ok": false, "error": "timeout"]
            let armedAt = uptimeSeconds()
            sink.watch(threshold: threshold) { at, diff in
                result = ["ok": true, "changed_at": at, "diff": diff]
                done.signal()
            }
            reply(conn, request, ["ok": true, "armed_at": armedAt])
            if done.wait(timeout: .now() + timeout) == .timedOut { sink.cancelWatch() }
            reply(conn, request, result)
        case "quit":
            reply(conn, request, ["ok": true])
            DispatchQueue.main.async { self.quit() }
        case "set":
            let state = try state(request)
            if !state.isNeutral {
                try lease.check(conn: conn.id)
                _ = try requireLink(request, default: 0)
            }
            try controller.set(client: conn.layer(request["client"] as? String), state)
            reply(conn, request, ["ok": true])
        case "press":
            let state = try state(request)
            let holdMS = request["hold_ms"] as? Int ?? 80
            guard holdMS > 0 && holdMS <= maxHoldMS else { throw BadInput("duration must be 1..\(maxHoldMS) ms") }
            try lease.check(conn: conn.id)
            _ = try requireLink(request, default: 2)
            let layer = conn.layer(request["client"] as? String)
            try controller.set(client: layer, state)
            Thread.sleep(forTimeInterval: Double(holdMS) / 1000)
            controller.release(client: layer)
            Thread.sleep(forTimeInterval: releaseGapSeconds)
            reply(conn, request, ["ok": true])
        case "release":
            controller.release(client: conn.layer(request["client"] as? String))
            reply(conn, request, ["ok": true])
        case "release_all":
            controller.releaseAll()
            reply(conn, request, ["ok": true])
        case "key":
            guard let key = request["key"] as? String else { throw BadInput("missing key") }
            guard conn.keys.handle(key, down: request["down"] as? Bool ?? false) else {
                throw BadInput("unmapped key '\(key)'")
            }
            reply(conn, request, ["ok": true])
        case "state":
            let current = controller.current()
            reply(conn, request, ["ok": true, "state": current.merged.json, "keys_held": current.keys,
                                  "agents": current.agents.mapValues { $0.json }])
        case "command":
            let op = request["op"] as? String ?? ""
            let arg = request["arg"] as? String ?? ""
            try lease.check(conn: conn.id)
            let status = try command(op, arg, link: requireLink(request, default: 2))
            reply(conn, request, ["ok": true, "status": Int(status)])
        case "ping":
            let pong = try requireLink(request, default: 2).ping()
            reply(conn, request, ["ok": true, "pong": pong.json])
        case "subscribe":
            let names = request["events"] as? [String] ?? ["status", "state"]
            conn.subscribe(names)
            reply(conn, request, ["ok": true, "events": names])
            if names.contains("status") { conn.send(["event": "status"].merging(status()) { a, _ in a }) }
        case "padd_start", "padd_stop":
            try lease.check(conn: conn.id)
            let action = cmd == "padd_start" ? "start" : "stop"
            reply(conn, request, try padd.run(action, firmware: request["firmware"] as? String))
        case "claim":
            let client = request["client"] as? String ?? "default"
            let reason = request["reason"] as? String ?? ""
            let idle = request["idle_s"] as? Double ?? Lease.defaultIdle
            reply(conn, request, lease.claim(conn: conn.id, client: client, reason: reason, idle: idle))
        case "unclaim":
            let had = lease.unclaim(conn: conn.id)
            reply(conn, request, lease.view(conn: conn.id).merging(["released": had]) { a, _ in a })
        case "lease":
            reply(conn, request, lease.view(conn: conn.id))
        default:
            throw ApiError(code: "unknown_cmd", message: "unknown cmd")
        }
    }
}
