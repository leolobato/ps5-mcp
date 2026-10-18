import AVFoundation
import Foundation

struct RemotePlayInputError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// For people: the message of a Remote Play input refusal, whichever layer raised it.
func remotePlayInputMessage(_ error: Error) -> String {
    switch error {
    case let error as LocalizedError: return error.errorDescription ?? "\(error)"
    case let error as CustomStringConvertible: return error.description
    default: return "\(error)"
    }
}

/// The console's answer to a keyboard text request.
enum RemotePlayKeyboardResult { case confirmed, differs, closed, timeout }

/// Owns one media timeline at a time. All decode/sink work is serialized and
/// callbacks synchronously consume buffers, so network traffic cannot queue an
/// unbounded number of frames. Reconnects start a fresh decoder/audio timeline.
final class RemotePlaySource: FrameSource {
    let name = "remoteplay"
    private let queue = DispatchQueue(label: "remoteplay.media", qos: .userInteractive)
    private let lock = NSLock()
    private let sink: FrameSink
    private let configuration: RemotePlaySession.Configuration
    private var session: RemotePlaySession?
    private var generation = 0
    private var running = false
    private var timer: DispatchSourceTimer?
    private var lastVideo = 0.0
    private var statusValue = RemotePlayStatus()
    private let admission: RemotePlayAdmissionServicing
    private var admissionAttempted = false
    private let enableKeyboard: Bool
    /// Chiaki's quit reason for the console's "Remote Play crashed" refusal (application reason 0x80108b15).
    static let remotePlayCrashedReason = 5
    /// On-screen keyboard state of the current timeline; `keyboardEvents` counts console answers.
    private let keyboard = NSCondition()
    private var keyboardOpen = false
    private var keyboardEvents = 0
    private var keyboardLast: RemotePlaySession.KeyboardEvent?
    var onStatus: ((RemotePlayStatus) -> Void)?
    /// Completion releases the old recording timeline; retry waits for it and native shutdown.
    var onStreamLost: ((@escaping () -> Void) -> Void)?
    private final class Recovery {
        var nativeStopped = false
        var timelineFinalized = false
        var scheduled = false
        var admissionReady = true
    }
    private lazy var decoder = RemotePlayDecoder { [weak self] buffer, time in
        guard let self else { return }
        self.sink.push(buffer, at: time)
        self.lastVideo = uptimeSeconds()
        self.lock.lock()
        self.statusValue.videoReady = true
        self.statusValue.width = CVPixelBufferGetWidth(buffer)
        self.statusValue.height = CVPixelBufferGetHeight(buffer)
        self.lock.unlock()
        if self.status.phase != .streaming { self.publish("streaming", issue: nil) }
    }
    private lazy var audio = RemotePlayAudio { [weak self] sample in
        guard let self else { return }
        self.sink.push(audio: sample)
        self.lock.lock(); let changed = !self.statusValue.audioReady; self.statusValue.audioReady = true; self.lock.unlock()
        if changed { self.notifyStatus() }
    }

    init(host: String, credentials: RemotePlayCredentials, sink: FrameSink,
         admission: RemotePlayAdmissionServicing = RemotePlayAdmission(), enableKeyboard: Bool = true) {
        self.admission = admission
        self.sink = sink
        self.enableKeyboard = enableKeyboard
        configuration = .init(host: host, consoleMAC: credentials.consoleMAC,
                              registrationKey: credentials.registrationKey, rpKey: credentials.sessionKey,
                              enableKeyboard: enableKeyboard)
        // Initialize lazy callbacks on owner queue before mute/network callbacks can race.
        _ = decoder
        _ = audio
    }

