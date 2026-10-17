// The hub: frames, the one padd link, auto-assign, padd start/stop, and the API clients around them.

import AVFoundation
import Foundation

protocol HubUI: AnyObject {
    func setVisible(_ visible: Bool)
    func refresh()
    func willQuit()
    func remotePlayStreamLost(completion: (() -> Void)?)
    func validateCaptureChange() throws
    func restartCapture(video: String, audio: String?) throws
}

final class Hub {
    let config: Config
    private var currentSink: FrameSink
    var sink: FrameSink {
        lock.lock(); defer { lock.unlock() }; return currentSink
    }
    private(set) var captureVideo = ""
    private var remotePlayHostChange: UInt64 = 0
    private(set) var captureGeneration: UInt64 = 0
    private(set) var captureAudio: String?
    private var captureIssueText: String?
    private(set) var captureIssue: String? {
        get { lock.lock(); defer { lock.unlock() }; return captureIssueText }
        set { lock.lock(); captureIssueText = newValue; lock.unlock() }
    }
    let remotePlayCredentials = RemotePlayCredentialStore()
    let controller: PadController
    let padd: PaddRunner
    let lease = Lease()
    private var currentSource: FrameSource?
    var source: FrameSource! {
        get { lock.lock(); defer { lock.unlock() }; return currentSource }
        set { lock.lock(); currentSource = newValue; lock.unlock() }
    }
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
    /// One Remote Play input request (PS button, keyboard) at a time; `remoteButtonsHeld` is under `lock`.
    private let remoteInput = NSLock()
    private var remoteButtonsHeld = false

    var stateDir: String { config.stateDir }
    var socketPath: String { config.stateDir + "/capture.sock" }
    /// The inode of the socket this app bound, so quitting removes only its own socket file.
    var boundSocket: ino_t?

    init(config: Config) {
        self.config = config
        currentSink = FrameSink(path: config.stateDir + "/latest.jpg", fps: config.snapshotFPS)
        controller = PadController(host: config.host, port: config.port)
        padd = PaddRunner(config: config)
        padd.hub = self
        if config.host.isEmpty { noticeText = missingHost }
        else if padd.cli.isEmpty, let repo = config.repo {
            noticeText = "padd Start/Stop and Install are off: \(repo) is gone. Rebuild the app with make from the checkout."
        }
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
        controller.onAgentInputCancelled = { [weak self] in self?.cancelRemoteButtons() }
        lease.onChange = { [weak self] in self?.statusChanged() }
        if config.autoAssign {
            controller.onConnected = { [weak self] link in self?.autoAssign(link) }
        }
    }

    /// Creates the frame source, the API and the padd link. The UI starts the source once the preview layer is
    /// attached: starting a capture session while a preview layer joins it crashes AVFoundation.
    func start() {
        configureCapture(video: config.video, audio: config.audio)
        serveApi()
        controller.start()
    }

