import Foundation

/// Safe, numeric diagnostics. Upstream reason strings and credentials never enter logs.
struct RemotePlayError: LocalizedError {
    let code: Int
    var errorDescription: String? {
        switch code {
        case Int(RP_ERROR_IDENTITY): return "The console identity does not match the saved registration. Pair this console again."
        case Int(RP_ERROR_TIMEOUT): return "The console did not answer Remote Play discovery."
        case Int(RP_ERROR_CANCELED): return "Remote Play was canceled."
        case Int(RP_ERROR_INVALID): return "Remote Play requires a console IP address and valid registration."
        default: return "Remote Play failed (code \(code))."
        }
    }
}

/// Shared generation gate invalidates queued events immediately when stop/cancel is called.
private final class RemotePlayGeneration {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func advance() -> UInt64 { lock.lock(); defer { lock.unlock() }; value &+= 1; return value }
    func matches(_ generation: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return value == generation }
}

final class RemotePlaySession {
    struct Configuration {
        let host: String
        let consoleMAC: Data
        let registrationKey: Data
        let rpKey: Data
        /// Lets the console hand its on-screen keyboard to this client (Chiaki's keyboard handshake).
        var enableKeyboard = true
    }
    enum KeyboardEvent { case opened, confirmed, differs, closed }
    enum Event {
        case connected
        case disconnected(reason: Int)
        case loginPINNeeded(incorrect: Bool)
        case failed(RemotePlayError)
        case keyboard(KeyboardEvent)
    }
    private final class Context {
        let gate: RemotePlayGeneration
        let generation: UInt64
        let events: DispatchQueue
        let video: (Data, Int32) -> Bool
        let audio: (Data, Int, Int, Int) -> Void
        let event: (Event) -> Void
        init(gate: RemotePlayGeneration, generation: UInt64, events: DispatchQueue,
             video: @escaping (Data, Int32) -> Bool,
             audio: @escaping (Data, Int, Int, Int) -> Void, event: @escaping (Event) -> Void) {
            self.gate = gate; self.generation = generation; self.events = events
            self.video = video; self.audio = audio; self.event = event
        }
        var active: Bool { gate.matches(generation) }
        func emit(_ value: Event) {
            events.async { [self] in if active { event(value) } }
        }
    }
    private final class State {
        let queue = DispatchQueue(label: "ps5.remoteplay.control", qos: .userInitiated)
        let events = DispatchQueue(label: "ps5.remoteplay.events", qos: .userInitiated)
        let gate = RemotePlayGeneration()
        var handle: OpaquePointer?
        var context: UnsafeMutableRawPointer?
        /// The started native session of the current generation, on `queue` only.
        var live: OpaquePointer? {
            guard let handle, let context, Unmanaged<Context>.fromOpaque(context).takeUnretainedValue().active else { return nil }
            return handle
        }
        func destroy() {
            if let handle { rp_session_destroy(handle) }
            handle = nil
            if let context { Unmanaged<Context>.fromOpaque(context).release() }
            context = nil
        }
    }
    private let state = State()
    private let configuration: Configuration
    private let video: (Data, Int32) -> Bool
    private let audio: (Data, Int, Int, Int) -> Void
    private let event: (Event) -> Void

