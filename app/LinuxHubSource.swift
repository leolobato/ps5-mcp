// A Linux hub (docs/linux.md) on another machine as this app's picture. The Linux hub owns the capture card, the
// padd link and the claims; this app shows its live view and status, and keeps its own padd link closed.
//
// Reached over SSH: one master connection forwards the hub's control socket and its loopback MJPEG viewer to Unix
// sockets in this app's state directory. A target that is an absolute path is a hub's capture.sock on this Mac
// (tests): its viewer is then reached on 127.0.0.1 directly.

import CoreGraphics
import Foundation
import ImageIO

struct LinuxHubStatus {
    enum Phase: String { case connecting, streaming, reconnecting, stopped }
    var phase = Phase.connecting
    var issue: String?
    /// The Linux hub's own `status` reply, as last read.
    var remote: [String: Any]?
    /// Its `lease` reply (who holds the console there), as last read.
    var lease: [String: Any]?

    var json: [String: Any] {
        ["state": phase.rawValue, "error": issue as Any? ?? NSNull(), "status": remote as Any? ?? NSNull()]
    }
}

final class LinuxHubSource: FrameSource {
    let name: String
    let target: String
    private let sink: FrameSink
    private let stateDir: String
    private let lock = NSLock()
    private var stopped = false
    /// Signalled when `run` has cleaned up, so a new source cannot have its sockets unlinked by this one.
    private let finished = DispatchSemaphore(value: 0)
    private var started = false
    private var master: Process?
    private var stream: Int32 = -1
    private var current = LinuxHubStatus()
    /// The window's keys: one connection of their own, so the hub lets them go if it ends.
    private var humanLink: LinuxHubUpstream?
    /// Counts connections, so a status poller from an earlier one stops.
    private var generation = 0
    var onStatus: ((LinuxHubStatus) -> Void)?

    static let prefix = "linux:"
    static let ssh = "/usr/bin/ssh"

    init(target: String, stateDir: String, sink: FrameSink) {
        self.target = target
        self.stateDir = stateDir
        self.sink = sink
        name = Self.prefix + target
    }

    var status: LinuxHubStatus { lock.lock(); defer { lock.unlock() }; return current }
    var json: [String: Any] { var body = status.json; body["target"] = target; return body }

    private var direct: Bool { target.hasPrefix("/") }
    /// Names its sockets apart from any other source's, so a source that is slow to stop cannot remove a newer one's.
    private let token = String(UInt32.random(in: 0..<UInt32.max), radix: 36)
    private var hubSocket: String { direct ? target : stateDir + "/linux-hub-\(token).sock" }
    private var viewSocket: String { stateDir + "/linux-view-\(token).sock" }
    private var control: String { stateDir + "/linux-ssh-\(token).ctl" }

    func start() {
        lock.lock(); started = true; lock.unlock()
        Thread.detachNewThread { self.run(); self.finished.signal() }
    }

    func stop() {
        lock.lock()
        let running = started && !stopped
        stopped = true
        let fd = stream, process = master
        lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        if let process, process.isRunning { process.terminate() }
        // Its sockets have fixed names: the next source (or the next launch) reuses them.
        if running && finished.wait(timeout: .now() + 5) == .timedOut { say("Linux hub \(target): still stopping") }
    }

    func setMuted(_ muted: Bool) {}

    /// The Linux hub's control socket while it streams (forwarded over SSH, or the hub's own on this Mac).
    var apiSocket: String? { status.phase == .streaming ? hubSocket : nil }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func publish(_ change: (inout LinuxHubStatus) -> Void) {
        lock.lock()
        change(&current)
        let now = current
        lock.unlock()
        onStatus?(now)
    }

    private func run() {
        var backoff = 1.0
        while !isStopped {
            var streamed = false
            do {
                let viewer = try connect()
                publish { $0.phase = .streaming; $0.issue = nil }
                lock.lock(); generation += 1; let mine = generation; lock.unlock()
                let poller = Thread { [weak self] in self?.pollStatus(mine) }
                poller.start()
                streamed = try read(viewer)
            } catch {
                if !isStopped {
                    let message = (error as? BadInput)?.description ?? "\(error)"
                    say("Linux hub \(target): \(message)")
                    publish { $0.phase = .reconnecting; $0.issue = message }
                }
            }
            disconnect()
            sink.clear()
            if streamed { backoff = 1 }
            var waited = 0.0
            while waited < backoff && !isStopped { usleep(100_000); waited += 0.1 }
            backoff = min(backoff * 2, 15)
        }
        publish { $0.phase = .stopped }
    }

