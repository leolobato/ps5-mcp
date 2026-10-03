// The one padd link and the merged pad state (client.PadController and keys.KeyServer in Python).
//
// - Every API client owns an agent layer; the layers OR together, so several agents never see "busy".
// - The keyboard layer (window keys and API `key`) wins: while any key is held, non-neutral agent writes fail
//   with "human has control", and a key going down cancels every agent hold.
// - Changes are sent at once; the state is repeated every `keepalive` s so padd's 1 s watchdog never fires.
// - After every (re)connect all layers are reset to neutral before anything is sent.
// - `pause()` closes the link and stops reconnecting (padd start/stop need padd's only client slot).

import Foundation

func uptimeSeconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

struct LinkStatus {
    var connected: Bool
    var paused: Bool
    var host: String
    var port: UInt16
    var hello: Hello?
    var error: String?
    var reconnects: Int
    var statesSent: UInt64
    var humanActive: Bool
    var agents: Int

    var json: [String: Any] {
        var out: [String: Any] = ["connected": connected, "paused": paused, "host": host, "port": Int(port),
                                  "error": error as Any? ?? NSNull(), "reconnects": reconnects,
                                  "states_sent": statesSent, "human_has_control": humanActive,
                                  "agent_layers": agents]
        if let hello {
            out["hello"] = hello.json
            out["version"] = hello.versionString
        }
        return out
    }

    /// Window title, as keys.title_for did.
    var title: String {
        if paused { return "PS5 MCP · padd start/stop running" }
        if !connected { return "PS5 MCP · no payload" + (error.map { " (\($0))" } ?? "") }
        let pad = hello?.padReady == true ? "pad connected" : "payload up, NO pad"
        return "PS5 MCP · \(pad)" + (humanActive ? " · you have control" : "")
    }
}

final class PadController {
    let host: String
    let port: UInt16
    let keepalive: Double
    private let cond = NSCondition()
    private var agents: [String: PadState] = [:]
    private var keys: [String: PadState] = [:]
    private var link: PadLink?
    private var dirty = true
    private var paused = false
    private var stopped = false
    private var connecting = false
    private var lastMerged = PadState.neutral
    private(set) var error: String?
    private(set) var reconnects = 0
    private(set) var statesSent: UInt64 = 0

    /// Called (from any thread, never with the lock held) when the link or control state changes.
    var onStatus: (() -> Void)?
    /// Called with the lock held, in order, with the uptime of every change of the merged state.
    var onState: ((PadState, Double) -> Void)?
    /// Run on its own thread after every (re)connect (auto-assign).
    var onConnected: ((PadLink) -> Void)?

    init(host: String, port: UInt16, keepalive: Double = 0.1) {
        self.host = host
        self.port = port
        self.keepalive = keepalive
    }

    func start() { Thread.detachNewThread { self.run() } }

    // MARK: inputs

    func set(client: String, _ state: PadState) throws {
        cond.lock()
        if !keys.isEmpty && !state.isNeutral { cond.unlock(); throw PadError.humanHasControl }
        if state.isNeutral { agents.removeValue(forKey: client) } else { agents[client] = state }
        changed()
        cond.unlock()
    }

    /// Keyboard layer: `state` while the key is down, nil on release.
    func key(_ id: String, _ state: PadState?) {
        cond.lock()
        let wasHuman = !keys.isEmpty
        if let state {
            keys[id] = state
            agents.removeAll()  // a human taking over cancels any agent hold
        } else {
            keys.removeValue(forKey: id)
        }
        let isHuman = !keys.isEmpty
        changed()
        cond.unlock()
        if wasHuman != isHuman { onStatus?() }
    }

    func release(client: String) {
        cond.lock()
        agents.removeValue(forKey: client)
        changed()
        cond.unlock()
    }

    func releaseAll() {
        cond.lock()
        let wasHuman = !keys.isEmpty
        keys.removeAll()
        agents.removeAll()
        changed()
        cond.unlock()
        if wasHuman { onStatus?() }
    }

    /// With the lock held, after any input change.
    private func changed() {
        dirty = true
        let state = merged()
        if state != lastMerged {
            lastMerged = state
            onState?(state, uptimeSeconds())
        }
        cond.broadcast()
    }

