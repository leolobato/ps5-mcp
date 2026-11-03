import AVFoundation
import Foundation

// Only with PBS=1 (make app PBS=1): the PBS payload is an optional video source, off in a normal build.
#if PS5MCP_PBS

/// What the PBS source is doing. PBS is loaded on the console by the user; the app only connects to it.
struct PBSStatus {
    enum Phase: String { case connecting, streaming, reconnecting, stopped }
    var phase = Phase.connecting
    var issue: String?
    var videoReady = false
    var audioReady = false
    var width = 0
    var height = 0
    var reconnects = 0

    var summary: String { issue ?? (phase == .streaming ? "PBS is streaming." : "") }
    var json: [String: Any] {
        ["state": phase.rawValue, "error": issue as Any? ?? NSNull(), "video_ready": videoReady, "audio_ready": audioReady,
         "width": width, "height": height, "reconnects": reconnects]
    }
}

/// One HTTP/1.1 request over a blocking socket. `cancel` may run on another thread and unblocks the reader. The
/// descriptor closes only with the object: a reader inside `recv` keeps it alive, so its number cannot be reused.
final class PBSConnection {
    private let host: String
    private let port: Int
    private let method: String
    private let path: String
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false
    private var pending = Data()
    /// A stalled stream counts as lost after this long, which also bounds how long a read can block.
    static let readTimeout = 3.0

    /// Does no I/O, so an owner can register the connection before `open` and cancel it at any point.
    init(host: String, port: Int, method: String = "GET", path: String) {
        self.host = host
        self.port = port
        self.method = method
        self.path = path
    }

    /// A connection that is not shared: opens it and returns it on success.
    static func perform(host: String, port: Int, method: String = "GET", path: String) -> PBSConnection? {
        let connection = PBSConnection(host: host, port: port, method: method, path: path)
        return connection.open() ? connection : nil
    }

    deinit { if fd >= 0 { close(fd) } }

    /// Connects, sends the request and reads the reply's headers. False on failure, including after `cancel`.
    func open() -> Bool {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(list) }
        let socket = Darwin.socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard socket >= 0 else { return false }
        lock.lock()
        guard !cancelled else { lock.unlock(); close(socket); return false }
        fd = socket
        lock.unlock()
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(socket, F_GETFL, 0)
        _ = fcntl(socket, F_SETFL, flags | O_NONBLOCK)
        if connect(socket, first.pointee.ai_addr, first.pointee.ai_addrlen) != 0 {
            guard errno == EINPROGRESS else { return false }
            var waiter = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard poll(&waiter, 1, 2000) == 1, getsockopt(socket, SOL_SOCKET, SO_ERROR, &failure, &size) == 0,
                  failure == 0 else { return false }
        }
        _ = fcntl(socket, F_SETFL, flags)
        var timeout = timeval(tv_sec: Int(Self.readTimeout), tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let request = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        return request.withCString({ send(socket, $0, strlen($0), 0) }) > 0 && readHeaders()
    }

    /// Ends the connection; a blocked read returns at once, and later ones fail.
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    private func fill() -> Bool {
        lock.lock(); let socket = cancelled ? -1 : fd; lock.unlock()
        guard socket >= 0 else { return false }
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        let count = recv(socket, &chunk, chunk.count, 0)
        guard count > 0 else { return false }
        pending.append(contentsOf: chunk[..<count])
        return true
    }

    private func readHeaders() -> Bool {
        let end = Data("\r\n\r\n".utf8)
        while pending.range(of: end) == nil {
            guard pending.count < 16 * 1024, fill() else { return false }
        }
        let range = pending.range(of: end)!
        let head = String(decoding: pending[pending.startIndex..<range.lowerBound], as: UTF8.self)
        pending = Data(pending[range.upperBound...])
        return head.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first == "200"
    }

    /// Exactly `count` bytes, or nil when the stream ends, stalls or is cancelled.
    func read(_ count: Int) -> Data? {
        while pending.count < count { guard fill() else { return nil } }
        let result = Data(pending.prefix(count))
        pending = Data(pending.dropFirst(count))
        return result
    }