    /// Where to read the MJPEG stream: a forwarded Unix socket, or 127.0.0.1:port for a hub on this Mac.
    private enum Viewer { case unix(String), tcp(UInt16) }

    private func connect() throws -> Viewer {
        if !direct {
            try startMaster()
            let state = try sshOutput(#"printf %s "${PS5MCP_STATE:-$HOME/.local/state/ps5-mcp}""#)
            guard state.hasPrefix("/") else { throw BadInput("cannot find the Linux hub's state directory (got \(state))") }
            unlink(hubSocket)
            try forward(local: hubSocket, remote: state + "/capture.sock")
        }
        let status = try hubStatus()
        try takePadd()
        guard let url = status["viewer_url"] as? String, let port = URLComponents(string: url)?.port,
              let port16 = UInt16(exactly: port) else {
            throw BadInput("the Linux hub has no live view (viewer_url is empty)")
        }
        if direct { return .tcp(port16) }
        unlink(viewSocket)
        try forward(local: viewSocket, remote: "127.0.0.1:\(port16)")
        return .unix(viewSocket)
    }

    private func hubStatus() throws -> [String: Any] {
        guard let line = askRunningApp(hubSocket, #"{"cmd":"status"}"#),
              let data = line.data(using: .utf8),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BadInput(direct ? "no Linux hub answers at \(target)"
                : "no Linux hub answers on \(target); start it there with `ps5mcp capture start`")
        }
        guard reply["ok"] as? Bool != false else {
            throw BadInput("the Linux hub refused status: \(reply["error"] as? String ?? "unknown error")")
        }
        publish { $0.remote = reply }
        return reply
    }

    /// One request to the hub on its own connection, for longer than `status` takes.
    private func ask(_ cmd: String, timeout: Double, _ fields: [String: Any] = [:]) throws -> [String: Any] {
        let fd = try connectUnix(hubSocket)
        defer { close(fd) }
        var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var body = fields
        body["cmd"] = cmd
        body["client"] = "PS5 MCP window"
        var request = try JSONSerialization.data(withJSONObject: body)
        request.append(0x0A)
        let sent = request.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
        guard sent == request.count else { throw BadInput("the Linux hub closed") }
        var reader = LineReader(fd: fd)
        let line = try reader.line()
        guard let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw BadInput("the Linux hub sent no reply")
        }
        guard reply["ok"] as? Bool == true else { throw BadInput(reply["error"] as? String ?? "refused") }
        return reply
    }

    /// The hub may have handed padd to this Mac earlier (`padd_release`): this Mac has let go now, so it takes it back.
    private func takePadd() throws {
        do {
            _ = try ask("padd_take", timeout: 5)
        } catch let error as BadInput where error.description.contains("offline") || error.description.contains("does not support") {
            say("Linux hub \(target): \(error.description)")  // no console access there, or an older hub
        }
    }

    /// Before this Mac takes padd back: the hub drops its link and stays off it, even if it restarts, until a later
    /// connection here takes it again. Nil when done, else why not.
    func releasePadd() -> String? {
        guard apiSocket != nil else { return "the Linux hub is not connected" }
        do { _ = try ask("padd_release", timeout: 8); return nil }
        catch { return (error as? BadInput)?.description ?? "\(error)" }
    }

