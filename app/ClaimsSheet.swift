// Claim and queue: who holds the PS5 and why, and who waits, kept up to date while the sheet is open.

import AppKit

private final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

final class ClaimsSheet: NSObject {
    private static let maxListHeight: CGFloat = 420
    let window: NSWindow
    private let hub: Hub
    private let onForceRelease: () -> Void
    private let content = FlippedStack()
    private let scroll = NSScrollView()
    private var scrollHeight: NSLayoutConstraint!
    private let forceRelease = NSButton(title: "Force Release…", target: nil, action: nil)
    private var timer: Timer?
    private var processes: [Int: String] = [:]
    private var plainText = ""

    init(hub: Hub, onForceRelease: @escaping () -> Void) {
        self.hub = hub
        self.onForceRelease = onForceRelease
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Claim and queue"

        let heading = NSTextField(labelWithString: "Claim and queue")
        heading.font = .boldSystemFont(ofSize: 15)
        let detail = NSTextField(labelWithString: "Agents claim the PS5 with claim_console; the others wait in this order.")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8

        forceRelease.target = self
        forceRelease.action = #selector(forceReleasePressed)
        forceRelease.hasDestructiveAction = true
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyText))
        let close = NSButton(title: "Close", target: self, action: #selector(closed))
        close.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [forceRelease, spacer, copy, close])
        buttons.spacing = 8

        // A long reason or queue scrolls here, so the buttons stay on screen.
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 100)
        scrollHeight.isActive = true
        let root = NSStackView(views: [heading, detail, scroll, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        for view in [scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true
        }
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root
        root.widthAnchor.constraint(equalToConstant: 560).isActive = true
    }

    func present(on parent: NSWindow, done: @escaping () -> Void) {
        reload()
        parent.beginSheet(window) { _ in done() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reload() }
    }

    private func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s < 60 ? "\(s) s" : s < 3600 ? "\(s / 60) min \(s % 60) s" : "\(s / 3600) h \(s % 3600 / 60) min"
    }

    /// A process's description does not change while it is connected, and reading it is not free.
    private func process(_ entry: Lease.Entry) -> String {
        if let known = processes[entry.conn] { return known }
        let text = agentDescription(pid: hub.clientPID(conn: entry.conn))
        processes[entry.conn] = text
        return text
    }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor, mono: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.preferredMaxLayoutWidth = 500
        return field
    }

    private func reload() {
        let (owner, queue, now) = hub.lease.entries()
        forceRelease.isEnabled = owner != nil
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var plain: [String] = []
        if let owner {
            let timing = "Held for \(duration(now - owner.since)) · lapses in "
                + "\(duration(max(0, owner.idle - (now - owner.active)))) without a request"
            let reason = owner.reason.isEmpty ? "No reason given" : owner.reason
            let details = process(owner)
            let box = Banner(target: self)
            // Command lines can be very long: the whole text is under Copy.
            let short = details.split(separator: "\n").map { $0.count > 90 ? $0.prefix(90) + "…" : String($0) }
                .joined(separator: "\n")
            box.show(.info, title: owner.client, body: "\(reason)\n\(timing)\n\(short)", wrap: 500)
            content.addArrangedSubview(box)
            box.translatesAutoresizingMaskIntoConstraints = false
            box.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            plain.append("Holding the PS5: \(owner.client)\n  reason: \(reason)\n  \(timing)\n  "
                + details.replacingOccurrences(of: "\n", with: "\n  "))
        } else {
            content.addArrangedSubview(label("Nobody holds the PS5.", color: .secondaryLabelColor))
            plain.append("Nobody holds the PS5.")
        }
        content.addArrangedSubview(label(queue.isEmpty ? "Queue: empty" : "Queue (\(queue.count))", size: 11, weight: .semibold,
                                         color: .secondaryLabelColor))
        plain.append(queue.isEmpty ? "Queue: empty" : "Queue (\(queue.count)):")
        for (index, entry) in queue.enumerated() {
            let reason = entry.reason.isEmpty ? "No reason given" : entry.reason
            let waiting = "waiting for \(duration(now - entry.since))"
            content.addArrangedSubview(label("\(index + 1).  \(entry.client) · \(reason) · \(waiting)"))
            plain.append("#\(index + 1): \(entry.client)\n  reason: \(reason)\n  \(waiting)\n  "
                + process(entry).replacingOccurrences(of: "\n", with: "\n  "))
        }
        plainText = plain.joined(separator: "\n\n")
        content.layoutSubtreeIfNeeded()
        scrollHeight.constant = min(content.fittingSize.height, Self.maxListHeight)
        window.layoutIfNeeded()
        if let root = window.contentView {
            window.setContentSize(NSSize(width: 560, height: root.fittingSize.height))
        }
    }

    @objc private func forceReleasePressed() {
        onForceRelease()
        reload()
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plainText, forType: .string)
    }

    @objc private func closed() {
        timer?.invalidate()
        timer = nil
        window.sheetParent?.endSheet(window)
    }
}
