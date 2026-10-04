// The hub: frames, the one padd link, auto-assign, padd start/stop, and the API clients around them.

import AVFoundation
import Foundation

protocol HubUI: AnyObject {
    func setVisible(_ visible: Bool)
    func refresh()
    func willQuit()
}

final class Hub {
    let config: Config
    let sink: FrameSink
    let controller: PadController
    let padd: PaddRunner
    let lease = Lease()
    var source: FrameSource!
    weak var ui: HubUI?
    private(set) var assigner: Assigner?
    private(set) var visible = false

    private let lock = NSLock()
    private var connections: [Int: Connection] = [:]
    private var nextID = 0
    private var noticeText: String?
    private let recorderLock = NSLock()
    private var activeRecorder: InputRecorder?
    /// Events go out in order, off the controller's lock.
    private let events = DispatchQueue(label: "events")

    var stateDir: String { config.stateDir }
    var socketPath: String { config.stateDir + "/capture.sock" }

    init(config: Config) {
        self.config = config
        sink = FrameSink(path: config.stateDir + "/latest.jpg", fps: config.snapshotFPS)
        controller = PadController(host: config.host, port: config.port)
        padd = PaddRunner(config: config)
        padd.hub = self
        if config.host.isEmpty { noticeText = missingHost }
        do {
            assigner = try Assigner(templatePath: config.templatePath)
        } catch {
            say("auto-assign disabled: \(error)")
        }
        controller.onState = { [weak self] state, at in
            self?.recorder?.note(state, at: at)
            self?.events.async { self?.broadcast("state", ["t": at, "state": state.json]) }
        }
        controller.onStatus = { [weak self] in self?.statusChanged() }
        lease.onChange = { [weak self] in self?.statusChanged() }
        if config.autoAssign {
            controller.onConnected = { [weak self] link in self?.autoAssign(link) }
        }
    }

    /// Creates the frame source, the API and the padd link. The UI starts the source once the preview layer is
    /// attached: starting a capture session while a preview layer joins it crashes AVFoundation.
    func start() throws {
        switch config.video {
        case "synthetic":
            source = SyntheticSource(sink: sink)
        case let video where video.hasPrefix("file:"):
            source = FileSource(path: String(video.dropFirst(5)), sink: sink)
        default:
            source = try CameraSource(video: config.video, audio: config.audio, sink: sink)
        }
        serveApi()
        controller.start()
    }

    // MARK: clients

    func register(_ fd: Int32) -> Connection {
        lock.lock()
        nextID += 1
        let conn = Connection(fd: fd, id: nextID)
        conn.keys = KeyInput(source: "api\(nextID)", controller: controller) { [weak self] in self?.keyCommand($0) }
        connections[conn.id] = conn
        lock.unlock()
        return conn
    }

    /// A client is gone: its claim, agent layers and held keys are released, the rest keeps working.
    func unregister(_ conn: Connection) {
        lock.lock()
        connections.removeValue(forKey: conn.id)
        lock.unlock()
        lease.unclaim(conn: conn.id)
        for layer in conn.allLayers() { controller.release(client: layer) }
        conn.keys.drop()
        close(conn.fd)
    }

    func broadcast(_ event: String, _ body: [String: Any]) {
        lock.lock()
        let targets = connections.values.filter { $0.wants(event) }
        lock.unlock()
        guard !targets.isEmpty else { return }
        var message = body
        message["event"] = event
        for conn in targets { conn.send(message) }
    }

    func statusChanged() {
        events.async { [weak self] in
            guard let self else { return }
            self.broadcast("status", self.status())
        }
        DispatchQueue.main.async { self.ui?.refresh() }
    }

    func setVisible(_ visible: Bool) { lock.lock(); self.visible = visible; lock.unlock() }

    var notice: String? {
        get { lock.lock(); defer { lock.unlock() }; return noticeText }
        set {
            lock.lock(); noticeText = newValue; lock.unlock()
            if let newValue { say(newValue) }
            statusChanged()
        }
    }

