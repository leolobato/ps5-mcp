// The window: live video on the left, console status and controls on the right. Keys in the video drive the pad.

import AppKit
import AVFoundation
import UniformTypeIdentifiers

func keyName(_ event: NSEvent) -> String? {
    switch event.keyCode {
    case 123: return "left"
    case 124: return "right"
    case 125: return "down"
    case 126: return "up"
    case 36, 76: return "enter"
    case 53: return "escape"
    case 51: return "backspace"
    case 48: return "tab"
    case 49: return "space"
    default:
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 else { return nil }
        return chars
    }
}

final class VideoView: NSView {
    var keys: KeyInput?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        if let name = keyName(event), keys?.handle(name, down: true) == true { return }
        super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) {
        if let name = keyName(event) { keys?.handle(name, down: false) }
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
}

extension NSBox {
    /// A box's own content view has no constraints, so a box sized by its content needs one pinned inside it.
    func pin(_ view: NSView) {
        let holder = NSView()
        contentView = holder
        contentViewMargins = .zero
        view.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: holder.topAnchor),
            view.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
        ])
    }
}

/// A tinted message at the top of the sidebar, shown only while something needs attention.
final class Banner: NSBox {
    enum Tone { case neutral, info, attention, error }
    private let heading = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let action = NSButton(title: "", target: nil, action: nil)
    private let stack: NSStackView
    private weak var actionTarget: AnyObject?

    init(target: AnyObject) {
        actionTarget = target
        stack = NSStackView(views: [heading, message, action])
        super.init(frame: .zero)
        boxType = .custom
        titlePosition = .noTitle
        cornerRadius = 8
        borderWidth = 1
        contentViewMargins = .zero
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.font = .systemFont(ofSize: 12)  // 11 pt looks soft on a non-Retina monitor
        action.bezelStyle = .rounded
        action.controlSize = .small
        action.refusesFirstResponder = true  // keys stay with the video
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.setCustomSpacing(6, after: message)
        pin(stack)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ tone: Tone, title: String, body: String, actionTitle: String? = nil, selector: Selector? = nil,
              enabled: Bool = true, wrap: CGFloat = 250) {
        let color: NSColor = tone == .info ? .systemBlue : tone == .attention ? .systemOrange : tone == .error ? .systemRed : .gray
        fillColor = color.withAlphaComponent(0.13)
        borderColor = color.withAlphaComponent(0.4)
        heading.stringValue = title
        heading.toolTip = title
        heading.isHidden = title.isEmpty
        message.stringValue = body
        message.toolTip = body
        message.preferredMaxLayoutWidth = wrap
        action.isHidden = actionTitle == nil
        action.title = actionTitle ?? ""
        action.target = actionTarget
        action.action = selector
        action.isEnabled = enabled
        isHidden = false
    }

    func hide() { isHidden = true }

    /// Buttons that stay under the message, for a box with its own controls.
    func addButtons(_ buttons: [NSButton]) {
        let row = NSStackView(views: buttons)
        row.spacing = 6
        buttons.forEach { $0.controlSize = .small }
        stack.addArrangedSubview(row)
    }
}

/// One connected controller. With several, the selected row is the one that gets the input.
final class ControllerRow: NSBox {
    private let select = NSButton(title: "", target: nil, action: nil)
    private let tagLabel = NSTextField(labelWithString: "Input")
    let remove = NSButton(title: "", target: nil, action: nil)

    init(target: AnyObject) {
        super.init(frame: .zero)
        boxType = .custom
        titlePosition = .noTitle
        cornerRadius = 6
        borderWidth = 0
        contentViewMargins = .zero
        select.isBordered = false
        select.alignment = .left
        select.refusesFirstResponder = true  // keys stay with the video
        select.target = target
        select.action = #selector(AppDelegate.chooseController(_:))
        select.setContentHuggingPriority(.init(1), for: .horizontal)
        select.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        select.lineBreakMode = .byTruncatingTail
        tagLabel.font = .systemFont(ofSize: 11)
        remove.isBordered = false
        remove.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove this controller")
        remove.imagePosition = .imageOnly
        remove.refusesFirstResponder = true
        remove.target = target
        remove.action = #selector(AppDelegate.removeController)
        remove.toolTip = "Remove this controller; input goes back to controller 1"
        remove.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [select, tagLabel, remove])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
        pin(stack)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(pad: Int, name: String?, selected: Bool, several: Bool, enabled: Bool) {
        let on = selected && several
        fillColor = on ? .controlAccentColor : .clear
        let ink: NSColor = on ? .white : enabled ? .labelColor : .tertiaryLabelColor
        let title = NSMutableAttributedString(string: "\(pad)   ", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: on ? ink : NSColor.secondaryLabelColor])
        title.append(NSAttributedString(string: name ?? "Controller \(pad)", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: on ? .semibold : .regular), .foregroundColor: ink]))
        select.attributedTitle = title
        select.tag = pad
        select.isEnabled = enabled && several
        select.setAccessibilityLabel("Controller \(pad)" + (name.map { ", \($0)" } ?? ""))
        select.toolTip = several ? "Send the keyboard, the API and MCP agents' input to controller \(pad)" : nil
        tagLabel.isHidden = !on
        tagLabel.textColor = ink
        remove.isHidden = !on || pad == 1
        remove.contentTintColor = ink
        isHidden = false
    }
}

final class Sidebar: NSStackView {
    static let width: CGFloat = 300
    let fields = ["Link", "padd", "Pad", "User", "Reports", "Frame age", "Clients", "Control", "In use by"]
    private var values: [String: NSTextField] = [:]
    /// Keyed by id, not title: titles change ("Record" / "Stop") and repeat across sections.
    var buttons: [String: NSButton] = [:]
    /// Whether each command can run now. Rarely used ones have no button: only the More and main menus show them.
    private var commands: [String: Bool] = [:]
    var tips: [String: String] = [:]
    let titles = NSPopUpButton(frame: .zero, pullsDown: false)
    let recordings = NSPopUpButton(frame: .zero, pullsDown: false)
    let connectionBanner: Banner
    let agentBanner: Banner
    let noticeBanner: Banner
    let remotePlayBox: Banner
    private let statusDot = NSTextField(labelWithString: "●")
    private let statusButton = NSButton(title: "", target: nil, action: nil)
    private let details = NSStackView()
    private let detailsSource = NSTextField(labelWithString: "")
    private let pressesStatus = NSTextField(labelWithString: "")
    private let controllersHeading: NSTextField
    private var controllerRows: [ControllerRow] = []