    /// Called on the main thread after the previous source and preview have been stopped and detached.
    func configureCapture(video: String, audio: String?) {
        captureGeneration &+= 1
        controller.setInputBlock(video == "remoteplay" ? "Remote Play is not delivering video; reconnect before sending input." : nil)
        captureVideo = video
        captureAudio = audio
        captureIssue = nil
        sink.invalidate()
        lock.lock()
        currentSink = FrameSink(path: stateDir + "/latest.jpg", fps: config.snapshotFPS)
        lock.unlock()
        try? FileManager.default.removeItem(atPath: stateDir + "/latest.jpg")
        switch video {
        case "":
            source = UnavailableSource()
            captureIssue = "Choose a capture device in Settings (⌘,)."
        case "remoteplay":
            captureAudio = "remoteplay"
            do {
                if let credentials = try remotePlayCredentials.load(host: host) {
                    let targetHost = host, token = captureGeneration
                    let authorizeLease = lease.recoveryAuthorization()
                    let admission = RemotePlayAdmission(authorizeMutation: { [weak self] in
                        guard let self, self.host == targetHost, self.captureGeneration == token,
                              self.captureVideo == "remoteplay" else {
                            throw RemotePlaySetupError("Capture changed. The previous Remote Play operation was canceled.")
                        }
                        try authorizeLease()
                    })
                    let remote = RemotePlaySource(host: host, credentials: credentials, sink: sink, admission: admission,
                                                  enableKeyboard: config.remotePlayKeyboard)
                    remote.onStatus = { [weak self, weak remote] status in
                        guard let self, let remote, self.source === remote else { return }
                        self.captureIssue = status.issue
                        self.controller.setInputBlock(status.videoReady && status.phase == .streaming ? nil
                            : "Remote Play is not delivering video; reconnect before sending input.")
                        self.statusChanged()
                    }
                    remote.onStreamLost = { [weak self, weak remote] finalized in
                        guard let self, let remote, self.source === remote else { finalized(); return }
                        self.controller.releaseAll()
                        if let ui = self.ui { ui.remotePlayStreamLost(completion: finalized) }
                        else { finalized() }
                    }
                    source = remote
                } else {
                    source = UnavailableSource()
                    captureIssue = "Set up Remote Play in Settings (⌘,)."
                }
            } catch {
                source = UnavailableSource()
                captureIssue = error.localizedDescription
            }
        case "synthetic":
            source = SyntheticSource(sink: sink)
        case let video where video.hasPrefix("file:"):
            source = FileSource(path: String(video.dropFirst(5)), sink: sink)
        default:
            do {
                source = try CameraSource(video: video, audio: audio, sink: sink)
            } catch {
                source = UnavailableSource()
                // The UI is still being built; publish the notice on its first refresh.
                captureIssue = "Capture unavailable: \(error.localizedDescription). Reconnect the capture card, then use Apply & Restart Capture in Settings."
            }
        }
        if let camera = source as? CameraSource {
            camera.onError = { [weak self, weak camera] message in
                guard let self, let camera, self.source === camera else { return }
                self.captureIssue = message
                self.statusChanged()
            }
        }
        if let captureIssue { say(captureIssue) }
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
        lease.forget(conn: conn.id)
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
        get { lock.lock(); defer { lock.unlock() }; return noticeText ?? captureIssueText }
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
        remotePlayHostChange &+= 1
        let generation = remotePlayHostChange
        if captureVideo == "remoteplay" {
            controller.setInputBlock("Remote Play is not delivering video; reconnect before sending input.")
            controller.releaseAll()
            source?.stop()
            sink.invalidate()
        }
        controller.setHost(host)
        if captureVideo == "remoteplay" {
            ui?.remotePlayStreamLost { [weak self] in
                guard let self, self.remotePlayHostChange == generation,
                      self.captureVideo == "remoteplay", self.host == host else { return }
                do { try self.ui?.restartCapture(video: "remoteplay", audio: "remoteplay") }
                catch { self.captureIssue = "Remote Play stopped after host change: \(error.localizedDescription)" }
            }
        }
        if notice == missingHost { notice = nil }
        statusChanged()
    }

    /// Takes the console from an agent that will not let go: the next in the queue gets it, and the evicted
    /// connection's held input is released. `client` limits it to that holder (the one the user confirmed).
    /// Returns the evicted holder's client name.
    @discardableResult
    func forceRelease(client: String? = nil) -> String? {
        guard let holder = lease.forceRelease(client: client) else { return nil }
        lock.lock()
        let conn = connections[holder.conn]
        lock.unlock()
        for layer in conn?.allLayers() ?? [] { controller.release(client: layer) }
        return holder.client
    }

    var clientCount: Int { lock.lock(); defer { lock.unlock() }; return connections.count }