    /// The keys a person holds in this app's window (nil: none). Like this app's own keyboard, they need no claim and
    /// keep agents out while held. Sends without waiting: a key that cannot reach the hub is not held there either.
    func human(_ state: PadState?) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, current.phase == .streaming else { return }
        if humanLink == nil {
            guard state != nil else { return }
            humanLink = try? LinuxHubUpstream(path: hubSocket, onLine: { _ in }, onLost: { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.humanLink = nil; self.lock.unlock()
            })
        }
        let body: [String: Any] = ["cmd": "human", "client": "PS5 MCP window", "state": state?.json ?? NSNull()]
        guard let line = try? JSONSerialization.data(withJSONObject: body) else { return }
        if (try? humanLink?.send(line)) == nil { humanLink?.close(); humanLink = nil }
    }

    /// A console command from this app's window (home, close, launch, uninstall), as one client of the hub: refused
    /// while an agent holds the console there.
    func command(_ op: String, _ arg: String) throws -> Int32 {
        guard apiSocket != nil else { throw BadInput("the Linux hub is not connected") }
        let reply = try ask("command", timeout: 20, ["op": op, "arg": arg, "wait": 2])
        guard let status = reply["status"] as? Int else { throw BadInput("the Linux hub sent no status") }
        return Int32(truncatingIfNeeded: status)
    }

    private func pollStatus(_ mine: Int) {
        func current() -> Bool { lock.lock(); defer { lock.unlock() }; return !stopped && generation == mine }
        while current(), status.phase == .streaming {
            _ = try? hubStatus()
            if let lease = try? ask("lease", timeout: 2) { publish { $0.lease = lease } }
            for _ in 0..<20 where current() { usleep(100_000) }
        }
    }

    // MARK: SSH

    /// PS5MCP_SSH_CONFIG: an ssh config file to use instead of ~/.ssh/config (tests).
    private func sshArguments(_ extra: [String], control: String? = nil) -> [String] {
        let config = ProcessInfo.processInfo.environment["PS5MCP_SSH_CONFIG"].map { ["-F", $0] } ?? []
        return config + ["-S", control ?? self.control, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"] + extra + ["--", target]
    }

    private func startMaster() throws {
        guard !target.hasPrefix("-"), target.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw BadInput("not an SSH destination: \(target)")
        }
        cleanUpStale()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.ssh)
        process.arguments = ["-M", "-N", "-o", "ControlPersist=no", "-o", "ServerAliveInterval=5",
                             "-o", "ServerAliveCountMax=3", "-o", "ExitOnForwardFailure=yes",
                             "-o", "StreamLocalBindUnlink=yes"] + sshArguments([])
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        lock.lock()
        guard !stopped else { lock.unlock(); throw BadInput("stopped") }
        master = process
        lock.unlock()
        try process.run()
        let deadline = uptimeSeconds() + 20
        while uptimeSeconds() < deadline && !isStopped {
            if !process.isRunning {
                let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var hint = ""
                if text.contains("Host key verification failed") {
                    hint = " Connect once with `ssh \(target)` in Terminal to trust its host key."
                } else if text.contains("Permission denied") {
                    hint = " The app signs in with your SSH keys or agent, without prompting; set up key login first."
                }
                throw BadInput("ssh \(target) failed: \(text.isEmpty ? "exit \(process.terminationStatus)" : text)\(hint)")
            }
            if (try? runSSH(["-O", "check"])) != nil { return }
            usleep(200_000)
        }
        throw BadInput("ssh \(target) did not connect within 20 s")
    }

    /// Sockets and masters other sources left (an app that crashed, or a source still stopping): their forwards are
    /// dead or about to be, and a master that outlived its app would hold an SSH connection open for nothing.
    private func cleanUpStale() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: stateDir)) ?? []
        for name in names where name.hasPrefix("linux-") && !name.contains("-\(token).") {
            let path = stateDir + "/" + name
            if name.hasPrefix("linux-ssh-") && name.hasSuffix(".ctl") {
                _ = try? runSSH(["-O", "exit"], control: path)
            }
            if name.hasSuffix(".sock") || name.hasSuffix(".ctl") { unlink(path) }
        }
    }

    private func forward(local: String, remote: String) throws {
        _ = try runSSH(["-O", "forward", "-L", "\(local):\(remote)"])
    }

    private func sshOutput(_ command: String) throws -> String {
        try runSSH([], command: command)
    }

    /// Runs ssh over the master connection; throws with its stderr when it fails.
    /// Every call ends within 20 s: a stalled network cannot keep `stop` waiting.
    @discardableResult
    private func runSSH(_ options: [String], command: String? = nil, control: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.ssh)
        process.arguments = sshArguments(options, control: control) + (command.map { [$0] } ?? [])
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let problem = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: problem, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BadInput(text.isEmpty ? "ssh exited with \(process.terminationStatus)" : text)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func disconnect() {
        lock.lock()
        let process = master, fd = stream, keys = humanLink
        master = nil
        stream = -1
        humanLink = nil
        lock.unlock()
        keys?.close()
        if fd >= 0 { close(fd) }
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        if !direct {
            unlink(hubSocket)
            unlink(viewSocket)
            unlink(control)
        }
    }

    // MARK: MJPEG

    private func open(_ viewer: Viewer) throws -> Int32 {
        let fd: Int32
        switch viewer {
        case .unix(let path):
            fd = try connectUnix(path)
        case .tcp(let port):
            fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == 0 else { close(fd); throw BadInput("cannot open the live view on port \(port)") }
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // A stalled stream counts as lost after this long.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// Streams frames into the sink until the stream ends. True when at least one frame arrived.
    private func read(_ viewer: Viewer) throws -> Bool {
        let fd = try open(viewer)
        lock.lock()
        guard !stopped else { lock.unlock(); close(fd); return false }
        stream = fd
        lock.unlock()
        let request = Array("GET /stream.mjpg HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
        guard write(fd, request, request.count) == request.count else { throw BadInput("the live view closed") }
        var reader = LineReader(fd: fd)
        let head = try reader.headers()
        guard head.first?.contains(" 200 ") == true else {
            throw BadInput("the Linux hub's live view answered \(head.first ?? "nothing"): is its capture running?")
        }
        var frames = 0
        while !isStopped {
            let part = try reader.headers()
            guard let length = part.lazy.compactMap({ line -> Int? in
                let pieces = line.split(separator: ":", maxSplits: 1)
                guard pieces.count == 2, pieces[0].lowercased() == "content-length" else { return nil }
                return Int(pieces[1].trimmingCharacters(in: .whitespaces))
            }).first, length > 0, length < 32 << 20 else { continue }
            let jpeg = try reader.bytes(length)
            guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            sink.push(render(image))
            frames += 1
        }
        return frames > 0
    }
}

func connectUnix(_ path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw BadInput("no socket") }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        close(fd); throw BadInput("socket path too long: \(path)")
    }
    _ = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        path.withCString { strncpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, raw.count - 1) }
    }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { close(fd); throw BadInput("cannot connect to \(path)") }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