    private func merged() -> PadState {
        let layers = keys.isEmpty ? Array(agents.values) : Array(keys.values)
        return layers.reduce(PadState.neutral) { $0.merged($1) }
    }

    func current() -> (merged: PadState, keys: Int, agents: [String: PadState]) {
        cond.lock(); defer { cond.unlock() }
        return (merged(), keys.count, agents)
    }

    // MARK: link

    func currentLink(wait: Double = 0) throws -> PadLink {
        let deadline = Date().addingTimeInterval(wait)
        cond.lock(); defer { cond.unlock() }
        while true {
            if let link, !link.closed { return link }
            if paused { throw PadError.failed("padd start/stop is running; the link is paused") }
            if Date() >= deadline {
                throw PadError.failed("padd not connected at \(host):\(port): \(error ?? "connecting")")
            }
            _ = cond.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
    }

    func status() -> LinkStatus {
        cond.lock(); defer { cond.unlock() }
        let up = link.map { !$0.closed } ?? false
        return LinkStatus(connected: up, paused: paused, host: host, port: port, hello: up ? link?.hello : nil,
                          error: error, reconnects: reconnects, statesSent: statesSent, humanActive: !keys.isEmpty,
                          agents: agents.count)
    }

    /// Close the link (neutral first) and stop reconnecting until `resume()`. Returns once the link is down.
    func pause() {
        cond.lock()
        paused = true
        cond.broadcast()
        while link != nil || connecting { _ = cond.wait(until: Date().addingTimeInterval(0.05)) }
        cond.unlock()
        onStatus?()
    }

    func resume() {
        cond.lock()
        paused = false
        cond.broadcast()
        cond.unlock()
        onStatus?()
    }

    /// Sleeps up to `seconds`, waking early when paused/resumed/stopped. Lock held.
    private func nap(_ seconds: Double) {
        _ = cond.wait(until: Date().addingTimeInterval(seconds))
    }

    private func run() {
        var backoff = 0.25
        while true {
            cond.lock()
            if stopped { cond.unlock(); return }
            if paused { nap(1); cond.unlock(); continue }
            connecting = true
            cond.unlock()
            let link: PadLink
            do {
                link = try PadLink(host: host, port: port)
            } catch {
                cond.lock()
                self.error = "\(error)"
                connecting = false
                cond.broadcast()
                cond.unlock()
                onStatus?()
                cond.lock()
                nap(backoff)
                cond.unlock()
                backoff = min(backoff * 2, 5)
                continue
            }
            backoff = 0.25
            cond.lock()
            let wasHuman = !keys.isEmpty
            agents.removeAll()
            keys.removeAll()
            self.link = link
            connecting = false
            error = nil
            changed()
            let abandon = paused || stopped  // paused while connecting: give the slot back at once
            cond.unlock()
            if wasHuman { onStatus?() }
            if !abandon {
                onStatus?()
                if let onConnected { Thread.detachNewThread { onConnected(link) } }
                do {
                    try stream(link)
                } catch {
                    cond.lock(); self.error = "\(error)"; cond.unlock()
                }
            }
            link.close()
            cond.lock()
            self.link = nil
            reconnects += 1
            cond.broadcast()
            cond.unlock()
            onStatus?()
        }
    }

    /// Streams until the link fails (throws) or the controller is paused or stopped (returns, after neutral).
    private func stream(_ link: PadLink) throws {
        var lastSent = 0.0
        while true {
            cond.lock()
            if !dirty && !paused && !stopped {
                _ = cond.wait(until: Date().addingTimeInterval(max(0, keepalive - (uptimeSeconds() - lastSent))))
            }
            let leaving = paused || stopped
            let state = leaving ? PadState.neutral : merged()
            dirty = false
            cond.unlock()
            if link.closed { throw PadError.failed(link.error ?? "connection closed") }
            if leaving {
                _ = try? link.sendState(.neutral, wait: true, timeout: 1)
                return
            }
            try link.sendState(state)
            cond.lock(); statesSent += 1; cond.unlock()
            lastSent = uptimeSeconds()
        }
    }

    /// Neutral, then close the link for good (padd's own disconnect rule releases too). Never sends SHUTDOWN.
    func close() {
        releaseAll()
        cond.lock()
        stopped = true
        cond.broadcast()
        let deadline = Date().addingTimeInterval(1.5)
        while link != nil && Date() < deadline { _ = cond.wait(until: Date().addingTimeInterval(0.05)) }
        cond.unlock()
    }
}

// MARK: - keyboard

enum KeyAction {
    case pad(PadState)
    case command(String)
}

/// Key name (as produced by `keyName`) -> pad state while held, or a command (keys.DEFAULT_KEYMAP).
let defaultKeymap: [String: KeyAction] = {
    func b(_ name: String) -> KeyAction { var s = PadState(); s.buttons = button(name); return .pad(s) }
    func axis(_ set: (inout PadState) -> Void) -> KeyAction { var s = PadState(); set(&s); return .pad(s) }
    var l2 = PadState(); l2.buttons = button("l2"); l2.l2 = 255
    var r2 = PadState(); r2.buttons = button("r2"); r2.r2 = 255
    return [
        "up": b("up"), "down": b("down"), "left": b("left"), "right": b("right"),
        "enter": b("cross"), "space": b("cross"), "backspace": b("circle"), "escape": b("circle"),
        "[": b("square"), "]": b("triangle"), "q": b("l1"), "e": b("r1"), "z": .pad(l2), "c": .pad(r2),
        "w": axis { $0.ly = 0 }, "s": axis { $0.ly = 255 }, "a": axis { $0.lx = 0 }, "d": axis { $0.lx = 255 },
        "i": axis { $0.ry = 0 }, "k": axis { $0.ry = 255 }, "j": axis { $0.rx = 0 }, "l": axis { $0.rx = 255 },
        "tab": b("options"), "t": b("touchpad"), "h": .command("home"),
    ]
}()

/// The PS5 ignores very short presses; a quick tap (or a synthetic key event) is stretched to this.
let minHoldSeconds = 0.08

/// Key-down/up from one source (the window, or one API connection) into the keyboard layer.
final class KeyInput {
    private let source: String
    private let controller: PadController
    private let onCommand: (String) -> Void
    private let lock = NSLock()
    private var held = Set<String>()
    private var downAt: [String: Double] = [:]
    private var pressCount: [String: Int] = [:]

