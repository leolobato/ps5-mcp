// The floating panel with the keyboard's controller mapping. It never takes focus from the video, so keys keep going to
// the PS5 while it is open. It only shows the mapping: keys reach the console while the main window's video has focus,
// and the panel says when they do not. ⌃⌥K shows or hides it from any app.

import AppKit
import Carbon.HIToolbox

let keyboardPanelShownKey = "keyboardPanelShown"
let keyboardPanelFloatsKey = "keyboardPanelFloats"

final class KeyboardPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let focusLabel = NSTextField(labelWithString: "")
    private let focusPill = NSBox()
    private var hotKey: GlobalHotKey?
    private var placed = false
    var onChange: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    /// On by default: over every app and Space. Off: only while PS5 MCP is the active app.
    static var floats: Bool {
        get { UserDefaults.standard.object(forKey: keyboardPanelFloatsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: keyboardPanelFloatsKey) }
    }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.title = "Keyboard controls"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.delegate = self
        placed = UserDefaults.standard.string(forKey: "NSWindow Frame keyboardPanel") != nil
        panel.setFrameAutosaveName("keyboardPanel")
        let content = build()
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        applyFloating()
    }

    func applyFloating() {
        panel.hidesOnDeactivate = !Self.floats
        panel.collectionBehavior = Self.floats ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]
    }

    /// Takes the shortcut once there is a window to go with it (a headless launch has none).
    func enableHotKey() {
        guard hotKey == nil else { return }
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.toggle()
        }
    }

    func toggle() { setShown(!panel.isVisible) }

    /// The person's choice, saved for the next launch.
    func setShown(_ shown: Bool) {
        UserDefaults.standard.set(shown, forKey: keyboardPanelShownKey)
        if shown { show() } else { panel.orderOut(nil) }
        onChange?()
    }

    /// Follows the main window without changing the saved choice.
    func windowVisibilityChanged(_ visible: Bool) {
        if !visible { panel.orderOut(nil) }
        else if UserDefaults.standard.bool(forKey: keyboardPanelShownKey) { show() }
        onChange?()
    }

    private func show() {
        if !placed, let screen = NSScreen.main {  // top right the first time, then where it was left
            placed = true
            panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 24,
                                               y: screen.visibleFrame.maxY - 24))
        }
        panel.orderFrontRegardless()
    }

    func setKeysActive(_ active: Bool) {
        let text = active ? "Keys go to the PS5" : "Click the video to send keys"
        guard focusLabel.stringValue != text else { return }
        focusLabel.stringValue = text
        focusLabel.textColor = active ? .systemGreen : .systemYellow
        focusPill.fillColor = (active ? NSColor.systemGreen : .systemYellow).withAlphaComponent(0.18)
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: keyboardPanelShownKey)
        DispatchQueue.main.async { self.onChange?() }
    }

    // MARK: layout, top to bottom in the order of a controller

    private func build() -> NSView {
        focusPill.boxType = .custom
        focusPill.borderWidth = 0
        focusPill.cornerRadius = 10
        focusPill.titlePosition = .noTitle
        focusLabel.font = .systemFont(ofSize: 11)
        let pillContent = NSStackView(views: [focusLabel])
        pillContent.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        focusPill.pin(pillContent)
        setKeysActive(false)

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 12, right: 14)
        func add(_ view: NSView) {
            root.addArrangedSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28).isActive = true
        }
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(equalToConstant: 400).isActive = true
        root.addArrangedSubview(focusPill)
        add(pairs([cell("L2", "Z"), cell("R2", "C")]))
        add(pairs([cell("L1", "Q"), cell("R1", "E")]))
        add(pairs([cell("Share", "`", mapped: false), cell("Options", "Tab")]))
        add(pairs([cell("Touch left", "R", mapped: false), cell("Center", "T"), cell("Right", "Y", mapped: false)]))
        add(pairs([cell("PS button", "P"), cell("Home", "H")]))
        add(separator())
        let face = NSStackView(views: [cell("✕ Cross", "Enter", "Space"), cell("○ Circle", "Esc", "⌫"),
                                       cell("□ Square", "["), cell("△ Triangle", "]")])
        face.orientation = .vertical
        face.alignment = .width
        face.spacing = 3
        add(pairs([titled("D-pad", nil, cross("↑", "←", "↓", "→")), face]))
        add(separator())
        add(pairs([titled("Left stick", cell("L3", "X"), cross("W", "A", "S", "D")),
                   titled("Right stick", cell("R3", "M"), cross("I", "J", "K", "L"))]))
        let footnote = NSTextField(labelWithString: "Dimmed keys are not mapped yet.")
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .secondaryLabelColor
        root.addArrangedSubview(footnote)
        return root
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func pairs(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = 14
        return row
    }

    private func cap(_ text: String, mapped: Bool = true) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.alignment = .center
        label.textColor = mapped ? .white : .tertiaryLabelColor
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 5
        box.borderWidth = 1
        box.borderColor = mapped ? NSColor(white: 0.45, alpha: 1) : NSColor(white: 0.35, alpha: 1)
        box.fillColor = mapped ? NSColor(white: 0.25, alpha: 1) : .clear
        let content = NSStackView(views: [label])
        content.edgeInsets = NSEdgeInsets(top: 0, left: 5, bottom: 0, right: 5)
        box.pin(content)
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 22),
            box.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
        if !mapped { box.toolTip = "Not mapped yet" }
        return box
    }

    /// A control's name on the left and its keys on the right.
    private func cell(_ name: String, _ keys: String..., mapped: Bool = true) -> NSView {
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 12)
        label.textColor = mapped ? .labelColor : .tertiaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [label, spacer] + keys.map { cap($0, mapped: mapped) })
        row.spacing = 4
        if !mapped { row.toolTip = "\(name): not mapped yet" }
        return row
    }

    /// Keys laid out like arrow keys: one above the middle of three.
    private func cross(_ top: String, _ left: String, _ middle: String, _ right: String) -> NSView {
        let empty = NSGridCell.emptyContentView
        let grid = NSGridView(views: [[empty, cap(top), empty], [cap(left), cap(middle), cap(right)]])
        grid.rowSpacing = 3
        grid.columnSpacing = 3
        grid.xPlacement = .fill
        for index in 0..<3 { grid.column(at: index).width = 26 }
        for index in 0..<2 { grid.row(at: index).height = 22 }
        return grid
    }

    private func titled(_ title: String, _ extra: NSView?, _ keys: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        let heading = NSStackView(views: [label] + (extra.map { [$0] } ?? []))
        heading.spacing = 8
        heading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [heading, keys])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        return stack
    }
}

/// A shortcut that works from any app. Carbon's hot keys need no Accessibility permission.
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return OSStatus(eventNotHandledErr) }
            Unmanaged<GlobalHotKey>.fromOpaque(data).takeUnretainedValue().action()
            return noErr
        }, 1, &type, me, &handler)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x5053_4D43), id: 1)  // "PSMC"
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else {
            say("⌃⌥K is taken by another app (\(status)); use the toolbar button")
            RemoveEventHandler(handler)
            handler = nil
            return nil
        }
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