/// One local API client's own connection to the Linux hub, so the hub's claims and input layers are per client as
/// they are here. Requests go up as they came; every line the hub sends (replies, events) comes back unchanged.
final class LinuxHubUpstream {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private var fdClosed = false

    /// `onLine` gets each line without its newline; `onLost` runs once if the hub side ends first. The reader keeps
    /// the object alive until the socket ends, and closes it.
    init(path: String, onLine: @escaping (Data) -> Void, onLost: @escaping () -> Void) throws {
        fd = try connectUnix(path)
        let fd = fd
        Thread.detachNewThread { [self] in
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = Darwin.read(fd, &chunk, chunk.count)
                if count <= 0 { break }
                buffer.append(contentsOf: chunk[0..<count])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    onLine(Data(buffer[buffer.startIndex..<newline]))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
            self.lock.lock()
            let lost = !self.closed
            self.closed = true
            self.fdClosed = true
            Darwin.close(fd)
            self.lock.unlock()
            if lost { onLost() }
        }
    }

    func send(_ line: Data) throws {
        var data = line
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw BadInput("the Linux hub connection closed") }
        let sent = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard sent else { throw BadInput("the Linux hub connection closed") }
    }

    /// Ends this client's session on the hub (its claim and held input go with it).
    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        if !fdClosed { shutdown(fd, SHUT_RDWR) }
    }
}

/// Buffered reads of HTTP header blocks and fixed-size bodies from a blocking socket.
struct LineReader {
    let fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }

    private mutating func fill() throws {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &chunk, chunk.count)
        guard count > 0 else { throw BadInput(count == 0 ? "the live view ended" : "the live view stalled") }
        buffer.append(contentsOf: chunk[0..<count])
    }

    /// The lines up to the next empty line, skipping blank lines before them (the CRLF after a part's body).
    mutating func headers() throws -> [String] {
        let end = Data("\r\n\r\n".utf8)
        while true {
            while buffer.starts(with: Data("\r\n".utf8)) { buffer.removeFirst(2) }
            if let range = buffer.range(of: end) {
                let block = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return block.components(separatedBy: "\r\n")
            }
            guard buffer.count < 65536 else { throw BadInput("the live view sent an oversized header") }
            try fill()
        }
    }

    /// One line, without its newline.
    mutating func line() throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            guard buffer.count < 1 << 20 else { throw BadInput("oversized reply") }
            try fill()
        }
    }

    mutating func bytes(_ count: Int) throws -> Data {
        while buffer.count < count { try fill() }
        let body = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(body)
    }
}