    /// The rest of the body, up to `limit` bytes (for short replies that end with the connection).
    func readToEnd(limit: Int) -> Data? {
        while pending.count <= limit { guard fill() else { break } }
        return pending.count <= limit ? pending : nil
    }

    /// One PBS media packet: big-endian length, big-endian timestamp, payload.
    func readPacket(limit: Int) -> Data? {
        guard let header = read(8) else { return nil }
        let length = header.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= limit else { return nil }
        return read(length)
    }
}

/// Video and audio from the PBS payload's HTTP service. Each stream has a reader thread; decoding is serialized on
/// `media`, and readers wait for it, so a slow decoder slows the socket instead of queuing frames.
final class PBSSource: FrameSource {
    let name = "pbs"
    static let defaultPort = 9999
    private static let maxVideoPacket = 8 * 1024 * 1024
    private static let maxAudioPacket = 1024 * 1024

    private let port: Int
    private let managerPort: Int
    private let sink: FrameSink
    private let media = DispatchQueue(label: "pbs.media", qos: .userInteractive)
    private let lock = NSLock()
    private let wake = NSCondition()
    private var host: String
    private var generation = 0
    private var running = false
    private var connections: [PBSConnection] = []
    private var statusValue = PBSStatus()
    private var lastKeyframeRequest = 0.0

    var onStatus: ((PBSStatus) -> Void)?
    /// Completion releases the old recording timeline; the reader reconnects after it.
    var onStreamLost: ((@escaping () -> Void) -> Void)?

    private lazy var decoder = RemotePlayDecoder { [weak self] buffer, time in
        guard let self else { return }
        self.sink.push(buffer, at: time)
        self.lock.lock()
        let first = !self.statusValue.videoReady
        self.statusValue.videoReady = true
        self.statusValue.phase = .streaming
        self.statusValue.issue = nil
        self.statusValue.width = CVPixelBufferGetWidth(buffer)
        self.statusValue.height = CVPixelBufferGetHeight(buffer)
        self.lock.unlock()
        if first { self.notifyStatus() }
    }
    private lazy var audio = RemotePlayAudio { [weak self] sample in
        guard let self else { return }
        self.sink.push(audio: sample)
        self.lock.lock()
        let first = !self.statusValue.audioReady
        self.statusValue.audioReady = true
        self.lock.unlock()
        if first { self.notifyStatus() }
    }

    init(host: String, port: Int, sink: FrameSink, managerPort: Int = 8084) {
        self.host = host
        self.port = port
        self.managerPort = managerPort
        self.sink = sink
        _ = decoder
        _ = audio
    }