    /// Media callbacks execute synchronously on Chiaki threads, receive copied Data,
    /// and must finish promptly. Video rejection requests an IDR (at most once a second).
    /// Events execute on a separate serial queue. stop() is safe in any callback.
    init(configuration: Configuration,
         onVideo: @escaping (Data, Int32) -> Bool,
         onAudio: @escaping (Data, Int, Int, Int) -> Void,
         onEvent: @escaping (Event) -> Void) {
        self.configuration = configuration; video = onVideo; audio = onAudio; event = onEvent
    }
    func start() {
        let state = state, config = configuration
        let generation = state.gate.advance()
        let context = Context(gate: state.gate, generation: generation, events: state.events,
                              video: video, audio: audio, event: event)
        state.queue.async {
            state.destroy()
            guard context.active else { return }
            guard config.consoleMAC.count == 6, config.registrationKey.count == 16, config.rpKey.count == 16 else {
                context.emit(.failed(RemotePlayError(code: Int(RP_ERROR_INVALID)))); return
            }
            let user = Unmanaged.passRetained(context).toOpaque()
            var callbacks = RPCallbacks()
            callbacks.video = { bytes, count, lost, user in
                guard let user, let bytes else { return false }
                let context = Unmanaged<Context>.fromOpaque(user).takeUnretainedValue()
                guard context.active else { return false }
                return context.video(Data(bytes: bytes, count: count), lost)
            }
            callbacks.audio = { pcm, samples, channels, rate, user in
                guard let user, let pcm, samples <= Int.max / max(1, Int(channels)) / 2 else { return }
                let context = Unmanaged<Context>.fromOpaque(user).takeUnretainedValue()
                guard context.active else { return }
                context.audio(Data(bytes: pcm, count: samples * Int(channels) * 2), samples, Int(channels), Int(rate))
            }
            callbacks.event = { value, reason, user in
                guard let user else { return }
                let context = Unmanaged<Context>.fromOpaque(user).takeUnretainedValue()
                switch value {
                case RP_EVENT_CONNECTED: context.emit(.connected)
                case RP_EVENT_DISCONNECTED: context.emit(.disconnected(reason: Int(reason)))
                case RP_EVENT_LOGIN_PIN_NEEDED: context.emit(.loginPINNeeded(incorrect: reason != 0))
                default: break
                }
            }
            callbacks.keyboard = { value, user in
                guard let user else { return }
                let context = Unmanaged<Context>.fromOpaque(user).takeUnretainedValue()
                switch value {
                case RP_KEYBOARD_OPENED: context.emit(.keyboard(.opened))
                case RP_KEYBOARD_TEXT_CONFIRMED: context.emit(.keyboard(.confirmed))
                case RP_KEYBOARD_TEXT_DIFFERS: context.emit(.keyboard(.differs))
                case RP_KEYBOARD_CLOSED: context.emit(.keyboard(.closed))
                default: break
                }
            }
            callbacks.cancelled = { user in
                guard let user else { return true }
                return !Unmanaged<Context>.fromOpaque(user).takeUnretainedValue().active
            }
            var error: Int32 = 0
            let handle = config.consoleMAC.withUnsafeBytes { mac in
                config.registrationKey.withUnsafeBytes { key in
                    config.rpKey.withUnsafeBytes { rpKey in
                        config.host.withCString { host in
                            rp_session_create(host, mac.bindMemory(to: UInt8.self).baseAddress,
                                              key.bindMemory(to: UInt8.self).baseAddress,
                                              rpKey.bindMemory(to: UInt8.self).baseAddress, config.enableKeyboard,
                                              callbacks, user, &error)
                        }
                    }
                }
            }
            guard let handle else {
                Unmanaged<Context>.fromOpaque(user).release()
                context.emit(.failed(RemotePlayError(code: Int(error)))); return
            }
            state.handle = handle; state.context = user
            guard context.active else { state.destroy(); return }
            error = rp_session_start(handle)
            if error != 0 {
                state.destroy(); context.emit(.failed(RemotePlayError(code: Int(error))))
            }
        }
    }
    /// Nonblocking: prevents stale delivery immediately; completion follows stop/join/fini.
    func stop(completion: (() -> Void)? = nil) {
        let state = state
        _ = state.gate.advance()
        state.queue.async { state.destroy(); if let completion { state.events.async(execute: completion) } }
    }
    /// Input for the live session, serialized with start/stop on the control queue. Blocks while a
    /// teardown joins Chiaki's threads, so never call these from a Chiaki callback or the media queue.
    /// RP_ERROR_INVALID when the session is stopped, superseded or not started yet.
    func setButtons(_ buttons: UInt32) -> Int32 {
        let state = state
        return state.queue.sync { state.live.map { rp_session_set_buttons($0, buttons) } ?? Int32(RP_ERROR_INVALID) }
    }
    func keyboardSetText(_ text: String) -> Int32 {
        let state = state
        return state.queue.sync {
            guard let handle = state.live else { return Int32(RP_ERROR_INVALID) }
            return text.withCString { rp_session_keyboard_set_text(handle, $0) }
        }
    }
    func keyboardClose(accept: Bool) -> Int32 {
        let state = state
        return state.queue.sync { state.live.map { rp_session_keyboard_close($0, accept) } ?? Int32(RP_ERROR_INVALID) }
    }
    deinit { let state = state; _ = state.gate.advance(); state.queue.async { state.destroy() } }
}