    init(source: String, controller: PadController, onCommand: @escaping (String) -> Void) {
        self.source = source
        self.controller = controller
        self.onCommand = onCommand
    }

    /// Returns false for keys that are not mapped.
    @discardableResult
    func handle(_ key: String, down: Bool) -> Bool {
        guard let action = defaultKeymap[key] else { return false }
        let id = "\(source):\(key)"
        switch action {
        case .command(let name):
            if down { onCommand(name) }
        case .pad(let state):
            lock.lock()
            if down {
                if held.contains(key) { lock.unlock(); return true }  // auto-repeat: a held key holds the button
                held.insert(key)
                downAt[key] = uptimeSeconds()
                pressCount[key, default: 0] += 1
                lock.unlock()
                controller.key(id, state)
            } else {
                guard held.remove(key) != nil else { lock.unlock(); return true }
                let remaining = minHoldSeconds - (uptimeSeconds() - (downAt.removeValue(forKey: key) ?? 0))
                let press = pressCount[key, default: 0]
                lock.unlock()
                if remaining > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + remaining) {
                        self.lock.lock()
                        let pressedAgain = self.held.contains(key) || self.pressCount[key] != press
                        self.lock.unlock()
                        if !pressedAgain { self.controller.key(id, nil) }
                    }
                } else {
                    controller.key(id, nil)
                }
            }
        }
        return true
    }

    /// Key-up for every held key (focus lost); taps still last `minHoldSeconds`.
    func releaseHeld() {
        lock.lock()
        let keys = held
        lock.unlock()
        for key in keys { handle(key, down: false) }
    }

    /// The source is gone: release at once.
    func drop() {
        lock.lock()
        let keys = held
        held.removeAll()
        lock.unlock()
        for key in keys { controller.key("\(source):\(key)", nil) }
    }
}