    var status: PBSStatus { lock.lock(); defer { lock.unlock() }; return statusValue }
    var json: [String: Any] { status.json }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        generation += 1
        let token = generation
        statusValue = PBSStatus()
        lock.unlock()
        notifyStatus()
        Thread.detachNewThread { [self] in videoLoop(token) }
        Thread.detachNewThread { [self] in audioLoop(token) }
    }

    func stop() {
        lock.lock()
        running = false
        generation += 1
        let open = connections
        connections = []
        statusValue.phase = .stopped
        statusValue.issue = nil
        statusValue.videoReady = false
        statusValue.audioReady = false
        lock.unlock()
        open.forEach { $0.cancel() }
        wakeWaiters()
        media.sync {
            decoder.reset()
            audio.reset()
        }
        sink.clear()
    }

    func setMuted(_ muted: Bool) { audio.setMuted(muted) }

    /// Follows a new console address; the readers notice the closed streams and reconnect.
    func setHost(_ host: String) {
        lock.lock()
        self.host = host
        let open = connections
        connections = []
        lock.unlock()
        open.forEach { $0.cancel() }
        wakeWaiters()
    }

    /// Drops the current streams and connects again, without touching the payload.
    func reconnect() { setHost(currentHost()) }

    /// Asks PBS to stop capturing and exit, as the button on its own page does. `done` runs on the main queue;
    /// false means PBS did not answer, usually because it is not running.
    func stopPayload(done: @escaping (Bool) -> Void) {
        let host = currentHost(), port = port
        DispatchQueue.global(qos: .userInitiated).async {
            let answered = PBSConnection.perform(host: host, port: port, method: "POST", path: "/stop") != nil
            DispatchQueue.main.async { done(answered) }
        }
    }

    enum LoadResult: Equatable { case started(String), notInLibrary, unreachable }

    /// The newest PS5 build in a Payload Manager library listing, by version-aware name order.
    static func libraryPayload(_ paths: [String]) -> String? {
        paths.filter {
            let name = ($0 as NSString).lastPathComponent.lowercased()
            return name.hasPrefix("pbs-payload") && name.hasSuffix(".elf") && !name.contains("-ps4")
        }.max { ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
    }

    /// Starts the copy of PBS the user added to Payload Manager's library; the app does not carry one.
    /// The readers connect by themselves once it is up. `done` runs on the main queue.
    func loadPayload(done: @escaping (LoadResult) -> Void) {
        let host = currentHost(), manager = managerPort
        DispatchQueue.global(qos: .userInitiated).async {
            let result: LoadResult
            if let listing = PBSConnection.perform(host: host, port: manager, path: "/list_payloads")?.readToEnd(limit: 1024 * 1024),
               let object = (try? JSONSerialization.jsonObject(with: listing)) as? [String: Any],
               let paths = object["payloads"] as? [String] {
                if let path = Self.libraryPayload(paths) {
                    let quoted = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                    let started = PBSConnection.perform(host: host, port: manager, path: "/loadpayload:" + quoted) != nil
                    result = started ? .started((path as NSString).lastPathComponent) : .unreachable
                } else {
                    result = .notInLibrary
                }
            } else {
                result = .unreachable
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    // MARK: readers

    private func alive(_ token: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return running && generation == token }
    private func currentHost() -> String { lock.lock(); defer { lock.unlock() }; return host }

    private func wakeWaiters() { wake.lock(); wake.broadcast(); wake.unlock() }

    /// Sleeps, but returns as soon as the source stops or the address changes.
    private func pause(_ seconds: Double) {
        wake.lock()
        _ = wake.wait(until: Date().addingTimeInterval(seconds))
        wake.unlock()
    }

    /// Registered with the current address in one step, before any I/O: `stop` and `setHost` can then cancel it at
    /// every stage, and it can never outlive a change of address.
    private func open(_ path: String, token: Int) -> PBSConnection? {
        lock.lock()
        guard running, generation == token else { lock.unlock(); return nil }
        let connection = PBSConnection(host: host, port: port, path: path)
        connections.append(connection)
        lock.unlock()
        if connection.open() { return connection }
        forget(connection)
        return nil
    }

    private func forget(_ connection: PBSConnection) {
        connection.cancel()
        lock.lock(); connections.removeAll { $0 === connection }; lock.unlock()
    }

    private struct Configuration {
        var sps: Data
        var pps: Data
        var audioCodec: String?
        var audioChannels = 0
        var audioRate = 0
    }

    private static func hex(_ text: String?) -> Data? {
        guard let text, !text.isEmpty, text.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private func configuration(_ token: Int) -> Configuration? {
        guard let connection = open("/config.json", token: token) else { return nil }
        defer { forget(connection) }
        guard let body = connection.readToEnd(limit: 64 * 1024),
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let sps = Self.hex(object["sps"] as? String), let pps = Self.hex(object["pps"] as? String) else { return nil }
        var result = Configuration(sps: sps, pps: pps)
        if let audio = object["audio"] as? [String: Any] {
            result.audioCodec = audio["codec"] as? String
            result.audioChannels = audio["channels"] as? Int ?? 0
            result.audioRate = audio["rate"] as? Int ?? 0
        }
        return result
    }

    private func videoLoop(_ token: Int) {
        var delivered = false
        while alive(token) {
            let waiting = "Waiting for PBS at \(currentHost()):\(port). Load the PBS payload on the console."
            guard let config = configuration(token), let stream = open("/frames", token: token) else {
                publish(delivered ? .reconnecting : .connecting, issue: waiting)
                pause(2)
                continue
            }
            let start = Data([0, 0, 0, 1])
            media.sync {
                decoder.reset()
                _ = decoder.submit(start + config.sps + start + config.pps, at: CMClockGetTime(CMClockGetHostTimeClock()))
            }
            while alive(token), let packet = stream.readPacket(limit: Self.maxVideoPacket) {
                let accepted = media.sync { () -> Bool in
                    guard alive(token) else { return true }
                    return decoder.submit(packet, at: CMClockGetTime(CMClockGetHostTimeClock()))
                }
                if !accepted { requestKeyframe() }
                if status.videoReady { delivered = true }
            }
            forget(stream)
            guard alive(token) else { return }
            streamLost(token, delivered: delivered, issue: waiting)
            pause(1)
        }
    }

    /// Ends the media timeline before reconnecting, so a recording is saved instead of spanning the gap.
    private func streamLost(_ token: Int, delivered: Bool, issue: String) {
        media.sync {
            decoder.reset()
            audio.reset()
        }
        lock.lock()
        statusValue.videoReady = false
        statusValue.audioReady = false
        statusValue.width = 0
        statusValue.height = 0
        statusValue.phase = delivered ? .reconnecting : .connecting
        statusValue.issue = issue
        if delivered { statusValue.reconnects += 1 }
        lock.unlock()
        sink.clear()
        notifyStatus()
        guard delivered else { return }
        let saved = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [weak self] in
            guard let self, let onStreamLost = self.onStreamLost else { saved.signal(); return }
            onStreamLost { saved.signal() }
        }
        while alive(token), saved.wait(timeout: .now() + 1) == .timedOut {}
    }

    private func audioLoop(_ token: Int) {
        while alive(token) {
            guard let config = configuration(token), let codec = config.audioCodec,
                  codec == "pcm_f32le" || codec == "pcm_s16le", config.audioChannels > 0, config.audioRate > 0,
                  let stream = open("/audio", token: token) else {
                pause(2)
                continue
            }
            let bytesPerSample = codec == "pcm_f32le" ? 4 : 2
            let frameSize = bytesPerSample * config.audioChannels
            while alive(token), let packet = stream.readPacket(limit: Self.maxAudioPacket) {
                guard packet.count % frameSize == 0 else { continue }
                let pcm = bytesPerSample == 4 ? Self.int16(fromFloat32: packet) : packet
                media.sync {
                    guard alive(token) else { return }
                    audio.submit(pcm, samplesPerChannel: packet.count / frameSize, channels: config.audioChannels,
                                 rate: config.audioRate, at: CMClockGetTime(CMClockGetHostTimeClock()))
                }
            }
            forget(stream)
            guard alive(token) else { return }
            audioLost()
            pause(1)
        }
    }

    /// Video may go on: status must stop claiming audio, and the next packets start a new audio timeline.
    private func audioLost() {
        media.sync { audio.reset() }
        lock.lock()
        let changed = statusValue.audioReady
        statusValue.audioReady = false
        lock.unlock()
        if changed { notifyStatus() }
    }

    /// RemotePlayAudio takes interleaved Int16.
    private static func int16(fromFloat32 data: Data) -> Data {
        var output = Data(count: data.count / 2)
        output.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                for index in 0..<(data.count / 4) {
                    let sample = source.loadUnaligned(fromByteOffset: index * 4, as: Float32.self)
                    let clamped = sample.isFinite ? max(-1, min(1, sample)) : 0
                    target.storeBytes(of: Int16(clamped * 32767).littleEndian, toByteOffset: index * 2, as: Int16.self)
                }
            }
        }
        return output
    }

    /// Asks PBS for an IDR after a decode failure, at most once a second.
    private func requestKeyframe() {
        let now = uptimeSeconds()
        lock.lock()
        guard now - lastKeyframeRequest >= 1 else { lock.unlock(); return }
        lastKeyframeRequest = now
        lock.unlock()
        let host = currentHost(), port = port
        DispatchQueue.global(qos: .utility).async {
            _ = PBSConnection.perform(host: host, port: port, method: "POST", path: "/video/keyframe")
        }
    }

    private func publish(_ phase: PBSStatus.Phase, issue: String?) {
        lock.lock()
        let changed = statusValue.phase != phase || statusValue.issue != issue
        statusValue.phase = phase
        statusValue.issue = issue
        lock.unlock()
        if changed { notifyStatus() }
    }

    private func notifyStatus() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStatus?(self.status)
        }
    }
}

#endif
