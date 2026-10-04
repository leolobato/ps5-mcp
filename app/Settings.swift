// The Settings window (⌘,): the PS5's IP address, saved for the next launches and applied at once.
//
// --host and PS5_HOST still win at launch (the MCP server passes PS5_HOST), so the window says when one of them set
// this launch's address. Saving here switches the running app to the new address either way.

import AppKit

final class SettingsWindow: NSObject, NSTextFieldDelegate {
    let window: NSWindow
    private let hub: Hub
    private let address = NSTextField()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let save = NSButton(title: "Save", target: nil, action: nil)
    private let onSaved: () -> Void

    init(hub: Hub, onSaved: @escaping () -> Void) {
        self.hub = hub
        self.onSaved = onSaved
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Settings"
        window.isReleasedWhenClosed = false

        let label = NSTextField(labelWithString: "PS5 IP address")
        address.placeholderString = "192.168.1.20"
        address.delegate = self
        address.target = self
        address.action = #selector(saved)
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let field = NSStackView(views: [label, address])
        field.spacing = 8
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 380
        save.target = self
        save.action = #selector(saved)
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), save])

        let content = NSStackView(views: [field, note, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [field, buttons] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
        }
        window.contentView = content
    }

    func show() {
        address.stringValue = hub.host
        update()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(address)
    }

    private var entered: String { address.stringValue.trimmingCharacters(in: .whitespaces) }

    /// An IP address or host name: no spaces or slashes, and not empty.
    private var valid: Bool {
        !entered.isEmpty && entered.rangeOfCharacter(from: CharacterSet(charactersIn: " /:\\")) == nil
    }

    func controlTextDidChange(_ notification: Notification) { update() }

    private func update() {
        save.isEnabled = valid && entered != hub.host
        var text = "Saved for the next launches. The padd link reconnects to the new address when you save."
        let source = hub.config.hostSource
        if source == "--host" || source == "PS5_HOST" {
            text += " This launch got its address from \(source) (\(hub.config.host)), which wins over Settings "
                + "when the app starts; the MCP server sets PS5_HOST."
        }
        note.stringValue = text
    }

    @objc private func saved() {
        guard valid else { NSSound.beep(); return }
        hub.setHost(entered)
        update()
        onSaved()
        window.close()
    }
}