final class RemotePlayRegistration {
    struct Result {
        let consoleMAC: Data
        let nickname: String
        let registrationKey: Data
        let rpKey: Data
    }
    private final class Context {
        let generation: UInt64
        let state: State
        let completion: (Swift.Result<Result, RemotePlayError>) -> Void
        init(generation: UInt64, state: State, completion: @escaping (Swift.Result<Result, RemotePlayError>) -> Void) {
            self.generation = generation; self.state = state; self.completion = completion
        }
        func finish(_ result: Swift.Result<Result, RemotePlayError>) {
            // The Chiaki callback only schedules teardown: it must never join itself.
            state.queue.async { [self] in
                guard state.gate.matches(generation) else { return }
                state.destroy()
                state.events.async { [self] in
                    if state.gate.matches(generation) { completion(result) }
                }
            }
        }
    }
    private final class State {
        let queue = DispatchQueue(label: "ps5.remoteplay.registration", qos: .userInitiated)
        let events = DispatchQueue(label: "ps5.remoteplay.registration.events")
        let gate = RemotePlayGeneration()
        var handle: OpaquePointer?
        var context: UnsafeMutableRawPointer?
        func destroy() {
            if let handle { rp_registration_destroy(handle) }
            handle = nil
            if let context { Unmanaged<Context>.fromOpaque(context).release() }
            context = nil
        }
    }
    private let state = State()
    /// PIN remains text until validation to preserve eight digits including leading zeroes.
    func start(host: String, accountID: Data, pin: String,
               completion: @escaping (Swift.Result<Result, RemotePlayError>) -> Void) {
        let state = state, generation = state.gate.advance()
        let context = Context(generation: generation, state: state, completion: completion)
        state.queue.async {
            state.destroy()
            guard state.gate.matches(generation) else { return }
            guard accountID.count == 8, pin.utf8.count == 8,
                  pin.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let number = UInt32(pin) else {
                context.finish(.failure(RemotePlayError(code: Int(RP_ERROR_INVALID)))); return
            }
            let user = Unmanaged.passRetained(context).toOpaque()
            var error: Int32 = 0
            let handle = accountID.withUnsafeBytes { account in
                host.withCString { host in
                    rp_registration_create(host, account.bindMemory(to: UInt8.self).baseAddress, number, { error, result, user in
                        guard let user else { return }
                        let context = Unmanaged<Context>.fromOpaque(user).takeUnretainedValue()
                        guard error == 0, let result else {
                            context.finish(.failure(RemotePlayError(code: Int(error)))); return
                        }
                        var copy = result.pointee
                        let mac = withUnsafeBytes(of: &copy.console_mac) { Data($0) }
                        let key = withUnsafeBytes(of: &copy.registration_key) { Data($0) }
                        let rpKey = withUnsafeBytes(of: &copy.rp_key) { Data($0) }
                        let nickname = withUnsafeBytes(of: &copy.nickname) { bytes in
                            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
                        }
                        context.finish(.success(Result(consoleMAC: mac, nickname: nickname, registrationKey: key, rpKey: rpKey)))
                    }, user, &error)
                }
            }
            guard let handle else {
                Unmanaged<Context>.fromOpaque(user).release()
                context.finish(.failure(RemotePlayError(code: Int(error)))); return
            }
            state.handle = handle; state.context = user
            if !state.gate.matches(generation) { state.destroy() }
        }
    }
    func cancel() {
        let state = state; _ = state.gate.advance()
        state.queue.async { state.destroy() }
    }
    deinit { let state = state; _ = state.gate.advance(); state.queue.async { state.destroy() } }
}