    /// The window's recording: every change of the merged state (keyboard and agents) while it is set.
    var recorder: InputRecorder? {
        get { recorderLock.lock(); defer { recorderLock.unlock() }; return activeRecorder }
        set { recorderLock.lock(); activeRecorder = newValue; recorderLock.unlock() }
    }

    /// The console address in use (Settings can change it while the app runs).
    var host: String { controller.host }

    /// Saves `host` for the next launches and reconnects to it now.
    func setHost(_ host: String) {
        UserDefaults.standard.set(host, forKey: savedHostKey)
        say("console address set to \(host)")
        controller.setHost(host)
        if notice == missingHost { notice = nil }
        statusChanged()
    }

    var clientCount: Int { lock.lock(); defer { lock.unlock() }; return connections.count }

    func status() -> [String: Any] {
        let link = controller.status()
        lock.lock()
        let shown = visible, clients = connections.count, note = noticeText
        lock.unlock()
        return ["ok": true, "api": apiVersion, "pid": Int(getpid()), "frames": sink.frames, "frame_age": sink.frameAge,
                "visible": shown, "now": uptimeSeconds(), "source": source?.name ?? "none", "clients": clients,
                "pad": link.json, "title": link.title, "notice": note ?? NSNull(), "padd": padd.json,
                "auto_assign": config.autoAssign && assigner != nil, "camera": cameraPermission, "lease": lease.json]
    }

    var cameraPermission: String {
        guard source is CameraSource else { return "not needed" }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "granted"
        case .denied, .restricted: return "denied"
        default: return "not asked yet"
        }
    }

    // MARK: console commands

    func command(_ op: String, _ arg: String, link: PadLink) throws -> Int32 {
        switch op {
        case "home":
            let method = arg.isEmpty ? config.homeMethod : arg
            guard PMCP.homeMethods.contains(method) else {
                throw BadInput("method must be one of \(PMCP.homeMethods.joined(separator: ", "))")
            }
            return try link.command(.home, method)
        case "close":
            return try link.command(.close)
        case "launch":
            guard !arg.isEmpty else { throw BadInput("launch needs a title id") }
            return try link.command(.launch, arg)
        case "uninstall":
            guard link.hello.flags & PMCP.flagUninstall != 0 else {
                throw BadInput("this padd cannot uninstall; deploy padd 1.3 or later")
            }
            guard arg.count == 9 else { throw BadInput("uninstall needs a title id such as PPSA01234") }
            return try link.command(.uninstall, arg)
        default:
            throw BadInput("op must be home, close, launch or uninstall")
        }
    }

    /// Keys mapped to commands (H = home).
    func keyCommand(_ name: String) {
        guard name == "home" else { return }
        DispatchQueue.global().async {
            if let link = try? self.controller.currentLink() { _ = try? self.command("home", "", link: link) }
        }
    }

    // MARK: auto-assign

    private func autoAssign(_ link: PadLink) {
        guard let assigner else { return }
        let layer = "auto-assign"
        let answered = assigner.assignIfAsked(frame: { sink.latestBuffer() }, pressCross: {
            keepFrame("auto-assign-before.jpg")
            var cross = PadState()
            cross.buttons = button("cross")
            try? controller.set(client: layer, cross)
            Thread.sleep(forTimeInterval: 0.1)
            controller.release(client: layer)
        }, log: { say($0) })
        if answered {
            keepFrame("auto-assign-after.jpg")
            notice = "Answered \"Who's using this controller?\" with the virtual pad. If your DualSense turned off, "
                + "press its PS button and pick the same user; both controllers then work."
        }
    }

    /// Evidence of an automatic press: a copy of the current frame in the state dir.
    private func keepFrame(_ name: String) {
        sink.writeNow()
        let dest = stateDir + "/" + name
        try? FileManager.default.removeItem(atPath: dest)
        try? FileManager.default.copyItem(atPath: stateDir + "/latest.jpg", toPath: dest)
    }

    // MARK: lifecycle

    /// Release input and drop the padd link (padd's disconnect rule goes neutral too). padd keeps running.
    func quit() {
        ui?.willQuit()
        controller.close()
        source?.stop()
        unlink(socketPath)
        exit(0)
    }
}