    func status() -> [String: Any] {
        let link = controller.status()
        lock.lock()
        let shown = visible, clients = connections.count, note = noticeText ?? captureIssueText
        let sink = currentSink, source = currentSource
        lock.unlock()
        return ["ok": true, "api": apiVersion, "version": AppVersion.short, "build": AppVersion.build, "pid": Int(getpid()), "frames": sink.frames, "frame_age": sink.frameAge,
                "visible": shown, "now": uptimeSeconds(), "source": source?.name ?? "none", "clients": clients,
                "pad": link.json, "title": link.title, "notice": note ?? NSNull(), "padd": padd.json,
                "remote_play": (source as? RemotePlaySource)?.json as Any? ?? (captureVideo == "remoteplay"
                    ? RemotePlayStatus(phase: .setupNeeded, issue: note).json : NSNull()),
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

    /// How long padd may take to answer a console command; launching a title can take several seconds.
    static let commandTimeout = 30.0

    func command(_ op: String, _ arg: String, link: PadLink) throws -> Int32 {
        let timeout = Hub.commandTimeout
        switch op {
        case "home":
            let method = arg.isEmpty ? config.homeMethod : arg
            guard PMCP.homeMethods.contains(method) else {
                throw BadInput("method must be one of \(PMCP.homeMethods.joined(separator: ", "))")
            }
            return try link.command(.home, method, timeout: timeout)
        case "close":
            return try link.command(.close, timeout: timeout)
        case "launch":
            guard !arg.isEmpty else { throw BadInput("launch needs a title id") }
            return try link.command(.launch, arg, timeout: timeout)
        case "uninstall":
            guard link.hello.flags & PMCP.flagUninstall != 0 else {
                throw BadInput("this padd cannot uninstall; deploy padd 1.3 or later")
            }
            guard arg.count == 9 else { throw BadInput("uninstall needs a title id such as PPSA01234") }
            return try link.command(.uninstall, arg, timeout: timeout)
        default:
            throw BadInput("op must be home, close, launch or uninstall")
        }
    }

    // MARK: Remote Play input
    //
    // The PS button and the on-screen keyboard exist only on the Remote Play controller; every other input stays on
    // padd. Same rules as padd input (the API checks the lease first): a held key wins, and nothing is sent unless
    // Remote Play is delivering fresh video. A held PS button is released when that hold is cancelled.

    private func remotePlay() throws -> RemotePlaySource {
        guard let remote = source as? RemotePlaySource else {
            throw ApiError(code: "not_remote_play", message: "The PS button and keyboard need Remote Play as the "
                           + "video source (Settings ⌘, → Video source).")
        }
        return remote
    }

    private func setRemoteButtonsHeld(_ held: Bool) { lock.lock(); remoteButtonsHeld = held; lock.unlock() }

    /// Off the caller's thread: releasing waits on Remote Play's control queue, which may be joining a teardown.
    private func cancelRemoteButtons() {
        lock.lock(); let held = remoteButtonsHeld; let remote = currentSource as? RemotePlaySource; lock.unlock()
        guard held, let remote else { return }
        DispatchQueue.global().async { remote.releaseButtons() }
    }

    /// Holds the PS button for `holdMS`, then releases it and leaves the release gap.
    func pressPSButton(holdMS: Int, epoch: UInt64, human: Bool = false) throws {
        remoteInput.lock(); defer { remoteInput.unlock() }
        try controller.authorizeAgentInput(epoch: epoch, human: human)
        let remote = try remotePlay()
        setRemoteButtonsHeld(true)
        defer { remote.releaseButtons(); setRemoteButtonsHeld(false) }
        try remote.setButtons(UInt32(RP_BUTTON_PS))
        Thread.sleep(forTimeInterval: Double(holdMS) / 1000)
        remote.releaseButtons()
        Thread.sleep(forTimeInterval: releaseGapSeconds)
        try controller.checkInputEpoch(epoch)
    }

    /// Replaces the text of the open PS5 text field; with `submit`, closes the keyboard once the console echoed it.
    func setRemoteText(_ text: String, submit: Bool, timeout: Double, epoch: UInt64,
                       human: Bool = false) throws -> (RemotePlayKeyboardResult, Bool) {
        remoteInput.lock(); defer { remoteInput.unlock() }
        try controller.authorizeAgentInput(epoch: epoch, human: human)
        let remote = try remotePlay()
        let result = try remote.setKeyboardText(text, timeout: timeout)
        guard submit && result == .confirmed else { return (result, false) }
        try controller.authorizeAgentInput(epoch: epoch, human: human)
        try remote.closeKeyboard(accept: true)
        return (result, true)
    }

    /// accept keeps the text and closes the keyboard; otherwise the PS5 shows its own keyboard again (padd, DualSense).
    func closeRemoteKeyboard(accept: Bool, epoch: UInt64, human: Bool = false) throws {
        remoteInput.lock(); defer { remoteInput.unlock() }
        try controller.authorizeAgentInput(epoch: epoch, human: human)
        try remotePlay().closeKeyboard(accept: accept)
    }

    /// Keys mapped to commands (H = home, P = PS button through Remote Play).
    func keyCommand(_ name: String) {
        if name == "ps" {
            let epoch = controller.inputEpoch
            DispatchQueue.global().async {
                do { try self.pressPSButton(holdMS: 100, epoch: epoch, human: true) }
                catch { self.notice = "PS button: \(remotePlayInputMessage(error))" }
            }
            return
        }
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
        var info = stat()
        if let bound = boundSocket, lstat(socketPath, &info) == 0, info.st_ino == bound { unlink(socketPath) }
        exit(0)
    }
}