    init(target: AnyObject) {
        connectionBanner = Banner(target: target)
        agentBanner = Banner(target: target)
        noticeBanner = Banner(target: target)
        remotePlayBox = Banner(target: target)
        controllersHeading = Self.header("Controller")
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        // What is going on, then what is used most: capture, the console, launching. Controllers come last, since
        // almost every session has one. Rare commands are in the More menu.
        statusDot.font = .systemFont(ofSize: 11)
        statusDot.setContentHuggingPriority(.required, for: .horizontal)
        statusButton.isBordered = false
        statusButton.alignment = .left
        statusButton.font = .systemFont(ofSize: 13, weight: .semibold)
        statusButton.imagePosition = .imageTrailing
        statusButton.refusesFirstResponder = true
        statusButton.lineBreakMode = .byTruncatingTail
        statusButton.target = self
        statusButton.action = #selector(toggleDetails)
        statusButton.setContentHuggingPriority(.init(1), for: .horizontal)
        statusButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusButton.toolTip = "Show or hide the connection details"
        let more = button("more", "", "ellipsis.circle", #selector(AppDelegate.showMoreMenu(_:)), target)
        more.setAccessibilityLabel("More: input, agents, games, install, padd")
        more.toolTip = "Release input, agents, reload games, install and padd"
        more.setContentHuggingPriority(.required, for: .horizontal)
        full(row([statusDot, statusButton, more], equal: false, spacing: 6))
        setCustomSpacing(10, after: arrangedSubviews.last!)

        let grid = NSGridView()
        grid.rowSpacing = 3
        grid.columnSpacing = 8
        for field in fields {
            let label = NSTextField(labelWithString: field)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 11)
            let value = NSTextField(labelWithString: "–")
            value.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            value.lineBreakMode = .byTruncatingTail
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            values[field] = value
            grid.addRow(with: [label, value])
        }
        grid.column(at: 0).xPlacement = .trailing
        // The holder's reason can be long: two lines, then an ellipsis (the tooltip has the full text).
        if let holder = values["In use by"] {
            holder.lineBreakMode = .byWordWrapping
            holder.maximumNumberOfLines = 2
            holder.cell?.truncatesLastVisibleLine = true
            let labelWidth = (0..<grid.numberOfRows).compactMap { grid.cell(atColumnIndex: 0, rowIndex: $0).contentView }
                .map(\.fittingSize.width).max() ?? 0
            holder.preferredMaxLayoutWidth = Self.width - 28 - grid.columnSpacing - ceil(labelWidth)
            grid.row(at: fields.firstIndex(of: "In use by")!).yPlacement = .top
        }
        detailsSource.font = .systemFont(ofSize: 11)
        detailsSource.textColor = .secondaryLabelColor
        detailsSource.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailsSource.setContentHuggingPriority(.init(1), for: .horizontal)
        let settings = button("detailsSettings", "Settings…", nil, #selector(AppDelegate.showSettings), target)
        settings.controlSize = .small
        settings.setContentHuggingPriority(.required, for: .horizontal)
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 6
        details.addArrangedSubview(grid)
        details.addArrangedSubview(row([detailsSource, settings], equal: false))
        details.arrangedSubviews.last?.translatesAutoresizingMaskIntoConstraints = false
        details.arrangedSubviews.last?.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
        full(details)
        details.isHidden = !UserDefaults.standard.bool(forKey: "statusDetailsShown")
        setCustomSpacing(10, after: details)
        updateStatusImage()

        for banner in [remotePlayBox, connectionBanner, agentBanner, noticeBanner] {
            full(banner)
            setCustomSpacing(10, after: banner)
        }
        let reconnect = button("reconnect", "Reconnect", nil, #selector(AppDelegate.reconnectRemotePlay), target)
        let type = button("typeText", "Type…", nil, #selector(AppDelegate.typeText), target)
        type.toolTip = "Type into the PS5 text field whose keyboard is open"
        remotePlayBox.addButtons([reconnect, type])

        addArrangedSubview(Self.header("Capture"))
        let snapshot = button("snapshot", "Snapshot", "camera", #selector(AppDelegate.saveSnapshot), target)
        snapshot.toolTip = "Save the current frame as a PNG to the folder set in Settings (⌘S)"
        let video = button("video", "Record video", "video", #selector(AppDelegate.toggleVideoRecording), target)
        video.toolTip = "Record the picture and sound to an MP4 until you press Stop (⇧⌘R)"
        for view in [snapshot, video] {
            view.controlSize = .large
            view.font = .systemFont(ofSize: 13, weight: .semibold)
        }
        full(row([snapshot, video], spacing: 6))
        for popup in [titles, recordings] {
            popup.refusesFirstResponder = true  // keys stay with the video
            popup.lineBreakMode = .byTruncatingTail
            popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        recordings.setAccessibilityLabel("Button recording to play")
        let play = button("play", "", "play.fill", #selector(AppDelegate.togglePlayback), target)
        play.setAccessibilityLabel("Play the button recording")
        play.toolTip = "Play the chosen button recording"
        let record = button("record", "", "record.circle", #selector(AppDelegate.toggleRecording), target)
        record.setAccessibilityLabel("Record button presses")
        record.toolTip = "Record the button presses sent to the console (keyboard and agents) until you press Stop (⌘R)"
        for view in [play, record] { view.setContentHuggingPriority(.required, for: .horizontal) }
        pressesStatus.font = .systemFont(ofSize: 11)
        pressesStatus.textColor = .systemRed
        pressesStatus.isHidden = true
        let presses = NSStackView(views: [row([recordings, play, record], equal: false, spacing: 6), pressesStatus])
        presses.orientation = .vertical
        presses.alignment = .leading
        presses.spacing = 4
        presses.arrangedSubviews[0].translatesAutoresizingMaskIntoConstraints = false
        presses.arrangedSubviews[0].widthAnchor.constraint(equalTo: presses.widthAnchor).isActive = true
        full(presses)

        section("Console")
        let close = button("closeApp", "Close…", nil, #selector(AppDelegate.closeApp), target)
        close.toolTip = "Close the game or app that is running now"
        let ps = button("psButton", "PS", nil, #selector(AppDelegate.psButton), target)
        ps.toolTip = "Press the PS button: the control center (P). ⌥-click holds it, which goes home."
        ps.setAccessibilityLabel("PS button")
        full(row([button("home", "Home", nil, #selector(AppDelegate.home), target), ps, close], spacing: 6))

        section("Launch")
        titles.setAccessibilityLabel("Game or app to launch")
        let launch = button("launch", "Launch", nil, #selector(AppDelegate.launchTitle), target)
        launch.toolTip = "Launch the selected game or app (⌘L)"
        launch.bezelColor = .controlAccentColor
        launch.setContentHuggingPriority(.required, for: .horizontal)
        full(row([titles, launch], equal: false, spacing: 6))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        addArrangedSubview(spacer)

        let divider = NSBox()
        divider.boxType = .separator
        full(divider)
        let add = button("addController", "", "plus", #selector(AppDelegate.addController(_:)), target)
        add.isBordered = false
        add.setAccessibilityLabel("Add a controller")
        add.setContentHuggingPriority(.required, for: .horizontal)
        let headingSpacer = NSView()
        headingSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        full(row([controllersHeading, headingSpacer, add], equal: false))
        for _ in 0..<Hub.maxControllers {
            let controller = ControllerRow(target: target)
            controller.isHidden = true
            controllerRows.append(controller)
            full(controller)
            setCustomSpacing(2, after: controller)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }  // the scroll view starts at the top

    @objc private func toggleDetails() {
        details.isHidden.toggle()
        UserDefaults.standard.set(!details.isHidden, forKey: "statusDetailsShown")
        updateStatusImage()
    }

    private func updateStatusImage() {
        statusButton.image = NSImage(systemSymbolName: details.isHidden ? "chevron.right" : "chevron.down",
                                     accessibilityDescription: details.isHidden ? "Show details" : "Hide details")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        statusButton.setAccessibilityExpanded(!details.isHidden)
    }

    func setStatus(_ text: String, color: NSColor) {
        if statusButton.title != text { statusButton.title = text }
        statusDot.textColor = color
    }

    func setSource(_ text: String) { detailsSource.stringValue = text }

    func setPressesStatus(_ text: String?) {
        pressesStatus.stringValue = text ?? ""
        pressesStatus.isHidden = text == nil
    }

    func showControllers(_ pads: [(pad: Int, name: String?)], active: Int, enabled: Bool) {
        controllersHeading.stringValue = pads.count > 1 ? "CONTROLLERS" : "CONTROLLER"
        for (index, row) in controllerRows.enumerated() {
            guard index < pads.count else { row.isHidden = true; continue }
            row.show(pad: pads[index].pad, name: pads[index].name, selected: pads[index].pad == active,
                     several: pads.count > 1, enabled: enabled)
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        commands[id] = enabled
        buttons[id]?.isEnabled = enabled
    }

    func isEnabled(_ id: String) -> Bool { commands[id] ?? buttons[id]?.isEnabled ?? false }

    func setTip(_ id: String, _ tip: String?) {
        tips[id] = tip
        buttons[id]?.toolTip = tip
    }

    /// Red while it records, so the way to stop stands out.
    func setRecording(_ id: String, _ recording: Bool) {
        guard let button = buttons[id] else { return }
        button.bezelColor = recording ? .systemRed : nil
        button.contentTintColor = recording ? .white : nil
    }

    private static func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// A header with more room above it than between the rows of a section.
    private func section(_ text: String) {
        if let last = arrangedSubviews.last { setCustomSpacing(14, after: last) }
        addArrangedSubview(Self.header(text))
    }

    /// Adds a row that spans the sidebar's content width.
    private func full(_ view: NSView) {
        addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: widthAnchor, constant: -(edgeInsets.left + edgeInsets.right)).isActive = true
    }

    private func row(_ views: [NSView], equal: Bool = true, spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = spacing
        stack.distribution = equal ? .fillEqually : .fill
        return stack
    }

    private func button(_ id: String, _ title: String, _ symbol: String?, _ action: Selector,
                        _ target: AnyObject) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.refusesFirstResponder = true  // keys stay with the video
        if let symbol {
            button.identifier = NSUserInterfaceItemIdentifier(symbol)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title.isEmpty ? nil : title)
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        buttons[id] = button
        return button
    }

    func setButton(_ id: String, title: String? = nil, symbol: String) {
        guard let button = buttons[id] else { return }
        if let title, button.title != title { button.title = title }
        if button.identifier?.rawValue != symbol {
            button.identifier = NSUserInterfaceItemIdentifier(symbol)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    func set(_ field: String, _ text: String, color: NSColor = .labelColor) {
        values[field]?.stringValue = text
        values[field]?.textColor = color
        values[field]?.toolTip = text
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation,
                         HubUI {
    let hub: Hub
    var window: NSWindow!
    var video: VideoView!
    var sidebar: Sidebar!
    var keys: KeyInput!
    private var sidebarScroll: NSScrollView!
    private var sidebarMenuItem: NSMenuItem!
    private var sidebarToolbarItem: NSToolbarItem?
    private let sidebarItemID = NSToolbarItem.Identifier("toggleSidebar")
    private let videoItemID = NSToolbarItem.Identifier("toggleVideo")
    private let audioItemID = NSToolbarItem.Identifier("toggleAudio")
    private let keyboardItemID = NSToolbarItem.Identifier("toggleKeyboardPanel")
    private var keyboardMenuItem: NSMenuItem!
    private var keyboardToolbarItem: NSToolbarItem?
    private let keyboardPanel = KeyboardPanel()
    /// The current notice and when it appeared: most fade out, so the sidebar is quiet when nothing needs attention.
    private var shownNotice: String?
    private var shownNoticeAt = 0.0
    private var claimsSheet: ClaimsSheet?
    private var videoMenuItem: NSMenuItem!
    private var audioMenuItem: NSMenuItem!
    private var videoToolbarItem: NSToolbarItem?
    private var audioToolbarItem: NSToolbarItem?
    private var videoHidden = UserDefaults.standard.bool(forKey: "videoHidden")
    private var frameMeterShown = UserDefaults.standard.bool(forKey: "frameMeterShown")
    private let frameMeterOverlay = FrameMeterOverlay()
    private var frameMeterMenuItem: NSMenuItem!
    private static let startingFrameMeter = FrameMeterReading(state: .starting, gaps: 0, refreshMs: 1000.0 / 60, samples: [], now: 0)
    private var audioMuted = UserDefaults.standard.bool(forKey: "audioMuted")
    private var previewLayer: CALayer!
    private let hiddenVideoLabel = NSTextField(labelWithString: "Video hidden")
    /// Over the last picture while frames stop (the console's screen dropped the HDMI signal): it is not frozen.
    private let noSignalLabel = NSTextField(labelWithString: "")
    private var imageLayer: CALayer?
    private var previewLink: CADisplayLink?
    /// Kept while on screen: the decoder's pool must not reuse the surface the layer is showing.
    private var shownBuffer: CVPixelBuffer?
    private var pong: Pong?
    private var pongAt = 0.0
    private var titleLibrary: TitleLibrary?
    /// Web File Manager on the current console (a new one after the address changes in Settings).
    private var library: TitleLibrary {
        if let titleLibrary, titleLibrary.host == hub.host { return titleLibrary }
        let fresh = TitleLibrary(host: hub.host, stateDir: hub.stateDir)
        titleLibrary = fresh
        return fresh
    }
    private var settings: SettingsWindow?
    private var controllerList: [Int] = [1]
    private var titleList: [Title] = []
    private var titlesFetched = false
    private var titlesLoading = false
    private var titlesError: String?
    private var playing: String?
    private var videoRecorder: VideoRecorder?
    /// From Stop until the video is saved or discarded (the save sheet included).
    private var videoSaving = false
    private var afterVideoSaved: [() -> Void] = []
    private var installing: Process?
    private var uninstallSheet: UninstallSheet?
    private let playbackLock = NSLock()
    private var playbackCancelled = false
    private var stopPlayback: Bool {
        get { playbackLock.lock(); defer { playbackLock.unlock() }; return playbackCancelled }
        set { playbackLock.lock(); playbackCancelled = newValue; playbackLock.unlock() }
    }

    init(hub: Hub) { self.hub = hub }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        hub.ui = self
        hub.start()
        keys = KeyInput(source: "window", controller: hub.controller) { [weak self] in self?.hub.keyCommand($0) }
        video = VideoView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        video.keys = keys
        video.wantsLayer = true
        video.layer = CALayer()
        video.layer?.backgroundColor = NSColor.black.cgColor
        attachCapturePreview()
        video.layer?.addSublayer(frameMeterOverlay.layer)
        frameMeterOverlay.layer.isHidden = !frameMeterShown
        if frameMeterShown { hub.setFrameMeter("overlay", on: true) }
        hiddenVideoLabel.textColor = .secondaryLabelColor
        hiddenVideoLabel.translatesAutoresizingMaskIntoConstraints = false
        hiddenVideoLabel.isHidden = !videoHidden
        video.addSubview(hiddenVideoLabel)
        NSLayoutConstraint.activate([
            hiddenVideoLabel.centerXAnchor.constraint(equalTo: video.centerXAnchor),
            hiddenVideoLabel.centerYAnchor.constraint(equalTo: video.centerYAnchor),
        ])
        noSignalLabel.textColor = .white
        noSignalLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .medium)
        noSignalLabel.wantsLayer = true
        noSignalLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        noSignalLabel.layer?.cornerRadius = 6
        noSignalLabel.layer?.zPosition = 1  // above the capture preview layer, added again on every capture restart
        noSignalLabel.translatesAutoresizingMaskIntoConstraints = false
        noSignalLabel.isHidden = true
        video.addSubview(noSignalLabel)
        NSLayoutConstraint.activate([
            noSignalLabel.centerXAnchor.constraint(equalTo: video.centerXAnchor),
            noSignalLabel.topAnchor.constraint(equalTo: video.topAnchor, constant: 16),
        ])
        hub.source.setMuted(hub.config.headless || audioMuted)
        hub.source.start()
        sidebar = Sidebar(target: self)
        for popup in [sidebar.titles, sidebar.recordings] {
            popup.target = self
            popup.action = #selector(popupChanged)
        }
        titleList = library.cached()
        fillTitles()
        fillRecordings()
        // Agents save recordings too (record_stop): list them again each time the menu opens.
        NotificationCenter.default.addObserver(forName: NSPopUpButton.willPopUpNotification, object: sidebar.recordings,
                                               queue: .main) { [weak self] _ in self?.fillRecordings() }
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll = NSScrollView()
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.documentView = sidebar
        NSLayoutConstraint.activate([
            sidebarScroll.widthAnchor.constraint(equalToConstant: Sidebar.width),
            sidebar.widthAnchor.constraint(equalTo: sidebarScroll.contentView.widthAnchor),
            sidebar.heightAnchor.constraint(greaterThanOrEqualTo: sidebarScroll.contentView.heightAnchor),
        ])
        let content = NSStackView(views: [video, sidebarScroll])
        content.spacing = 0
        content.setHuggingPriority(.defaultLow, for: .horizontal)
        video.setContentHuggingPriority(.init(1), for: .horizontal)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280 + Sidebar.width, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "PS5 MCP"
        window.contentView = content
        window.contentMinSize = NSSize(width: 640 + Sidebar.width, height: 360)
        let toolbar = NSToolbar(identifier: "PS5Toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        restoreFrame()
        setVisible(!hub.config.headless)
        keyboardPanel.onChange = { [weak self] in self?.updateKeyboardControls() }
        updateKeyboardControls()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        // Follows the window's display and stops while the window cannot be seen.
        let link = video.displayLink(target: self, selector: #selector(drawFrame))
        link.add(to: .main, forMode: .common)
        previewLink = link
        say("ready")
    }

    private func attachCapturePreview() {
        imageLayer = nil
        shownBuffer = nil
        if let camera = hub.source as? CameraSource {
            let preview = AVCaptureVideoPreviewLayer(session: camera.session)
            preview.videoGravity = .resizeAspect
            preview.backgroundColor = NSColor.black.cgColor
            previewLayer = preview
        } else {
            let layer = CALayer()
            layer.backgroundColor = NSColor.black.cgColor
            layer.contentsGravity = .resizeAspect
            previewLayer = layer
            imageLayer = layer
        }
        previewLayer.frame = video.bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        previewLayer.isHidden = videoHidden
        video.layer?.addSublayer(previewLayer)
    }

    /// Validate before removing credentials or otherwise committing to a capture change.
    /// Both validation and restart run synchronously on the main thread.
    func validateCaptureChange() throws {
        guard videoRecorder == nil, !videoSaving else {
            throw BadInput("Stop and save the video recording before changing capture devices.")
        }
    }

    func restartCapture(video: String, audio: String?) throws {
        try validateCaptureChange()
        hub.source.stop()
        (previewLayer as? AVCaptureVideoPreviewLayer)?.session = nil
        previewLayer.removeFromSuperlayer()
        hub.configureCapture(video: video, audio: audio)
        attachCapturePreview()
        hub.source.setMuted(audioMuted || !hub.visible)
        hub.source.start()
        hub.statusChanged()
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About PS5 MCP", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Window", action: #selector(hideWindow), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit PS5 MCP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        sidebarMenuItem = NSMenuItem(title: "Hide Sidebar", action: #selector(toggleSidebar), keyEquivalent: "s")
        sidebarMenuItem.keyEquivalentModifierMask = [.command, .option]
        sidebarMenuItem.target = self
        viewMenu.addItem(sidebarMenuItem)
        viewMenu.addItem(.separator())
        videoMenuItem = NSMenuItem(title: "Hide Video", action: #selector(toggleVideo), keyEquivalent: "v")
        videoMenuItem.keyEquivalentModifierMask = [.command, .option]
        videoMenuItem.target = self
        viewMenu.addItem(videoMenuItem)
        audioMenuItem = NSMenuItem(title: "Mute Audio", action: #selector(toggleAudio), keyEquivalent: "m")
        audioMenuItem.keyEquivalentModifierMask = [.command, .option]
        audioMenuItem.target = self
        viewMenu.addItem(audioMenuItem)
        frameMeterMenuItem = NSMenuItem(title: frameMeterShown ? "Hide Frame Meter" : "Show Frame Meter",
                                        action: #selector(toggleFrameMeter), keyEquivalent: "f")
        frameMeterMenuItem.keyEquivalentModifierMask = [.command, .option]
        frameMeterMenuItem.target = self
        viewMenu.addItem(frameMeterMenuItem)
        viewMenu.addItem(.separator())
        keyboardMenuItem = NSMenuItem(title: "Show Keyboard Panel", action: #selector(toggleKeyboardPanel), keyEquivalent: "k")
        keyboardMenuItem.keyEquivalentModifierMask = [.control, .option]
        keyboardMenuItem.target = self
        viewMenu.addItem(keyboardMenuItem)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)
        func menu(_ title: String, _ items: [(String, Selector?, String, NSEvent.ModifierFlags)]) {
            let holder = NSMenuItem()
            let submenu = NSMenu(title: title)
            for (name, action, key, modifiers) in items {
                guard let action else { submenu.addItem(.separator()); continue }
                let item = submenu.addItem(withTitle: name, action: action, keyEquivalent: key)
                item.keyEquivalentModifierMask = modifiers
                item.target = self
            }
            holder.submenu = submenu
            main.addItem(holder)
        }
        menu("Console", [
            ("Launch Game/App", #selector(launchTitle), "l", .command),
            ("Close Running Game/App…", #selector(closeApp), "", .command),
            ("Home", #selector(home), "", .command),
            ("PS Button", #selector(psButton), "", .command),
            ("Type…", #selector(typeText), "t", .command),
            ("Release All Input", #selector(releaseAll), ".", .command),
            ("-", nil, "", .command),
            ("Force Release Agent…", #selector(forceRelease), "", .command),
            ("Claim and Queue…", #selector(showClaims), "", .command),
            ("-", nil, "", .command),
            ("Reload Games/Apps", #selector(reloadTitles), "l", [.command, .shift]),
            ("Install…", #selector(installFile), "", .command),
            ("Uninstall…", #selector(showUninstall), "", .command),
            ("-", nil, "", .command),
            ("Start padd…", #selector(startPadd), "", .command),
            ("Update padd…", #selector(updatePadd), "", .command),
            ("Stop padd…", #selector(stopPadd), "", .command),
        ])
        menu("Capture", [
            ("Save Snapshot", #selector(saveSnapshot), "s", .command),
            ("Record Video", #selector(toggleVideoRecording), "r", [.command, .shift]),
            ("Record Button Presses", #selector(toggleRecording), "r", .command),
            ("Play Recording", #selector(togglePlayback), "", .command),
        ])
        menu("Controllers", [
            ("Controller 1", #selector(chooseController(_:)), "1", .command),
            ("Controller 2", #selector(chooseController(_:)), "2", .command),
            ("Controller 3", #selector(chooseController(_:)), "3", .command),
            ("Controller 4", #selector(chooseController(_:)), "4", .command),
            ("-", nil, "", .command),
            ("Add Controller", #selector(addController(_:)), "n", [.command, .option]),
            ("Remove Controller", #selector(removeController), "\u{8}", [.command, .option]),
        ])
        for (index, item) in (main.items.last?.submenu?.items.prefix(4) ?? []).enumerated() { item.tag = index + 1 }
        var sources: [(String, Selector?, String, NSEvent.ModifierFlags)] = [
            ("Reconnect Remote Play", #selector(reconnectRemotePlay), "", .command),
            ("Set Up Remote Play…", #selector(setUpRemotePlay), "", .command),
        ]
        #if PS5MCP_PBS
        sources.append(("PBS Controls…", #selector(showSettings), "", .command))
        #endif
        menu("Video Source", sources)
        NSApp.mainMenu = main
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [videoItemID, audioItemID, keyboardItemID, .flexibleSpace, sidebarItemID]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [videoItemID, audioItemID, keyboardItemID, .flexibleSpace, sidebarItemID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == videoItemID || itemIdentifier == audioItemID {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.target = self
            if itemIdentifier == videoItemID {
                item.action = #selector(toggleVideo)
                videoToolbarItem = item
            } else {
                item.action = #selector(toggleAudio)
                audioToolbarItem = item
            }
            updatePlaybackControls()
            return item
        }
        if itemIdentifier == keyboardItemID {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboard panel")
            item.target = self
            item.action = #selector(toggleKeyboardPanel)
            keyboardToolbarItem = item
            updateKeyboardControls()
            return item
        }
        guard itemIdentifier == sidebarItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Hide Sidebar"
        item.toolTip = "Hide Sidebar (⌥⌘S)"
        item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Toggle Sidebar")
        item.target = self
        item.action = #selector(toggleSidebar)
        sidebarToolbarItem = item
        return item
    }

    @objc func toggleSidebar() {
        sidebarScroll.isHidden.toggle()
        let title = sidebarScroll.isHidden ? "Show Sidebar" : "Hide Sidebar"
        sidebarMenuItem.title = title
        sidebarToolbarItem?.label = title
        sidebarToolbarItem?.toolTip = "\(title) (⌥⌘S)"
        window.contentMinSize = NSSize(width: sidebarScroll.isHidden ? 640 : 640 + Sidebar.width, height: 360)
        window.makeFirstResponder(video)
    }

    @objc func toggleKeyboardPanel() { keyboardPanel.toggle() }

    private func updateKeyboardControls() {
        let title = keyboardPanel.isVisible ? "Hide Keyboard Panel" : "Show Keyboard Panel"
        keyboardMenuItem?.title = title
        keyboardToolbarItem?.label = title
        keyboardToolbarItem?.toolTip = "\(title) (⌃⌥K)"
        keyboardToolbarItem?.image = NSImage(systemSymbolName: keyboardPanel.isVisible ? "keyboard.fill" : "keyboard",
                                             accessibilityDescription: title)
    }

    @objc func toggleVideo() {
        videoHidden.toggle()
        UserDefaults.standard.set(videoHidden, forKey: "videoHidden")
        updatePlaybackControls()
        if !videoHidden { drawFrame() }
        window.makeFirstResponder(video)
    }

    @objc func toggleFrameMeter() {
        frameMeterShown.toggle()
        UserDefaults.standard.set(frameMeterShown, forKey: "frameMeterShown")
        hub.setFrameMeter("overlay", on: frameMeterShown)
        frameMeterMenuItem.title = frameMeterShown ? "Hide Frame Meter" : "Show Frame Meter"
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameMeterOverlay.layer.isHidden = !frameMeterShown
        CATransaction.commit()
        drawFrame()
        window.makeFirstResponder(video)
    }

    @objc func toggleAudio() {
        audioMuted.toggle()
        UserDefaults.standard.set(audioMuted, forKey: "audioMuted")
        updatePlaybackControls()
        window.makeFirstResponder(video)
    }

    private func updatePlaybackControls() {
        let videoTitle = videoHidden ? "Show Video" : "Hide Video"
        let audioTitle = audioMuted ? "Unmute Audio" : "Mute Audio"
        videoMenuItem.title = videoTitle
        audioMenuItem.title = audioTitle
        videoToolbarItem?.label = videoTitle
        videoToolbarItem?.toolTip = "\(videoTitle) (⌥⌘V)"
        videoToolbarItem?.image = NSImage(systemSymbolName: videoHidden ? "video.slash" : "video",
                                        accessibilityDescription: videoTitle)
        audioToolbarItem?.label = audioTitle
        audioToolbarItem?.toolTip = "\(audioTitle) (⌥⌘M)"
        audioToolbarItem?.image = NSImage(systemSymbolName: audioMuted ? "speaker.slash" : "speaker.wave.2",
                                        accessibilityDescription: audioTitle)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.isHidden = videoHidden
        CATransaction.commit()
        hiddenVideoLabel.isHidden = !videoHidden
        hub.source.setMuted(audioMuted || !hub.visible)
    }

    /// Shows the newest frame of a source that has no preview layer of its own (all but the capture card).
    @objc private func drawFrame() {
        if frameMeterShown, window.isVisible {
            frameMeterOverlay.update(hub.frameMeterSupported ? hub.sink.frameMeterReading() ?? Self.startingFrameMeter : nil,
                                     in: video.bounds, scale: window.backingScaleFactor)
        }
        guard imageLayer != nil, !videoHidden, window.isVisible else { return }
        let buffer = hub.sink.latestBuffer()
        if buffer === shownBuffer { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let buffer, let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
            imageLayer?.contents = surface
        } else {
            imageLayer?.contents = hub.sink.latestImage()
        }
        CATransaction.commit()
        shownBuffer = buffer
        if buffer != nil { hub.sink.previewDrawn() }
    }

    /// Show or hide the window. Hiding through the API (and a headless launch) also drops the Dock icon and menu bar;
    /// the user closing the window keeps them (`dock`), so a Dock click brings it back.
    func setVisible(_ visible: Bool) { setVisible(visible, dock: visible) }

    private func setVisible(_ visible: Bool, dock: Bool) {
        hub.setVisible(visible)
        if visible {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(video)
            NSApp.activate(ignoringOtherApps: true)
            if !titlesFetched { loadTitles() }
            keyboardPanel.enableHotKey()
        } else {
            keys?.releaseHeld()
            window.orderOut(nil)
            if !dock { NSApp.setActivationPolicy(.accessory) }
        }
        keyboardPanel.windowVisibilityChanged(visible)
        updatePlaybackControls()
        refresh()
    }

    @objc func hideWindow() { setVisible(false, dock: true) }

    /// Every quit path (menu, API `quit`, SIGTERM) ends in `exit`: save where the window was, for the next launch.
    func willQuit() {
        saveFrame()
        UserDefaults.standard.synchronize()
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "windowFrame")
    }

    /// The last frame, on whichever screen it was. AppKit's own autosave moves the window to the main screen when
    /// a screen's geometry changed even slightly; this keeps it wherever it still shows on a screen.
    private func restoreFrame() {
        var saved = UserDefaults.standard.string(forKey: "windowFrame").map(NSRectFromString)
        if saved == nil, let old = UserDefaults.standard.string(forKey: "NSWindow Frame ps5-app") {
            let parts = old.split(separator: " ").compactMap { Double($0) }  // "x y w h screen…" (earlier builds)
            if parts.count >= 4 { saved = NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]) }
        }
        if let frame = saved, frame.width >= 640, frame.height >= 360,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersection(frame).width >= 100 }) {
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
    }

    func refresh() {
        guard let window, let sidebar else { return }
        settings?.refreshCaptureStatus()
        let link = hub.controller.status()
        window.title = link.title
        let busy = hub.padd.busy
        if busy != nil {
            sidebar.set("Link", "paused (padd \(busy!))", color: .systemOrange)
        } else if link.connected {
            sidebar.set("Link", "\(link.host):\(link.port)", color: .systemGreen)
        } else {
            sidebar.set("Link", link.error ?? "connecting", color: .systemRed)
        }
        let bundled = hub.padd.bundled
        if let hello = link.hello {
            if let number = bundled.number, number != hello.payloadVersion {
                sidebar.set("padd", "v\(hello.versionString) · v\(bundled.version!) available", color: .systemOrange)
            } else {
                sidebar.set("padd", "v\(hello.versionString)" + (bundled.error == nil ? " · up to date" : ""))
            }
            sidebar.set("Pad", hello.padReady ? "handle \(hello.padHandle)" : "NOT ready (\(hello.addStatus))",
                        color: hello.padReady ? .labelColor : .systemRed)
            let userID = String(format: "0x%08X", UInt32(bitPattern: hello.userID))
            sidebar.set("User", hello.userName.map { "\($0) · \(userID)" } ?? userID)
        } else {
            for field in ["Pad", "User"] { sidebar.set(field, "–") }
            sidebar.set("padd", bundled.version.map { "– · v\($0) to start" } ?? "–")
        }
        if link.connected, uptimeSeconds() - pongAt > 2 {
            pongAt = uptimeSeconds()
            DispatchQueue.global().async {
                let link = try? self.hub.controller.currentLink()
                let pong = try? link?.ping(timeout: 1)
                if let link { self.hub.refreshLoginUsers(link) }
                DispatchQueue.main.async { self.pong = pong }
            }
        }
        if !link.connected { pong = nil }
        do {
            // Name each controller's user: the foreground user changes when another controller takes over.
            let pads = hub.pads, supported = link.connected && (link.hello?.flags ?? 0) & PMCP.flagPads != 0
            let connected = pads?.connected ?? [1]
            let active = pads?.active ?? 1
            sidebar.showControllers(connected.map { (pad: $0, name: hub.controllerName($0)) }, active: active,
                                    enabled: link.connected)
            let available = hub.availableUsers, signedOut = hub.signedOutUsers
            let full = connected.count >= (pads?.capacity ?? 1)
            let unknown = hub.loginUsers.map { $0.status != 0 } ?? true
            sidebar.setEnabled("addController", supported && !full && (!available.isEmpty || !signedOut.isEmpty || unknown))
            sidebar.setTip("addController", !supported ? "Needs a newer padd: press Update"
                : full ? ((pads?.capacity ?? 0) < Hub.maxControllers ? "Press Update for up to \(Hub.maxControllers) controllers"
                          : "All \(Hub.maxControllers) controllers are connected")
                : !available.isEmpty ? "Add a controller for another signed-in user and send input to it"
                : !signedOut.isEmpty ? "Nobody else is signed in: sign someone in with a new controller"
                : "Sign another user (or a guest) in on the console first")
            sidebar.setEnabled("removeController", supported && active != 1)
            sidebar.setEnabled("selectController", supported)
            controllerList = connected
        }
        if let pong {
            sidebar.set("Reports", "\(pong.reportsSent) sent, \(pong.reportFailures) failed",
                        color: pong.reportFailures > 0 ? .systemRed : .labelColor)
        } else {
            sidebar.set("Reports", "–")
        }
        let age = hub.sink.frameAge
        let camera = hub.cameraPermission
        let pbsIssue = hub.pbsIssue
        noSignalLabel.isHidden = videoHidden || (age <= 2 && pbsIssue == nil)
        noSignalLabel.stringValue = pbsIssue.map { "  \($0)  " } ?? (hub.source is CameraSource
            ? String(format: "  No HDMI signal for %.0f s · it returns when the console leaves this screen  ", age)
            : String(format: "  No video for %.0f s  ", age))
        sidebar.set("Frame age", camera == "denied" ? "no camera permission" : age < 0 ? "no frames"
                    : String(format: "%.0f ms", age * 1000),
                    color: age < 0 || age > 2 ? .systemRed : .labelColor)
        sidebar.set("Clients", "\(hub.clientCount) API · \(link.agents) holding")
        sidebar.set("Control", link.humanActive ? "you (keys held)" : "shared")
        let lease = hub.lease.json
        let queued = (lease["queue"] as? [Any])?.count ?? 0
        if let owner = lease["owner"] as? [String: Any] {
            let reason = owner["reason"] as? String ?? ""
            sidebar.set("In use by", "\(owner["client"] as? String ?? "?")" + (reason.isEmpty ? "" : " · \(reason)")
                        + (queued > 0 ? " · \(queued) waiting" : ""), color: .systemOrange)
        } else {
            sidebar.set("In use by", "nobody")
        }
        sidebar.setEnabled("forceRelease", lease["owner"] is [String: Any])
        sidebar.setEnabled("claimDetails", lease["owner"] is [String: Any] || queued > 0)
        let canRun = busy == nil && hub.padd.json["available"] as? Bool == true
        let fileManagerBusy = titlesLoading || installing != nil  // Web File Manager runs one task at a time
        sidebar.setEnabled("paddStart", canRun && !link.connected && !fileManagerBusy)
        sidebar.setEnabled("paddStop", canRun && !fileManagerBusy)
        // Only a running padd with another version than the build needs it; with padd down, Start deploys the build.
        let outdated = bundled.error == nil && link.hello.map { $0.payloadVersion != bundled.number } == true
        sidebar.setEnabled("paddUpdate", canRun && !fileManagerBusy && outdated)
        let build = bundled.name
        sidebar.setTip("paddUpdate", bundled.error
            ?? (link.hello == nil ? "padd is not running; Start deploys \(build)"
                : outdated ? "Stop padd and start \(build) from \(hub.config.repo ?? "the checkout")"
                : "padd is up to date with \(build)"))
        sidebar.setEnabled("install", installing == nil && busy == nil && !titlesLoading && !hub.padd.cli.isEmpty)
        sidebar.setEnabled("uninstall", link.connected && uninstallSheet == nil
            && (link.hello?.flags ?? 0) & PMCP.flagUninstall != 0)
        for id in ["home", "closeApp", "releaseAll"] { sidebar.setEnabled(id, link.connected) }
        let remote = (hub.source as? RemotePlaySource)?.status
        let live = remote.map { $0.phase == .streaming && $0.videoReady } ?? false
        sidebar.setEnabled("psButton", link.connected)
        sidebar.setEnabled("typeText", live && remote?.keyboardOpen == true && typeSheet == nil)
        sidebar.setEnabled("launch", link.connected && selectedTitle != nil)
        sidebar.buttons["launch"]?.bezelColor = sidebar.isEnabled("launch") ? .controlAccentColor : nil
        sidebar.setEnabled("reloadTitles", !titlesLoading && busy == nil && installing == nil)
        sidebar.titles.isEnabled = !titleList.isEmpty
        let recorder = hub.recorder
        if let recorder {
            let seconds = Int(uptimeSeconds() - recorder.started)
            sidebar.setPressesStatus(String(format: "Recording button presses %d:%02d", seconds / 60, seconds % 60))
            sidebar.setButton("record", symbol: "stop.circle.fill")
        } else {
            sidebar.setPressesStatus(nil)
            sidebar.setButton("record", symbol: "record.circle")
        }
        sidebar.buttons["record"]?.contentTintColor = recorder == nil ? nil : .systemRed
        sidebar.setEnabled("record", playing == nil)
        if let videoRecorder {
            let seconds = Int(uptimeSeconds() - videoRecorder.started)
            sidebar.setButton("video", title: String(format: "Stop %d:%02d", seconds / 60, seconds % 60),
                              symbol: "stop.circle.fill")
        } else {
            sidebar.setButton("video", title: videoSaving ? "Saving…" : "Record video", symbol: "video")
        }
        sidebar.setRecording("video", videoRecorder != nil)
        sidebar.setEnabled("video", !videoSaving)
        sidebar.setButton("play", symbol: playing == nil ? "play.fill" : "stop.fill")
        sidebar.setEnabled("play", playing != nil
            || (link.connected && recorder == nil && sidebar.recordings.selectedItem?.representedObject != nil))
        sidebar.recordings.isEnabled = playing == nil && sidebar.recordings.numberOfItems > 0
            && sidebar.recordings.itemArray.contains { $0.representedObject != nil }
        refreshStatus(link: link, canRun: canRun && !fileManagerBusy, remote: remote, owner: lease["owner"] as? [String: Any],
                      queued: queued, age: age, camera: camera)
        keyboardPanel.setKeysActive(NSApp.isActive && window.isKeyWindow && window.firstResponder === video)
    }

    /// The top of the sidebar: one line, then a message only for what needs attention.
    private func refreshStatus(link: LinkStatus, canRun: Bool, remote: RemotePlayStatus?, owner: [String: Any]?,
                               queued: Int, age: Double, camera: String) {
        let isRemote = hub.captureVideo == "remoteplay"
        let isCamera = hub.source is CameraSource
        let issue = hub.captureIssue
        let noSignal = !hub.config.headless && isCamera && age > 2
        let denied = camera == "denied"
        let padd = hub.padd.busy.map { "padd \($0)…" }
        if let padd {
            sidebar.setStatus(padd, color: .systemOrange)
        } else if !link.connected {
            sidebar.setStatus("padd not connected", color: .systemRed)
        } else if denied || noSignal || issue != nil || hub.pbsIssue != nil || (isRemote && remote?.phase != .streaming) {
            sidebar.setStatus("Connected · " + (noSignal ? "no HDMI signal" : "no video"), color: .systemOrange)
        } else {
            let version = link.hello?.versionString ?? "?"
            let bundled = hub.padd.bundled
            if let number = bundled.number, let running = link.hello?.payloadVersion, number != running {
                sidebar.setStatus("Connected · padd \(version) · update available", color: .systemOrange)
            } else {
                sidebar.setStatus("Connected · padd \(version)", color: .systemGreen)
            }
        }
        sidebar.setSource(isRemote ? "Video from Remote Play" : hub.captureVideo == "pbs" ? "Video from PBS"
                          : isCamera ? "Video from the capture card" : "No video source")

        if !link.connected, hub.padd.busy == nil {
            sidebar.connectionBanner.show(.error, title: "padd is not connected",
                                          body: "Video still works. The console takes no input until padd runs."
                                            + (link.error.map { "\n\($0)" } ?? ""),
                                          actionTitle: "Start padd…", selector: #selector(startPadd), enabled: canRun)
        } else if denied {
            sidebar.connectionBanner.show(.attention, title: "No camera permission",
                                          body: "Allow PS5 MCP in System Settings, under Privacy & Security, Camera.")
        } else if let issue, !isRemote {
            sidebar.connectionBanner.show(.attention, title: "No video", body: issue, actionTitle: "Settings…",
                                          selector: #selector(showSettings))
        } else if noSignal {
            sidebar.connectionBanner.show(.attention, title: "No HDMI signal",
                                          body: "This console screen drops HDMI. The picture returns when the console leaves it.")
        } else {
            sidebar.connectionBanner.hide()
        }

        if isRemote {
            let streaming = remote?.phase == .streaming
            sidebar.remotePlayBox.show(streaming ? .neutral : .attention, title: "Remote Play",
                                       body: remote?.summary ?? issue ?? "Set up Remote Play.")
        } else {
            sidebar.remotePlayBox.hide()
        }
        sidebar.setEnabled("reconnect", remotePlayCanReconnect)

        if let owner {
            let reason = owner["reason"] as? String ?? ""
            sidebar.agentBanner.show(.info, title: "\(owner["client"] as? String ?? "An agent") holds the console",
                                     body: (reason.isEmpty ? "" : reason + " · ") + (queued > 0 ? "\(queued) waiting. " : "")
                                        + "Your keyboard still works.",
                                     actionTitle: "Claim and Queue…", selector: #selector(showClaims))
        } else {
            sidebar.agentBanner.hide()
        }

        // captureIssue also comes through hub.notice: it has its own message above.
        let text = hub.notice == issue ? nil : hub.notice
        if text != shownNotice {
            shownNotice = text
            shownNoticeAt = uptimeSeconds()
        }
        let asks = text?.hasPrefix(Hub.assignNoticePrefix) == true
        if let text, asks || uptimeSeconds() - shownNoticeAt < 10 {
            sidebar.noticeBanner.show(asks ? .attention : .neutral, title: asks ? "The PS5 needs an answer" : "", body: text)
        } else {
            sidebar.noticeBanner.hide()
        }
        if asks { hub.clearAnsweredAssignNotice() }
    }

    private var remotePlayCanReconnect: Bool {
        guard hub.captureVideo == "remoteplay", let remote = hub.source as? RemotePlaySource else { return false }
        return ![.connecting, .applyingAdmission, .waitingForVideo].contains(remote.status.phase)
    }

    @objc func reconnectRemotePlay() {
        do {
            guard hub.captureVideo == "remoteplay" else { return }
            if let owner = hub.lease.json["owner"] as? [String: Any] {
                throw RemotePlaySetupError("The console is claimed by \(owner["client"] as? String ?? "another client"). Wait for its claim to be released.")
            }
            try restartCapture(video: "remoteplay", audio: "remoteplay")
        } catch { hub.notice = (error as? BadInput)?.description ?? error.localizedDescription }
        window.makeFirstResponder(video)
    }

    @objc func setUpRemotePlay() {
        showSettings()
        settings?.setUpRemotePlay()
    }

    /// The commands that have no button of their own, and the rare ones.
    @objc func showMoreMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, action) in [
            ("Release All Input", #selector(releaseAll)), ("-", nil),
            ("Force Release Agent…", #selector(forceRelease)), ("Claim and Queue…", #selector(showClaims)), ("-", nil),
            ("Reload Games/Apps", #selector(reloadTitles)), ("Install…", #selector(installFile)),
            ("Uninstall…", #selector(showUninstall)), ("-", nil),
            ("Start padd…", #selector(startPadd)), ("Update padd…", #selector(updatePadd)), ("Stop padd…", #selector(stopPadd)),
        ] as [(String, Selector?)] {
            guard let action else { menu.addItem(.separator()); continue }
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.items.first?.keyEquivalent = "."
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let sidebar else { return true }
        func enabled(_ id: String) -> Bool { sidebar.isEnabled(id) }
        switch menuItem.action {
        case #selector(launchTitle):
            menuItem.title = selectedTitle.map { "Launch \($0.name)" } ?? "Launch Game/App"
            return enabled("launch")
        case #selector(closeApp): return enabled("closeApp")
        case #selector(home): return enabled("home")
        case #selector(psButton): return enabled("psButton")
        case #selector(typeText):
            menuItem.toolTip = hub.captureVideo == "remoteplay" ? nil : "Needs Remote Play as the video source"
            return enabled("typeText")
        case #selector(releaseAll): return enabled("releaseAll")
        case #selector(forceRelease): return enabled("forceRelease")
        case #selector(showClaims): return enabled("claimDetails")
        case #selector(toggleRecording):
            menuItem.title = hub.recorder == nil ? "Record Button Presses" : "Stop Recording Button Presses…"
            return enabled("record")
        case #selector(toggleVideoRecording):
            menuItem.title = videoRecorder == nil ? "Record Video" : "Stop Recording Video…"
            return enabled("video")
        case #selector(togglePlayback):
            menuItem.title = playing == nil ? "Play Recording" : "Stop Playback"
            return enabled("play")
        case #selector(reloadTitles): return enabled("reloadTitles")
        case #selector(installFile):
            menuItem.title = installing == nil ? "Install…" : "Installing…"
            return enabled("install")
        case #selector(showUninstall): return enabled("uninstall")
        case #selector(startPadd): return enabled("paddStart")
        case #selector(updatePadd):
            menuItem.toolTip = sidebar.tips["paddUpdate"]
            return enabled("paddUpdate")
        case #selector(stopPadd): return enabled("paddStop")
        case #selector(addController(_:)):
            menuItem.toolTip = sidebar.tips["addController"]
            return enabled("addController")
        case #selector(removeController): return enabled("removeController")
        case #selector(chooseController(_:)):
            let pad = menuItem.tag
            menuItem.title = "Controller \(pad)" + (hub.controllerName(pad).map { " (\($0))" } ?? "")
            menuItem.state = controllerList.count > 1 && hub.pads?.active == pad ? .on : .off
            return enabled("selectController") && controllerList.contains(pad)
        case #selector(reconnectRemotePlay): return remotePlayCanReconnect
        case #selector(setUpRemotePlay): return !hub.host.isEmpty
        default: return true
        }
    }

    private func confirm(_ title: String, _ text: String, _ action: String, destructive: Bool = false,
                         warning: String? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let button = alert.addButton(withTitle: action)
        button.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        if let warning {
            let box = Banner(target: self)
            box.show(.attention, title: "Your DualSense may turn off", body: warning, wrap: 290)
            box.frame = NSRect(origin: .zero, size: NSSize(width: 310, height: box.fittingSize.height))
            alert.accessoryView = box
        }
        defer { window.makeFirstResponder(video) }
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func background(_ work: @escaping () throws -> Void) {
        window.makeFirstResponder(video)
        DispatchQueue.global().async {
            do { try work() } catch { self.hub.notice = "\(error)" }
            DispatchQueue.main.async { self.refresh() }
        }
    }

    @objc func showAbout() {
        let credits = NSMutableAttributedString(string: "Controls a PS5 through a virtual DualSense and sees it through "
                                                + "an HDMI capture card.\n\n", attributes: [.font: NSFont.systemFont(ofSize: 11)])
        credits.append(NSAttributedString(string: AppVersion.github, attributes: [
            .link: URL(string: AppVersion.github)!, .font: NSFont.systemFont(ofSize: 11)]))
        credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: AppVersion.short + (hub.padd.bundled.version.map { " (padd \($0))" } ?? ""),
            .version: "build \(AppVersion.build)",
            .credits: credits,
        ])
    }

    @objc func showSettings() {
        if settings == nil {
            settings = SettingsWindow(hub: hub) { [weak self] in
                self?.reloadTitles()  // another console: fetch its games/apps
                self?.refresh()
            } onFloatingChanged: { [weak self] in
                self?.keyboardPanel.applyFloating()
            }
        }
        settings?.show()
    }

    private static let dualSenseWarning = "If the PS5 asks \"Who's using this controller?\", the virtual pad answers it. "
        + "Then press the DualSense's PS button and pick the same user."

    @objc func startPadd() {
        guard confirm("Start padd on \(hub.host)?",
                      "This uploads \(hub.padd.bundled.name) through Payload Manager and starts it once. "
                      + "The run is archived under results/.", "Start", warning: Self.dualSenseWarning)
        else { return }
        hub.notice = "Starting padd…"
        background { _ = try self.hub.padd.run("start", firmware: nil) }
    }

    @objc func updatePadd() {
        let bundled = hub.padd.bundled.version ?? "?"
        let running = hub.controller.status().hello.map { "padd v\($0.versionString)" } ?? "padd, if it runs,"
        guard confirm("Update padd on \(hub.host) to v\(bundled)?",
                      "\(running.prefix(1).uppercased() + running.dropFirst()) stops, which releases input and removes the "
                      + "virtual pad. Then \(hub.padd.bundled.name) uploads through Payload Manager and starts once. "
                      + "Both runs are archived under results/.", "Update", warning: Self.dualSenseWarning)
        else { return }
        hub.notice = "Updating padd…"
        background { _ = try self.hub.padd.run("update", firmware: nil) }
    }

    @objc func stopPadd() {
        guard confirm("Stop padd?", "padd releases input, removes the virtual pad and exits. The run is archived.",
                      "Stop", destructive: true) else { return }
        hub.notice = "Stopping padd…"
        background { _ = try self.hub.padd.run("stop", firmware: nil) }
    }

    @objc func home() {
        background { _ = try self.hub.command("home", "", link: self.hub.controller.currentLink()) }
    }

    private var typeSheet: NSAlert?
    private var psClicks = 0

    @objc func psButton() {
        // The same key as P, so losing focus releases it too; only the latest click ends the press.
        let hold = NSEvent.modifierFlags.contains(.option) ? 1.0 : 0.1
        psClicks &+= 1
        let click = psClicks
        keys.handle("p", down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard let self, self.psClicks == click else { return }
            self.keys.handle("p", down: false)
        }
    }

    /// The PS5 hands its keyboard to Remote Play ("Use the keyboard on your Remote Play device"): type here.
    @objc func typeText() {
        guard typeSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Type on the PS5"
        alert.informativeText = "Send replaces the text field's content and closes the keyboard. Hand Back shows the "
            + "PS5's own keyboard, for the controller."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Text for the PS5"
        field.setAccessibilityLabel("Text for the PS5")
        alert.accessoryView = field
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Hand Back")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        typeSheet = alert
        refresh()
        alert.beginSheetModal(for: window) { response in
            self.typeSheet = nil
            let text = field.stringValue
            let epoch = self.hub.controller.inputEpoch
            switch response {
            case .alertFirstButtonReturn:
                guard text.utf8.count <= Int(RP_KEYBOARD_TEXT_MAX), !text.utf8.contains(0) else {
                    self.hub.notice = "Text is too long for the PS5 keyboard (\(RP_KEYBOARD_TEXT_MAX) bytes at most)."
                    return
                }
                self.background {
                    do {
                        let (result, submitted) = try self.hub.setRemoteText(text, submit: true, timeout: 3,
                                                                             epoch: epoch, human: true)
                        if !submitted { self.hub.notice = "The PS5 did not confirm the text (\(result)); it was not submitted." }
                    } catch { throw BadInput("Type: \(remotePlayInputMessage(error))") }
                }
            case .alertSecondButtonReturn:
                self.background {
                    do { try self.hub.closeRemoteKeyboard(accept: false, epoch: epoch, human: true) }
                    catch { throw BadInput("Hand back: \(remotePlayInputMessage(error))") }
                }
            default:
                self.window.makeFirstResponder(self.video)
                self.refresh()
            }
        }
    }

    /// A row of the sidebar's controller list, or the Controllers menu: input goes to that controller.
    @objc func chooseController(_ sender: Any?) {
        let pad = (sender as? NSButton)?.tag ?? (sender as? NSMenuItem)?.tag ?? 0
        guard pad >= 1, pad != hub.pads?.active else { return }
        background {
            let status = try self.hub.selectPad(pad, link: self.hub.controller.currentLink())
            if status != 0 { self.hub.notice = "Controller \(pad): \(PMCP.padsText(.selectPad, status))" }
        }
    }

    /// Sidebar's +. A menu only when there is a choice: signed-in users first, then profiles a controller can sign in.
    @objc func addController(_ sender: Any?) {
        let available = hub.availableUsers, signedOut = hub.signedOutUsers
        if available.count + signedOut.count <= 1 {
            // The one free signed-in user is who padd picks anyway, and padd before 1.8 takes no user id.
            connectController(user: available.isEmpty ? signedOut.first?.id : nil)
            return
        }
        let menu = NSMenu()
        func add(_ title: String, _ user: Int32) {
            let item = NSMenuItem(title: title, action: #selector(connectControllerUser), keyEquivalent: "")
            item.target = self
            item.tag = Int(user)
            menu.addItem(item)
        }
        for user in available { add("Add controller for \(LoginUsers.label(user))", user.id) }
        if !available.isEmpty, !signedOut.isEmpty { menu.addItem(.separator()) }
        for user in signedOut { add("Sign in \(user.name) with a new controller", user.id) }
        if let button = sender as? NSButton {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc func connectControllerUser(_ item: NSMenuItem) { connectController(user: Int32(item.tag)) }

    private func connectController(user: Int32?) {
        background {
            let status = try self.hub.connectPad(self.hub.controller.currentLink(), user: user)
            if status != 0 { self.hub.notice = "New controller: \(PMCP.padsText(.pad, status))" }
        }
    }

    /// The − on the selected controller's row.
    @objc func removeController() {
        guard let pad = hub.pads?.active, pad != 1 else { return }
        background {
            let status = try self.hub.disconnectPad(self.hub.controller.currentLink(), pad: pad)
            if status != 0 { self.hub.notice = "Controller \(pad): \(PMCP.padsText(.pad, status))" }
        }
    }

    @objc func closeApp() {
        guard confirm("Close the running game or app?", "Unsaved progress is lost. The console returns to the home screen.",
                      "Close", destructive: true) else { return }
        background { _ = try self.hub.command("close", "", link: self.hub.controller.currentLink()) }
    }

    // MARK: games

    private var selectedTitle: Title? {
        guard let id = sidebar?.titles.selectedItem?.representedObject as? String else { return nil }
        return titleList.first { $0.id == id }
    }

    /// Fills the list from the cache at once, then refreshes it from the console (only new titles are fetched).
    private func loadTitles() {
        titlesFetched = true
        if titleList.isEmpty { titleList = library.cached() }
        reloadTitles()
    }

    @objc func popupChanged() {
        refresh()
        window.makeFirstResponder(video)
    }

    /// Web File Manager runs one task at a time, and padd Start and Install use it too: they never overlap.
    @objc func reloadTitles() {
        guard !titlesLoading, hub.padd.busy == nil, installing == nil else { return }
        titlesLoading = true
        titlesError = nil
        fillTitles()
        window.makeFirstResponder(video)
        DispatchQueue.global().async {
            let result = Result { try self.library.refresh() }
            DispatchQueue.main.async {
                self.titlesLoading = false
                switch result {
                case .success(let titles): self.titleList = titles
                case .failure(let error):
                    self.titlesError = error.localizedDescription
                    say("games/apps: \(error)")
                }
                self.fillTitles()
                self.refresh()
            }
        }
    }

    private func fillTitles() {
        let popup = sidebar.titles
        let previous = (popup.selectedItem?.representedObject as? String)
            ?? UserDefaults.standard.string(forKey: "launchTitle")
        popup.removeAllItems()
        if titleList.isEmpty {
            popup.addItem(withTitle: titlesLoading ? "Loading games/apps…" : titlesError != nil
                          ? "Console not reachable" : "No games/apps found")
            popup.toolTip = titlesError
            return
        }
        for title in titleList {
            let item = NSMenuItem(title: title.name, action: nil, keyEquivalent: "")
            item.representedObject = title.id
            item.toolTip = title.id
            if let icon = title.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            popup.menu?.addItem(item)
        }
        if let previous, let item = popup.itemArray.first(where: { $0.representedObject as? String == previous }) {
            popup.select(item)
        }
        popup.toolTip = titlesError.map { "Showing the saved list: \($0)" } ?? selectedTitle?.id
    }

    @objc func launchTitle() {
        guard let title = selectedTitle else { return }
        UserDefaults.standard.set(title.id, forKey: "launchTitle")
        hub.notice = "Launching \(title.name)…"
        background {
            let status = try self.hub.command("launch", title.id, link: self.hub.controller.currentLink())
            self.hub.notice = status == 0 ? "Launched \(title.name)."
                : String(format: "Launch of %@ failed (status 0x%08X).", title.name, UInt32(bitPattern: status))
        }
    }

    // MARK: install / uninstall

    /// Runs `ps5mcp install` (the Python installer, shared with the MCP tool) and shows its progress lines.
    @objc func installFile() {
        window.makeFirstResponder(video)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["pkg", "elf"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = false
        panel.message = "Choose a .pkg package to install, or an .elf payload to add to Payload Manager"
        panel.prompt = "Install"
        panel.beginSheetModal(for: window) { response in
            defer { self.window.makeFirstResponder(self.video) }
            guard response == .OK, let url = panel.url else { return }
            var run = false
            if url.pathExtension.lowercased() == "elf" {
                let alert = NSAlert()
                alert.messageText = "Install \(url.lastPathComponent)?"
                alert.informativeText = "It is added to Payload Manager's payloads on \(self.hub.host)."
                alert.addButton(withTitle: "Install and Run")
                alert.addButton(withTitle: "Install Only")
                alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn: run = true
                case .alertSecondButtonReturn: run = false
                default: return
                }
            }
            self.runInstall(url, run: run)
        }
    }

    private func runInstall(_ url: URL, run: Bool) {
        let base = hub.padd.cli
        guard !base.isEmpty, installing == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: base[0])
        process.arguments = Array(base.dropFirst()) + ["install", url.path, "--host", hub.host]
            + (run ? ["--run"] : [])
        process.environment = hub.padd.cliEnvironment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        var lastLine = ""
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let line = text.split(separator: "\n").last.map(String.init), !line.isEmpty else { return }
            DispatchQueue.main.async {
                lastLine = line
                self.hub.notice = line
            }
        }
        process.terminationHandler = { process in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.installing = nil
                if process.terminationStatus != 0 && !lastLine.hasPrefix("install failed") {
                    self.hub.notice = "Install of \(url.lastPathComponent) failed (exit \(process.terminationStatus))."
                }
                if url.pathExtension.lowercased() == "pkg" && process.terminationStatus == 0 { self.reloadTitles() }
                self.refresh()
            }
        }
        do {
            try process.run()
            installing = process
            hub.notice = "Installing \(url.lastPathComponent)…"
        } catch {
            hub.notice = "Could not start the installer: \(error.localizedDescription)"
        }
        refresh()
    }

    @objc func showUninstall() {
        window.makeFirstResponder(video)
        let candidates = titleList.filter { !$0.id.hasPrefix("NPXS") }  // system apps
        guard !candidates.isEmpty else {
            hub.notice = "No games/apps to uninstall. Reload the list first."
            return
        }
        let sheet = UninstallSheet(titles: candidates) { [weak self] chosen in
            guard let self else { return }
            self.uninstallSheet = nil
            self.window.makeFirstResponder(self.video)
            if !chosen.isEmpty { self.confirmUninstall(chosen) }
            self.refresh()
        }
        uninstallSheet = sheet
        window.beginSheet(sheet.window)
        refresh()
    }

    private func confirmUninstall(_ chosen: [Title]) {
        let names = chosen.prefix(8).map { "• \($0.name)" }.joined(separator: "\n")
            + (chosen.count > 8 ? "\n…and \(chosen.count - 8) more" : "")
        guard confirm("Uninstall \(chosen.count == 1 ? chosen[0].name : "\(chosen.count) games/apps")?",
                      "\(names)\n\nTheir data on the console is deleted. For titles ShadowMountPlus manages, their "
                      + "source folder or image is deleted too. This cannot be undone.", "Uninstall", destructive: true)
        else { return }
        hub.notice = "Uninstalling \(chosen.count) game(s)/app(s)…"
        background {
            var failed: [String] = []
            for (index, title) in chosen.enumerated() {
                do {
                    // ShadowMountPlus titles: padd answers EBUSY/EINPROGRESS while their source is being deleted.
                    let deadline = Date().addingTimeInterval(90)
                    var status: Int32
                    repeat {
                        self.hub.notice = "Uninstalling \(title.name) (\(index + 1) of \(chosen.count))…"
                        status = try self.hub.command("uninstall", title.id, link: self.hub.controller.currentLink())
                        if PMCP.uninstallRetry.contains(status) { Thread.sleep(forTimeInterval: 2) }
                    } while PMCP.uninstallRetry.contains(status) && Date() < deadline
                    if status != 0 { failed.append("\(title.name): \(PMCP.uninstallText(status))") }
                } catch {
                    failed.append("\(title.name): \(error)")
                }
            }
            let done = chosen.count - failed.count
            self.hub.notice = failed.isEmpty
                ? "Uninstall requested for \(done) game(s)/app(s); the console removes them in the background."
                : "Uninstall requested for \(done). Not uninstalled: \(failed.joined(separator: "; "))."
            // The removal finishes after the request; list again once it has had time to.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.reloadTitles() }
        }
    }

    // MARK: recordings

    private func fillRecordings(select name: String? = nil) {
        let popup = sidebar.recordings
        let previous = name ?? popup.selectedItem?.representedObject as? String
        popup.removeAllItems()
        let saved = Recordings.list(hub.stateDir)
        guard !saved.isEmpty else { popup.addItem(withTitle: "No recordings yet"); return }
        popup.addItem(withTitle: "Button recordings…")  // nothing plays until one is picked
        popup.menu?.addItem(.separator())
        for recording in saved {
            let item = NSMenuItem(title: recording.name, action: nil, keyEquivalent: "")
            item.representedObject = recording.name
            let seconds = Double(recording.durationMS) / 1000
            let title = NSMutableAttributedString(string: recording.name + "  ",
                                                  attributes: [.font: NSFont.menuFont(ofSize: 0)])
            title.append(NSAttributedString(string: String(format: "%.1f s", seconds), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = title
            popup.menu?.addItem(item)
        }
        if let previous, let item = popup.itemArray.first(where: { $0.representedObject as? String == previous }) {
            popup.select(item)
        }
    }

    @objc func toggleRecording() {
        window.makeFirstResponder(video)
        guard let recorder = hub.recorder else {
            hub.recorder = InputRecorder(current: hub.controller.current().merged)
            hub.notice = "Recording the console input. Press Stop (⌘R) to save it."
            return
        }
        hub.recorder = nil
        let steps = recorder.steps()
        guard !steps.isEmpty else { hub.notice = "Nothing recorded: no input reached the console."; return }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        var name = "rec-" + stamp.string(from: Date())
        while true {
            guard let answer = askName(name) else { hub.notice = "Recording discarded."; return }
            name = answer
            do {
                _ = try Recordings.save(hub.stateDir, name: name, steps: steps, source: "app")
                fillRecordings(select: name)
                hub.notice = "Saved recording \(name) (\(steps.count) steps)."
                return
            } catch {
                hub.notice = "\(error)"
            }
        }
    }

    /// The name for a new recording, or nil to discard it. Saving over a recording asks first.
    private func askName(_ suggestion: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Save recording"
        alert.informativeText = "Agents can replay it with play_recording. Use letters, digits, - and _."
        let field = NSTextField(string: suggestion)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        defer { window.makeFirstResponder(video) }
        while alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !Recordings.isValidName(name) {
                alert.informativeText = "\"\(name)\" can't be used. Use 1 to 64 letters, digits, - and _."
                continue
            }
            if Recordings.list(hub.stateDir).contains(where: { $0.name == name }),
               !confirm("Replace \(name)?", "A recording with this name exists.", "Replace") {
                continue
            }
            return name
        }
        return nil
    }

    @objc func togglePlayback() {
        window.makeFirstResponder(video)
        if playing != nil { stopPlayback = true; return }
        guard let name = sidebar.recordings.selectedItem?.representedObject as? String else { return }
        let steps: [[String: Any]]
        let states: [(PadState, Double)]
        do {
            steps = try Recordings.load(hub.stateDir, name: name)
            states = try steps.map { (try Recordings.state($0), Double($0["duration_ms"] as? Int ?? 0) / 1000) }
        } catch {
            hub.notice = "\(error)"
            return
        }
        let total = states.reduce(0) { $0 + $1.1 }
        guard total <= Recordings.maxSeconds else {
            hub.notice = "\(name) is longer than \(Int(Recordings.maxSeconds / 60)) minutes."
            return
        }
        playing = name
        stopPlayback = false
        hub.notice = String(format: "Playing %@ (%.1f s)…", name, total)
        Thread.detachNewThread {
            var deadline = uptimeSeconds()
            var outcome = "Played \(name)."
            do {
                for (state, seconds) in states {
                    if self.stopPlayback { throw CancellationError() }
                    try self.hub.controller.set(client: "play", state)
                    deadline += seconds
                    while uptimeSeconds() < deadline {
                        if self.stopPlayback { throw CancellationError() }
                        // A key going down cancels every agent hold, this one included.
                        if !state.isNeutral && self.hub.controller.current().agents["play"] == nil {
                            throw BadInput("you took control with the keyboard")
                        }
                        Thread.sleep(forTimeInterval: min(0.01, max(0, deadline - uptimeSeconds())))
                    }
                }
            } catch is CancellationError {
                outcome = "Stopped \(name)."
            } catch {
                outcome = "Stopped \(name): \(error)."
            }
            self.hub.controller.release(client: "play")
            DispatchQueue.main.async {
                self.playing = nil
                self.hub.notice = outcome
            }
        }
    }

    // MARK: snapshot

    /// Saves the current frame straight to the capture folder from Settings (Desktop by default), no dialog.
    @objc func saveSnapshot() {
        guard let image = hub.sink.latestImage() else {
            hub.notice = "No frame to save yet."
            return
        }
        let folder = captureFolder
        let name = "PS5 \(Self.stamp())"
        var url = folder.appendingPathComponent(name + ".png")
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {  // two snapshots in the same second
            url = folder.appendingPathComponent("\(name) \(copy).png")
            copy += 1
        }
        do {
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw BadInput("could not encode the frame")
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url)
            hub.notice = "Saved snapshot to \(folder.lastPathComponent)/\(url.lastPathComponent)."
        } catch {
            hub.notice = "Snapshot not saved: \(error.localizedDescription)"
        }
    }

    // MARK: video

    private static func stamp() -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return format.string(from: Date())
    }

    /// Records to a file in the state directory; Stop asks where to save it.
    @objc func toggleVideoRecording() {
        defer { refresh(); window.makeFirstResponder(video) }
        guard let recorder = videoRecorder else {
            let url = URL(fileURLWithPath: hub.stateDir).appendingPathComponent("video-\(UUID().uuidString).mp4")
            do {
                let recorder = try VideoRecorder(url: url, audioFormat: hub.sink.audioFormat)
                videoRecorder = recorder
                hub.sink.record(recorder)
                hub.notice = hub.sink.audioFormat == nil
                    ? "Recording video (no audio). Press Stop (⇧⌘R) to save it."
                    : "Recording video and audio. Press Stop (⇧⌘R) to save it."
            } catch {
                hub.notice = "Could not record video: \(error.localizedDescription)"
            }
            return
        }
        let name = "PS5 \(Self.stamp()).mp4"
        stopVideo(recorder) { [weak self] reason in
            guard let self else { return }
            if let reason {
                self.videoSaved("Video not saved: \(reason)")
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = name
            panel.directoryURL = captureFolder
            panel.beginSheetModal(for: self.window) { response in
                defer { self.window.makeFirstResponder(self.video) }
                guard response == .OK, let url = panel.url else {
                    try? FileManager.default.removeItem(at: recorder.url)
                    try? FileManager.default.removeItem(at: VideoRecorder.meterCSV(for: recorder.url))
                    self.videoSaved("Video discarded.")
                    return
                }
                self.videoSaved(self.moveVideo(recorder.url, to: url))
            }
        }
    }

    /// A reconnect starts a new clock. Save the old timeline before accepting a new recording.
    /// A network source's stream ended (Remote Play or PBS): stop playback and save any recording.
    func remotePlayStreamLost(completion: (() -> Void)? = nil) {
        let label = hub.captureVideo == "pbs" ? "PBS" : "Remote Play"
        stopPlayback = true
        hub.controller.release(client: "play")
        if let completion { afterVideoSaved.append(completion) }
        if videoSaving { return }
        guard let recorder = videoRecorder else {
            let ready = afterVideoSaved
            afterVideoSaved.removeAll()
            ready.forEach { $0() }
            return
        }
        stopVideo(recorder) { [weak self] reason in
            guard let self else { return }
            if let reason { self.videoSaved("\(label) recording stopped: \(reason)"); return }
            // Keep the finished file at its unique state-directory path; never overwrite another recording.
            self.videoSaved("\(label) disconnected. Recording saved to \(recorder.url.path)")
        }
    }

    private func stopVideo(_ recorder: VideoRecorder, _ done: @escaping (String?) -> Void) {
        hub.sink.record(nil)
        videoRecorder = nil
        videoSaving = true
        refresh()
        recorder.finish(done)
    }

    private func videoSaved(_ notice: String) {
        videoSaving = false
        hub.notice = notice
        refresh()
        let ready = afterVideoSaved
        afterVideoSaved.removeAll()
        ready.forEach { $0() }
    }

    /// Moves the finished file into place; returns the notice to show.
    private func moveVideo(_ from: URL, to url: URL) -> String {
        let csv = VideoRecorder.meterCSV(for: from)
        do {
            try? FileManager.default.removeItem(at: url)  // the save panel already asked to replace it
            try FileManager.default.moveItem(at: from, to: url)
        } catch {
            try? FileManager.default.removeItem(at: from)
            try? FileManager.default.removeItem(at: csv)
            return "Video not saved: \(error.localizedDescription)"
        }
        // Frame times from a video this one replaced would no longer match it.
        let target = VideoRecorder.meterCSV(for: url)
        try? FileManager.default.removeItem(at: target)
        guard FileManager.default.fileExists(atPath: csv.path) else { return "Saved video to \(url.lastPathComponent)." }
        // The video is safe by now: a CSV that cannot move stays where it is and does not undo the save.
        do {
            try FileManager.default.moveItem(at: csv, to: target)
            return "Saved video and frame times to \(url.lastPathComponent)."
        } catch {
            return "Saved video to \(url.lastPathComponent). Frame times stayed at \(csv.path)."
        }
    }

    /// For an agent that claimed the console and will not let go (its claim only lapses after `idle_s`).
    @objc func forceRelease() {
        defer { window.makeFirstResponder(video) }
        guard let owner = hub.lease.json["owner"] as? [String: Any] else { return }
        let client = owner["client"] as? String ?? "the agent"
        let held = Int(owner["held_s"] as? Double ?? 0)
        let queued = (hub.lease.json["queue"] as? [[String: Any]]) ?? []
        let next = (queued.first?["client"] as? String).map { "\($0) will use it next." }
            ?? "Nobody is waiting for it."
        guard confirm("Force release \(client)?",
                      "\(client) has held the PS5 for \(held < 60 ? "\(held) s" : "\(held / 60) min").\n\(next)",
                      "Force Release", destructive: true) else { return }
        guard let evicted = hub.forceRelease(client: owner["client"] as? String) else {
            hub.notice = "\(client) no longer holds the PS5; nothing released."
            return refresh()
        }
        hub.notice = "Force-released \(evicted)."
        refresh()
    }

    /// The holder's reason and process, and the queue in order, up to date while it is open.
    @objc func showClaims() {
        guard claimsSheet == nil else { return }
        let sheet = ClaimsSheet(hub: hub) { [weak self] in self?.forceRelease() }
        claimsSheet = sheet
        sheet.present(on: window) { [weak self] in
            self?.claimsSheet = nil
            if let self { self.window.makeFirstResponder(self.video) }
        }
    }

    @objc func releaseAll() {
        hub.controller.releaseAll()
        window.makeFirstResponder(video)
    }

    // Closing the window keeps the hub (capture, padd link, API) running; Quit ends it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        setVisible(false, dock: true)
        return false
    }

    /// A Dock click, or opening the app again from Finder, Spotlight or `open`, while the window is hidden (by the user,
    /// the API or a headless launch) brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !window.isVisible { setVisible(true) }
        return true
    }

    func windowDidResignKey(_ notification: Notification) { keys?.releaseHeld() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting mid-recording keeps the video: it goes to the capture folder without asking.
        if let recorder = videoRecorder {
            let folder = captureFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("PS5 \(Self.stamp()).mp4")
            stopVideo(recorder) { [weak self] reason in
                if reason == nil { _ = self?.moveVideo(recorder.url, to: url) }
                self?.hub.quit()
            }
            return .terminateLater
        }
        hub.quit()
        return .terminateNow
    }
}
