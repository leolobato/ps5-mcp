// The console as a shared resource (docs/app-api.md, "Sharing"): one API connection can claim it, the others
// queue in order. While it is claimed, driving commands from other connections fail with `leased`.
//
// - Keyed by connection: closing a connection releases its claim or leaves the queue, so a crashed agent never
//   keeps the console.
// - A claim lapses after `idle` s without a request from its connection; the next in the queue gets it.
// - Agent vs agent only: the keyboard, the window's buttons and auto-assign are never blocked.
// - Nobody has to claim. While the console is free, every client drives it as before.
// - The window can force-release a holder that will not let go: the next in the queue gets the console, and the
//   evicted connection's next driving command fails once with `leased`, saying so.

import Foundation

final class Lease {
    static let defaultIdle = 600.0
    static let maxIdle = 3600.0

    struct Entry {
        let conn: Int
        let client: String
        let reason: String
        let idle: Double
        var since: Double
        var active: Double

        func json(now: Double, holder: Bool) -> [String: Any] {
            var out: [String: Any] = ["client": client, "reason": reason]
            if holder {
                out["held_s"] = (now - since).rounded()
                out["expires_in_s"] = max(0, idle - (now - active)).rounded()
            } else {
                out["waiting_s"] = (now - since).rounded()
            }
            return out
        }
    }

    private let lock = NSLock()
    private var owner: Entry?
    private var queue: [Entry] = []
    /// Connections whose claim was force-released and that have not been told yet.
    private var revoked = Set<Int>()
    /// Called (off the lock) whenever the owner or the queue changes.
    var onChange: (() -> Void)?

    /// Claims the console for `conn`, or joins (or keeps its place in) the queue. Returns `view(conn)`.
    func claim(conn: Int, client: String, reason: String, idle: Double) -> [String: Any] {
        let now = uptimeSeconds()
        let idle = min(max(idle, 10), Lease.maxIdle)
        let entry = Entry(conn: conn, client: client, reason: reason, idle: idle, since: now, active: now)
        lock.lock()
        revoked.remove(conn)
        var changed = expire(now)
        if owner == nil || owner?.conn == conn {
            owner = Entry(conn: conn, client: client, reason: reason, idle: idle, since: owner?.since ?? now,
                          active: now)
            changed = true
        } else if let index = queue.firstIndex(where: { $0.conn == conn }) {
            queue[index] = Entry(conn: conn, client: client, reason: reason, idle: idle, since: queue[index].since,
                                 active: now)
        } else {
            queue.append(entry)
            changed = true
        }
        let out = view(conn, now)
        lock.unlock()
        if changed { onChange?() }
        return out
    }

    /// Gives up the claim or the place in the queue. Returns whether `conn` had either.
    @discardableResult
    func unclaim(conn: Int) -> Bool {
        lock.lock()
        revoked.remove(conn)
        let had = owner?.conn == conn || queue.contains { $0.conn == conn }
        queue.removeAll { $0.conn == conn }
        if owner?.conn == conn { advance(uptimeSeconds()) }
        lock.unlock()
        if had { onChange?() }
        return had
    }

    /// Fails with `leased` when another connection holds the console.
    func check(conn: Int) throws {
        let now = uptimeSeconds()
        lock.lock()
        let changed = expire(now)
        let holder = owner
        let position = queue.firstIndex { $0.conn == conn }.map { $0 + 1 }
        let wasRevoked = revoked.remove(conn) != nil
        lock.unlock()
        if changed { onChange?() }
        if wasRevoked {
            throw ApiError(code: "leased", message: "the user force-released your claim on the PS5 from the app "
                           + "window; call claim to queue for it again")
        }
        guard let holder, holder.conn != conn else { return }
        let held = Int(now - holder.since)
        let place = position.map { "you are #\($0) in the queue" } ?? "call claim to queue for it"
        throw ApiError(code: "leased", message: "the PS5 is in use by \(holder.client) (\"\(holder.reason)\") "
                       + "for \(held) s; \(place)")
    }

    /// Takes the console from its holder (only if it is `client`, when given) and passes it to the next in the
    /// queue. Returns the evicted holder.
    @discardableResult
    func forceRelease(client: String? = nil) -> Entry? {
        lock.lock()
        let holder = owner.flatMap { client == nil || $0.client == client ? $0 : nil }
        if let holder {
            say("lease: force-released \(holder.client) (\"\(holder.reason)\")")
            revoked.insert(holder.conn)
            advance(uptimeSeconds())
        }
        lock.unlock()
        if holder != nil { onChange?() }
        return holder
    }

    /// A closed connection cannot be told any more.
    func forget(conn: Int) {
        lock.lock(); revoked.remove(conn); lock.unlock()
    }

    /// Any request from the holder keeps its claim alive.
    func touch(conn: Int) {
        lock.lock()
        if owner?.conn == conn { owner?.active = uptimeSeconds() }
        lock.unlock()
    }

    /// The lease as `conn` sees it: `granted`, `position` (0 = holder, n = nth in the queue, -1 = neither).
    func view(conn: Int) -> [String: Any] {
        let now = uptimeSeconds()
        lock.lock()
        let changed = expire(now)
        let out = view(conn, now)
        lock.unlock()
        if changed { onChange?() }
        return out
    }

    /// For `status`: the holder and the queue.
    var json: [String: Any] {
        let now = uptimeSeconds()
        lock.lock()
        let changed = expire(now)
        let out = json(now)
        lock.unlock()
        if changed { onChange?() }
        return out
    }

    // MARK: under the lock

    private func json(_ now: Double) -> [String: Any] {
        ["owner": owner?.json(now: now, holder: true) ?? NSNull(),
         "queue": queue.map { $0.json(now: now, holder: false) }]
    }

    private func view(_ conn: Int, _ now: Double) -> [String: Any] {
        let position = owner?.conn == conn ? 0 : queue.firstIndex { $0.conn == conn }.map { $0 + 1 } ?? -1
        return json(now).merging(["ok": true, "granted": position == 0, "position": position]) { a, _ in a }
    }

    private func expire(_ now: Double) -> Bool {
        guard let holder = owner, now - holder.active > holder.idle else { return false }
        say("lease: \(holder.client) idle for \(Int(holder.idle)) s, passing the console on")
        advance(now)
        return true
    }

    private func advance(_ now: Double) {
        owner = nil
        guard !queue.isEmpty else { return }
        var next = queue.removeFirst()
        next.since = now
        next.active = now
        owner = next
    }
}
