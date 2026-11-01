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
    /// What the person asked for: controller 2 connected, and which controller input drives. Kept in
    /// `<state>/controllers` and restored after every reconnect (a restarted padd has only controller 1).
    private var wantSecond = false
    private var wantActive = 1
    private var wantSecondUser: Int32?
    /// Every profile padd has reported signed in, kept in `<state>/known-users`: controller 2 can sign one of them in
    /// when nobody else is signed in (padd only lists signed-in users).
    private var knownUsersNow: [Int32: String] = [:]
    private var padsNow: Pads?
    private var loginUsersNow: LoginUsers?

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
        if let data = FileManager.default.contents(atPath: config.stateDir + "/controllers"),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            wantSecond = saved["second"] as? Bool ?? false
            wantActive = wantSecond && saved["active"] as? Int == 2 ? 2 : 1
            wantSecondUser = (saved["user"] as? Int).map { Int32($0) }
        }
        if let data = FileManager.default.contents(atPath: config.stateDir + "/known-users"),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            for (id, name) in saved { if let id = Int32(id) { knownUsersNow[id] = name } }
        }
        controller.onConnected = { [weak self] link in self?.restoreControllers(link) }
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

    /// The process behind API connection `conn`, while it is connected.
    func clientPID(conn: Int) -> pid_t? { lock.lock(); defer { lock.unlock() }; return connections[conn]?.peerPID }

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
                "auto_assign": config.autoAssign && assigner != nil, "camera": cameraPermission, "lease": lease.json,
                "controllers": controllersJSON, "login_users": loginUsers?.json as Any? ?? NSNull()]
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
        case "second_pad":
            let parts = arg.split(separator: " ").map(String.init)
            if parts == ["disconnect"] { return try disconnectSecond(link) }
            guard parts.first == "connect", parts.count <= 2 else {
                throw BadInput("second_pad needs connect, connect <user id> or disconnect")
            }
            if parts.count == 1 { return try connectSecond(link) }
            guard let user = Int32(parts[1]), user > 0 else { throw BadInput("not a user id: \(parts[1])") }
            return try connectSecond(link, user: user)
        case "select_pad":
            guard let pad = Int(arg), pad == 1 || pad == 2 else { throw BadInput("select_pad needs 1 or 2") }
            return try selectPad(pad, link: link)
        default:
            throw BadInput("op must be home, close, launch, uninstall, second_pad or select_pad")
        }
    }

    // MARK: controllers
    //
    // padd (1.7) runs controller 1 for the foreground user and, on request, controller 2 for the second signed-in
    // user. Keyboard, API and MCP input drive the selected one. A new controller shows "Who's using this
    // controller?", which only that controller can answer, so connecting controller 2 selects it and auto-assign
    // answers with it.

    /// Both controllers as padd last reported them (nil before padd 1.7 or before the first answer).
    var pads: Pads? { lock.lock(); defer { lock.unlock() }; return padsNow }

    /// Who is signed in, as padd last reported it (nil before padd 1.7 or before the first answer).
    var loginUsers: LoginUsers? { lock.lock(); defer { lock.unlock() }; return loginUsersNow }

    /// Asks padd who is signed in and how the controllers are now; the window calls it with its ping, so sign-ins
    /// and a new foreground user show.
    func refreshLoginUsers(_ link: PadLink) {
        let users = try? link.getUsers()
        let pads = try? link.getPads()
        lock.lock()
        loginUsersNow = users
        padsNow = pads
        var known = knownUsersNow
        for user in users?.users ?? [] where !user.name.isEmpty { known[user.id] = user.name }
        let changed = known != knownUsersNow
        knownUsersNow = known
        lock.unlock()
        if changed, let data = try? JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues:
            known.map { (String($0.key), $0.value) }), options: .sortedKeys) {
            try? data.write(to: URL(fileURLWithPath: stateDir + "/known-users"), options: .atomic)
        }
    }

    /// Profiles seen signed in before that are not signed in now: who controller 2 can sign in.
    var signedOutUsers: [(id: Int32, name: String)] {
        lock.lock(); defer { lock.unlock() }
        let signedIn = Set(loginUsersNow?.users.map(\.id) ?? [])
        return knownUsersNow.filter { !signedIn.contains($0.key) }.map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
    }

    /// A controller's user name, from the signed-in users.
    func controllerName(_ pad: Int) -> String? {
        guard let pads, let users = loginUsers, pad >= 1, pad <= 2, pads.handles[pad - 1] >= 0 else { return nil }
        let id = pads.userIDs[pad - 1]
        lock.lock(); let known = knownUsersNow[id]; lock.unlock()
        return users.users.first { $0.id == id }.map(LoginUsers.label) ?? known
    }

    private var controllersJSON: [String: Any] {
        guard let pads else { return ["active": 1, "second": false, "supported": false] }
        let list: [[String: Any]] = (1...2).filter { pads.handles[$0 - 1] >= 0 }.map {
            ["controller": $0, "handle": Int(pads.handles[$0 - 1]), "user_id": Int(pads.userIDs[$0 - 1]),
             "user_name": controllerName($0) as Any? ?? NSNull()]
        }
        let known = signedOutUsers.map { ["user_id": Int($0.id), "name": $0.name] }
        return ["active": pads.active, "second": pads.secondConnected, "supported": true, "list": list,
                "signed_out": known]
    }

    private func saveControllers(second: Bool, active: Int) {
        lock.lock()
        wantSecond = second
        wantActive = active
        if second, let pads = padsNow, pads.secondConnected { wantSecondUser = pads.userIDs[1] }
        if !second { wantSecondUser = nil }
        var saved: [String: Any] = ["second": second, "active": active]
        if let user = wantSecondUser { saved["user"] = Int(user) }
        lock.unlock()
        if let data = try? JSONSerialization.data(withJSONObject: saved, options: .sortedKeys) {
            try? data.write(to: URL(fileURLWithPath: stateDir + "/controllers"), options: .atomic)
        }
    }

    private func requirePads(_ link: PadLink) throws {
        guard link.hello.flags & PMCP.flagPads != 0 else {
            throw BadInput("this padd has one controller; update padd to 1.7 or later for a second one")
        }
    }

    /// Input goes to controller `pad` from now on; padd releases the other one. Returns padd's status (0, or
    /// ENOENT when controller 2 is not connected).
    func selectPad(_ pad: Int, link: PadLink) throws -> Int32 {
        try requirePads(link)
        controller.release(client: "auto-assign")  // a press in flight would land on the other controller
        let status = try link.padsCommand(.selectPad, String(pad), timeout: Hub.commandTimeout)
        refreshLoginUsers(link)
        if status == 0 {
            saveControllers(second: pads?.secondConnected ?? (pad == 2), active: pad)
            say("controller \(pad): \(link.hello.userName ?? "?") · \(link.hello.userID)")
        }
        statusChanged()
        return status
    }

    /// Adds controller 2 for the second signed-in user (or `user`) and selects it. For a signed-in user auto-assign
    /// answers its dialog; a signed-out user gets the console's sign-in picker, which the person confirms with Cross.
    /// Returns padd's status (ENOENT: nobody else is signed in; nothing changes).
    func connectSecond(_ link: PadLink, user: Int32? = nil) throws -> Int32 {
        try requirePads(link)
        controller.release(client: "auto-assign")
        let status = try link.padsCommand(.secondPad, user.map { "connect \($0)" } ?? "connect",
                                          timeout: Hub.commandTimeout)
        refreshLoginUsers(link)
        guard status == 0 else { statusChanged(); return status }
        saveControllers(second: true, active: pads?.active ?? 1)
        let selected = try selectPad(2, link: link)
        guard selected == 0 else { return selected }
        if let user, loginUsers?.users.contains(where: { $0.id == user }) == false {
            notice = "The PS5 asks to sign in \(controllerName(2) ?? String(user)) for controller 2: confirm with "
                + "Cross (Enter in this window). Input now goes to controller 2."
        } else if config.autoAssign {
            DispatchQueue.global().async { [weak self] in self?.autoAssign(link) }
        }
        return selected
    }

    /// Removes controller 2; input goes back to controller 1.
    func disconnectSecond(_ link: PadLink) throws -> Int32 {
        try requirePads(link)
        controller.release(client: "auto-assign")
        let status = try link.padsCommand(.secondPad, "disconnect", timeout: Hub.commandTimeout)
        refreshLoginUsers(link)
        if status == 0 { saveControllers(second: false, active: 1) }
        statusChanged()
        return status
    }

    /// After a (re)connect: answer controller 1's dialog, then bring back controller 2 and the selection. padd keeps
    /// both controllers while it runs, so an app restart finds them as they were; a padd restart has only
    /// controller 1. One dialog at a time: controller 2 is connected once controller 1's dialog is answered.
    private func restoreControllers(_ link: PadLink) {
        refreshLoginUsers(link)
        lock.lock(); let second = wantSecond, active = wantActive, secondUser = wantSecondUser; lock.unlock()
        guard link.hello.flags & PMCP.flagPads != 0, let pads else {
            if second { notice = "This padd has one controller; Update padd for controller 2." }
            if config.autoAssign { autoAssign(link) }
            return
        }
        do {
            if !second || pads.secondConnected {
                if pads.secondConnected && !second { saveControllers(second: true, active: pads.active) }
                else if pads.active != active { _ = try selectPad(active, link: link) }
                if config.autoAssign { autoAssign(link) }
                return
            }
            if pads.active != 1 { _ = try selectPad(1, link: link) }
            if config.autoAssign { autoAssign(link) }
            // The same user as before when they are still signed in; otherwise the second signed-in user.
            let signedIn = secondUser.map { id in loginUsers?.users.contains { $0.id == id } == true } ?? false
            let status = try link.padsCommand(.secondPad, signedIn ? "connect \(secondUser!)" : "connect",
                                              timeout: Hub.commandTimeout)
            refreshLoginUsers(link)
            guard status == 0 else {
                notice = "Controller 2: \(PMCP.padsText(.secondPad, status))."
                statusChanged()
                return
            }
            _ = try selectPad(2, link: link)
            if config.autoAssign { autoAssign(link) }
            if active == 1 { _ = try selectPad(1, link: link) }
        } catch {
            say("controllers: \(error)")
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

    /// Answers the selected controller's dialog. Controller 1 (the foreground user's): Cross on the focused profile.
    /// Controller 2: Right to its user's profile first (the dialog focuses the first profile, the foreground user's),
    /// and no press when the name is not on screen. Stops if another controller is selected meanwhile.
    private func autoAssign(_ link: PadLink) {
        guard let assigner else { return }
        let layer = "auto-assign"
        let pad = pads?.active ?? 1
        let steer = pad == 2
        let target = link.hello.userName
        func press(_ name: String) throws {
            guard (pads?.active ?? 1) == pad else { throw BadInput("controller \(pad) is no longer selected") }
            var state = PadState()
            state.buttons = button(name)
            try? controller.set(client: layer, state)
            Thread.sleep(forTimeInterval: 0.1)
            controller.release(client: layer)
            Thread.sleep(forTimeInterval: 0.3)
        }
        let answered = assigner.assignIfAsked(frame: { sink.latestBuffer() }, answer: { buffer in
            keepFrame("auto-assign-before.jpg")
            var steps = 0
            if steer {
                let users = assigner.users(buffer)
                guard let target, let index = users.firstIndex(where: {
                    $0.caseInsensitiveCompare(target) == .orderedSame
                }) else {
                    say("auto-assign: \(target ?? "the pad's user") is not among \(users); not pressing")
                    notice = "The PS5 asks \"Who's using this controller?\" for controller 2: pick "
                        + "\(target ?? "its user") with it (arrow keys and Enter in this window)."
                    return false
                }
                say("auto-assign: profiles \(users); moving \(index) right to \(target)")
                steps = index
            }
            do {
                for _ in 0..<steps { try press("right") }
                say("auto-assign: pressing Cross")
                try press("cross")
            } catch {
                say("auto-assign: \(error); not answering")
                return false
            }
            return true
        }, log: { say($0) })
        if answered {
            keepFrame("auto-assign-after.jpg")
            notice = steer
                ? "Answered \"Who's using this controller?\" with \(target ?? "its user") for controller 2."
                : "Answered \"Who's using this controller?\" with controller 1. If your DualSense turned off, "
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