    var status: RemotePlayStatus {
        lock.lock(); var value = statusValue; lock.unlock()
        keyboard.lock(); value.keyboardOpen = keyboardOpen; keyboard.unlock()
        value.keyboardEnabled = enableKeyboard
        return value
    }
    var json: [String: Any] { status.json }
    private func notifyStatus() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStatus?(self.status)
        }
    }
    private func publish(_ state: String, issue: String?) {
        lock.lock(); statusValue.phase = RemotePlayStatus.Phase(rawValue: state) ?? .unavailable
        statusValue.issue = issue; statusValue.generation = generation; lock.unlock()
        notifyStatus()
    }
    private func clearReadiness() {
        lock.lock(); statusValue.videoReady = false; statusValue.audioReady = false
        statusValue.width = 0; statusValue.height = 0; lock.unlock()
        // A new or lost timeline has no open text field; waiting requests end as closed.
        keyboard.lock(); keyboardOpen = false; keyboardEvents += 1; keyboardLast = .closed; keyboard.broadcast(); keyboard.unlock()
    }
    private func keyboardChanged(_ event: RemotePlaySession.KeyboardEvent) {
        keyboard.lock()
        switch event {
        case .opened: keyboardOpen = true
        case .closed: keyboardOpen = false
        case .confirmed, .differs: break
        }
        keyboardEvents += 1; keyboardLast = event
        keyboard.broadcast(); keyboard.unlock()
        notifyStatus()
    }
    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.admissionAttempted = false
            self.lock.lock(); self.statusValue.admission = "not_attempted"; self.lock.unlock()
            self.connect()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, self.running, self.lastVideo > 0,
                      uptimeSeconds() - self.lastVideo > 3 else { return }
                self.disconnect("Remote Play stopped delivering video. Reconnecting…", retry: true)
            }
            self.timer = timer
            timer.resume()
        }
    }
    private func connect() {
        guard running else { return }
        generation += 1
        let token = generation
        lastVideo = 0
        clearReadiness()
        publish("connecting", issue: "Connecting to Remote Play…")
        let session = RemotePlaySession(configuration: configuration, onVideo: { [weak self] data, _ in
            guard let self else { return false }
            return self.queue.sync {
                guard self.running, self.generation == token else { return false }
                return self.decoder.submit(data, at: CMClockGetTime(CMClockGetHostTimeClock()))
            }
        }, onAudio: { [weak self] data, samples, channels, rate in
            guard let self else { return }
            self.queue.sync {
                guard self.running, self.generation == token else { return }
                self.audio.submit(data, samplesPerChannel: samples, channels: channels, rate: rate,
                                  at: CMClockGetTime(CMClockGetHostTimeClock()))
            }
        }, onEvent: { [weak self] event in
            guard let self else { return }
            self.queue.async {
                guard self.running, self.generation == token else { return }
                switch event {
                case .connected:
                    // Transport connection alone is not proof of live video.
                    self.lastVideo = uptimeSeconds()
                    self.publish("waiting_for_video", issue: "Connected; waiting for video…")
                case .disconnected(let reason):
                    if reason == RemotePlayAdmission.sessionRequestUnknownReason {
                        if self.admissionAttempted {
                            self.disconnect("The PS5 is not ready for another Remote Play session. Retrying…", retry: true)
                        } else {
                            self.admissionAttempted = true
                            self.disconnect("Preparing Remote Play for this PS5 session…", retry: true, applyAdmission: true)
                        }
                        return
                    }
                    if reason == Self.remotePlayCrashedReason {
                        // The PS5 answers 0x80108b15 after its Remote Play service died (seen overnight on 13.60):
                        // retrying cannot help, and the restarted service has lost the admission patch.
                        self.disconnect("The PS5 reports that its Remote Play service crashed. Restart the PS5, "
                                        + "reload the jailbreak and Payload Manager, then reconnect.", retry: false)
                        return
                    }
                    self.disconnect("Remote Play disconnected (\(reason)). Reconnecting…", retry: true)
                case .loginPINNeeded:
                    self.disconnect("The PS5 requires its user login passcode. Sign in on the TV, then restart capture.", retry: false)
                case .failed(let error):
                    // Wrong console/invalid credentials need an explicit repair, never account activation.
                    self.disconnect(error.localizedDescription, retry: error.code != Int(RP_ERROR_IDENTITY)
                                    && error.code != Int(RP_ERROR_INVALID))
                case .keyboard(let event):
                    self.keyboardChanged(event)
                }
            }
        })
        self.session = session
        session.start()
    }
    private func disconnect(_ message: String, retry: Bool, applyAdmission: Bool = false) {
        generation += 1
        let token = generation
        lastVideo = 0
        let old = session
        session = nil
        decoder.reset()
        audio.reset()
        sink.clear()
        clearReadiness()
        publish(retry ? "reconnecting" : "unavailable", issue: message)
        let recovery = Recovery()
        recovery.admissionReady = !applyAdmission
        if applyAdmission {
            lock.lock(); statusValue.admission = "applying"; lock.unlock()
            publish("applying_admission", issue: message)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.queue.sync(execute: { self.running && self.generation == token }) else { return }
                self.admission.apply(host: self.configuration.host) { [weak self] result in
                    guard let self else { return }
                    self.queue.async {
                        guard self.running, self.generation == token else { return }
                        switch result {
                        case .success:
                            self.lock.lock(); self.statusValue.admission = "verified"; self.lock.unlock()
                            recovery.admissionReady = true
                            self.publish("reconnecting", issue: "Remote Play is ready. Reconnecting…")
                            self.retryWhenReady(recovery, token: token, retry: true)
                        case .failure(let error):
                            self.lock.lock(); self.statusValue.admission = "failed"; self.lock.unlock()
                            self.publish("unavailable", issue: error.localizedDescription)
                        }
                    }
                }
            }
        }
        recovery.nativeStopped = old == nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let finalized = { [weak self] in
                guard let self else { return }
                self.queue.async {
                    recovery.timelineFinalized = true
                    self.retryWhenReady(recovery, token: token, retry: retry)
                }
            }
            if let onStreamLost = self.onStreamLost { onStreamLost(finalized) }
            else { finalized() }
        }
        old?.stop { [weak self] in
            guard let self else { return }
            self.queue.async {
                recovery.nativeStopped = true
                self.retryWhenReady(recovery, token: token, retry: retry)
            }
        }
    }
    private func retryWhenReady(_ recovery: Recovery, token: Int, retry: Bool) {
        guard retry, running, generation == token, recovery.nativeStopped,
              recovery.timelineFinalized, recovery.admissionReady, !recovery.scheduled else { return }
        recovery.scheduled = true
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.running, self.generation == token else { return }
            self.lock.lock(); self.statusValue.reconnects += 1; self.lock.unlock()
            self.connect()
        }
    }
    func stop() {
        queue.async {
            self.running = false
            DispatchQueue.main.async { self.admission.cancel() }
            self.generation += 1
            self.timer?.cancel(); self.timer = nil
            self.session?.stop(); self.session = nil
            self.decoder.reset(); self.audio.reset()
            self.sink.clear()
            self.clearReadiness()
            self.publish("stopped", issue: nil)
        }
    }
    func setMuted(_ muted: Bool) { audio.setMuted(muted) }

    // MARK: input (PS button and on-screen keyboard; everything else stays on padd)

    /// The session of a timeline that is delivering fresh video. Callers then use it outside `queue`:
    /// session calls wait for teardown, which joins Chiaki threads that block on `queue`.
    private func liveSession() throws -> RemotePlaySession {
        try queue.sync {
            guard running else { throw RemotePlayInputError("Remote Play is not running.") }
            let status = status
            guard let session, status.phase == .streaming && status.videoReady else {
                throw RemotePlayInputError("Remote Play is not delivering video; wait for it to reconnect before sending input.")
            }
            return session
        }
    }

    /// Sets the Remote Play controller's buttons (0 or RP_BUTTON_PS).
    func setButtons(_ buttons: UInt32) throws {
        let code = try liveSession().setButtons(buttons)
        if code != 0 { throw RemotePlayInputError("Remote Play did not accept the button (code \(code)).") }
    }

    /// Best effort and without checks: back to an idle Remote Play controller. Never call on `queue`.
    func releaseButtons() {
        let session = queue.sync { self.session }
        _ = session?.setButtons(0)
    }

    var isKeyboardOpen: Bool { keyboard.lock(); defer { keyboard.unlock() }; return keyboardOpen }

    /// Replaces the text of the PS5 field whose on-screen keyboard is open and waits for the console's echo.
    func setKeyboardText(_ text: String, timeout: Double) throws -> RemotePlayKeyboardResult {
        guard enableKeyboard else { throw RemotePlayInputError("Remote Play keyboard input is turned off (PS5MCP_RP_KEYBOARD=0).") }
        let session = try liveSession()
        keyboard.lock()
        guard keyboardOpen else {
            keyboard.unlock()
            throw RemotePlayInputError("No PS5 text field is open. Select a text field so the on-screen keyboard shows, then retry.")
        }
        let before = keyboardEvents
        keyboard.unlock()
        let code = session.keyboardSetText(text)
        if code != 0 { throw RemotePlayInputError("Remote Play did not accept the text (code \(code)).") }
        let deadline = Date().addingTimeInterval(timeout)
        keyboard.lock(); defer { keyboard.unlock() }
        while true {
            if keyboardEvents != before {
                switch keyboardLast {
                case .confirmed?: return .confirmed
                case .differs?: return .differs
                case .closed?: return .closed
                case .opened?, nil: break  // a field (re)opened: keep waiting for the echo
                }
            }
            if !keyboard.wait(until: deadline) { return .timeout }
        }
    }

    /// Accept closes the keyboard keeping the text; reject hands text entry back to the PS5's own keyboard.
    func closeKeyboard(accept: Bool) throws {
        let session = try liveSession()
        guard isKeyboardOpen else { throw RemotePlayInputError("No PS5 text field is open.") }
        let code = session.keyboardClose(accept: accept)
        if code != 0 { throw RemotePlayInputError("Remote Play did not close the keyboard (code \(code)).") }
        keyboard.lock(); keyboardOpen = false; keyboard.unlock()
        notifyStatus()
    }
}
