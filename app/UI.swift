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

final class Sidebar: NSStackView {
    let fields = ["Link", "padd", "Pad", "User", "Reports", "Frame age", "Clients", "Control", "In use by"]
    private var values: [String: NSTextField] = [:]
    let notice = NSTextField(wrappingLabelWithString: "")
    /// Keyed by id, not title: titles change ("Record" / "Stop") and repeat across sections.
    var buttons: [String: NSButton] = [:]
    let titles = NSPopUpButton(frame: .zero, pullsDown: false)
    let recordings = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keyboard = NSGridView()
    private let keyboardToggle = NSButton()

    init(target: AnyObject) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        let grid = NSGridView()
        grid.rowSpacing = 4
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
        // Status, then padd, then what acts on the console as it is now (Console), on a chosen game (Launch),
        // on the picture and input (Capture), on saved input (Recordings) and on what is installed (Install).
        addArrangedSubview(header("Status"))
        addArrangedSubview(grid)
        section("padd")
        full(row([button("paddStart", "Start", "play.fill", #selector(AppDelegate.startPadd), target),
                  button("paddStop", "Stop", "stop.fill", #selector(AppDelegate.stopPadd), target)]))

        section("Console")
        let close = button("closeApp", "Close game/app", "xmark.circle", #selector(AppDelegate.closeApp), target)
        close.toolTip = "Close the game or app that is running now"
        full(row([button("home", "Home", "house", #selector(AppDelegate.home), target), close]))
        let release = button("releaseAll", "Release all input", "hand.raised", #selector(AppDelegate.releaseAll), target)
        release.toolTip = "Release every held button, stick and trigger (⌘.)"
        full(release)

        section("Launch")
        for popup in [titles, recordings] {
            popup.refusesFirstResponder = true  // keys stay with the video
            popup.lineBreakMode = .byTruncatingTail
            popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        titles.setAccessibilityLabel("Game or app to launch")
        let reload = button("reloadTitles", "", "arrow.clockwise", #selector(AppDelegate.reloadTitles), target)
        reload.toolTip = "Reload the installed games and apps from the console"
        reload.setAccessibilityLabel("Reload games and apps")
        reload.setContentHuggingPriority(.required, for: .horizontal)
        full(row([titles, reload], equal: false))
        let launch = button("launch", "Launch", "play.circle", #selector(AppDelegate.launchTitle), target)
        launch.toolTip = "Launch the selected game or app (⌘L)"
        full(launch)

        section("Capture")
        let record = button("record", "Record", "record.circle", #selector(AppDelegate.toggleRecording), target)
        record.toolTip = "Record the console input (keyboard and agents) until you press Stop (⌘R)"
        let snapshot = button("snapshot", "Snapshot", "camera", #selector(AppDelegate.saveSnapshot), target)
        snapshot.toolTip = "Save the current frame as a PNG (⌘S)"
        full(row([record, snapshot]))

        section("Recordings")
        recordings.setAccessibilityLabel("Recording to play")
        let play = button("play", "Play", "play.fill", #selector(AppDelegate.togglePlayback), target)
        play.setContentHuggingPriority(.required, for: .horizontal)
        full(row([recordings, play], equal: false))

        section("Install")
        let install = button("install", "Install…", "square.and.arrow.down", #selector(AppDelegate.installFile), target)
        install.toolTip = "Install a .pkg package or an .elf payload from this Mac"
        let uninstall = button("uninstall", "Uninstall…", "trash", #selector(AppDelegate.showUninstall), target)
        uninstall.toolTip = "Choose installed games/apps to uninstall (needs padd 1.3)"
        full(row([install, uninstall]))

        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .secondaryLabelColor
        notice.preferredMaxLayoutWidth = 232
        setCustomSpacing(10, after: arrangedSubviews.last!)
        addArrangedSubview(notice)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        addArrangedSubview(spacer)

        keyboardToggle.setButtonType(.pushOnPushOff)
        keyboardToggle.bezelStyle = .disclosure
        keyboardToggle.title = ""
        keyboardToggle.refusesFirstResponder = true
        keyboardToggle.target = self
        keyboardToggle.action = #selector(toggleKeyboard)
        keyboardToggle.setAccessibilityLabel("Keyboard controls")
        let keyboardHeader = header("Keyboard controls")
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleKeyboardFromLabel))
        keyboardHeader.addGestureRecognizer(click)
        addArrangedSubview(row([keyboardToggle, keyboardHeader], equal: false, spacing: 2))
        keyboard.rowSpacing = 5
        keyboard.columnSpacing = 12
        for (key, action) in [
            ("↑ ↓ ← →", "D-pad"),
            ("Enter / Space", "✕ Cross"),
            ("Esc / Backspace", "○ Circle"),
            ("[", "□ Square"),
            ("]", "△ Triangle"),
            ("Q", "L1"), ("E", "R1"),
            ("Z", "L2"), ("C", "R2"),
            ("W A S D", "Left stick"),
            ("I J K L", "Right stick"),
            ("Tab", "Options"),
            ("T", "Touchpad"),
            ("H", "Home screen"),
        ] {
            let keyLabel = NSTextField(labelWithString: key)
            keyLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            let actionLabel = NSTextField(labelWithString: action)
            actionLabel.font = .systemFont(ofSize: 11)
            actionLabel.textColor = .secondaryLabelColor
            keyboard.addRow(with: [keyLabel, actionLabel])
        }
        addArrangedSubview(keyboard)
        let shown = UserDefaults.standard.bool(forKey: "keyboardHelpShown")
        keyboardToggle.state = shown ? .on : .off
        keyboard.isHidden = !shown
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }  // the scroll view starts at the top

    @objc private func toggleKeyboard() {
        keyboard.isHidden = keyboardToggle.state == .off
        UserDefaults.standard.set(!keyboard.isHidden, forKey: "keyboardHelpShown")
    }

    @objc private func toggleKeyboardFromLabel() {
        keyboardToggle.state = keyboardToggle.state == .on ? .off : .on
        toggleKeyboard()
    }

    private func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    /// A header with more room above it than between the rows of a section.
    private func section(_ text: String) {
        if let last = arrangedSubviews.last { setCustomSpacing(14, after: last) }
        addArrangedSubview(header(text))
    }

    /// Adds a row that spans the sidebar's content width.
    private func full(_ view: NSView) {
        addArrangedSubview(view)
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
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title.isEmpty ? nil : title)
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        buttons[id] = button
        return button
    }

    func setButton(_ id: String, title: String, symbol: String) {
        guard let button = buttons[id], button.title != title else { return }
        let symbolChanged = button.identifier?.rawValue != symbol
        button.title = title
        if symbolChanged {
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
    private let snapshotItemID = NSToolbarItem.Identifier("snapshot")
    private var videoMenuItem: NSMenuItem!
    private var audioMenuItem: NSMenuItem!
    private var videoToolbarItem: NSToolbarItem?
    private var audioToolbarItem: NSToolbarItem?
    private var videoHidden = UserDefaults.standard.bool(forKey: "videoHidden")
    private var audioMuted = UserDefaults.standard.bool(forKey: "audioMuted")
    private var previewLayer: CALayer!
    private let hiddenVideoLabel = NSTextField(labelWithString: "Video hidden")
    private var imageLayer: CALayer?
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
    private var titleList: [Title] = []
    private var titlesFetched = false
    private var titlesLoading = false
    private var titlesError: String?
    private var playing: String?
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
        do {
            try hub.start()
        } catch {
            say("capture failed: \(error.localizedDescription)")
            exit(2)
        }
        keys = KeyInput(source: "window", controller: hub.controller) { [weak self] in self?.hub.keyCommand($0) }
        video = VideoView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        video.keys = keys
        video.wantsLayer = true
        video.layer = CALayer()
        video.layer?.backgroundColor = NSColor.black.cgColor
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
        hiddenVideoLabel.textColor = .secondaryLabelColor
        hiddenVideoLabel.translatesAutoresizingMaskIntoConstraints = false
        hiddenVideoLabel.isHidden = !videoHidden
        video.addSubview(hiddenVideoLabel)
        NSLayoutConstraint.activate([
            hiddenVideoLabel.centerXAnchor.constraint(equalTo: video.centerXAnchor),
            hiddenVideoLabel.centerYAnchor.constraint(equalTo: video.centerYAnchor),
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
            sidebarScroll.widthAnchor.constraint(equalToConstant: 260),
            sidebar.widthAnchor.constraint(equalTo: sidebarScroll.contentView.widthAnchor),
            sidebar.heightAnchor.constraint(greaterThanOrEqualTo: sidebarScroll.contentView.heightAnchor),
        ])
        let content = NSStackView(views: [video, sidebarScroll])
        content.spacing = 0
        content.setHuggingPriority(.defaultLow, for: .horizontal)
        video.setContentHuggingPriority(.init(1), for: .horizontal)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280 + 260, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "PS5 MCP"
        window.contentView = content
        window.contentMinSize = NSSize(width: 640 + 260, height: 360)
        let toolbar = NSToolbar(identifier: "PS5Toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        restoreFrame()
        setVisible(!hub.config.headless)
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        if imageLayer != nil {
            Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.drawFrame() }
        }
        say("ready")
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
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
        viewItem.submenu = viewMenu
        main.addItem(viewItem)
        let consoleItem = NSMenuItem()
        let consoleMenu = NSMenu(title: "Console")
        for (title, action, key) in [
            ("Launch Game/App", #selector(launchTitle), "l"),
            ("Close Running Game/App…", #selector(closeApp), ""),
            ("Home", #selector(home), ""),
            ("Release All Input", #selector(releaseAll), "."),
            ("-", nil, ""),
            ("Start Recording", #selector(toggleRecording), "r"),
            ("Play Recording", #selector(togglePlayback), ""),
            ("Save Snapshot…", #selector(saveSnapshot), "s"),
            ("-", nil, ""),
            ("Install…", #selector(installFile), ""),
            ("Uninstall…", #selector(showUninstall), ""),
            ("Reload Games/Apps", #selector(reloadTitles), ""),
        ] as [(String, Selector?, String)] {
            guard let action else { consoleMenu.addItem(.separator()); continue }
            consoleMenu.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
        }
        consoleItem.submenu = consoleMenu
        main.addItem(consoleItem)
        NSApp.mainMenu = main
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [videoItemID, audioItemID, snapshotItemID, .flexibleSpace, sidebarItemID]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [videoItemID, audioItemID, snapshotItemID, .flexibleSpace, sidebarItemID]
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
        if itemIdentifier == snapshotItemID {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Save Snapshot"
            item.toolTip = "Save Snapshot (⌘S)"
            item.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Save Snapshot")
            item.target = self
            item.action = #selector(saveSnapshot)
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
        window.contentMinSize = NSSize(width: sidebarScroll.isHidden ? 640 : 900, height: 360)
        window.makeFirstResponder(video)
    }

    @objc func toggleVideo() {
        videoHidden.toggle()
        UserDefaults.standard.set(videoHidden, forKey: "videoHidden")
        updatePlaybackControls()
        if !videoHidden { drawFrame() }
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

    private func drawFrame() {
        guard !videoHidden, window.isVisible, let image = hub.sink.latestImage() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer?.contents = image
        CATransaction.commit()
    }

    func setVisible(_ visible: Bool) {
        hub.setVisible(visible)
        if visible {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(video)
            NSApp.activate(ignoringOtherApps: true)
            if !titlesFetched { loadTitles() }
        } else {
            keys?.releaseHeld()
            window.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
        }
        updatePlaybackControls()
        refresh()
    }

    @objc func hideWindow() { setVisible(false) }

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
        if let hello = link.hello {
            sidebar.set("padd", "v\(hello.versionString)")
            sidebar.set("Pad", hello.padReady ? "handle \(hello.padHandle)" : "NOT ready (\(hello.addStatus))",
                        color: hello.padReady ? .labelColor : .systemRed)
            let userID = String(format: "0x%08X", UInt32(bitPattern: hello.userID))
            sidebar.set("User", hello.userName.map { "\($0) · \(userID)" } ?? userID)
        } else {
            for field in ["padd", "Pad", "User"] { sidebar.set(field, "–") }
        }
        if link.connected, uptimeSeconds() - pongAt > 2 {
            pongAt = uptimeSeconds()
            DispatchQueue.global().async {
                let pong = try? self.hub.controller.currentLink().ping(timeout: 1)
                DispatchQueue.main.async { self.pong = pong }
            }
        }
        if !link.connected { pong = nil }
        if let pong {
            sidebar.set("Reports", "\(pong.reportsSent) sent, \(pong.reportFailures) failed",
                        color: pong.reportFailures > 0 ? .systemRed : .labelColor)
        } else {
            sidebar.set("Reports", "–")
        }
        let age = hub.sink.frameAge
        let camera = hub.cameraPermission
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
        sidebar.notice.stringValue = hub.notice ?? ""
        let canRun = busy == nil && hub.padd.json["available"] as? Bool == true
        let fileManagerBusy = titlesLoading || installing != nil  // Web File Manager runs one task at a time
        sidebar.buttons["paddStart"]?.isEnabled = canRun && !link.connected && !fileManagerBusy
        sidebar.buttons["paddStop"]?.isEnabled = canRun && !fileManagerBusy
        sidebar.buttons["install"]?.isEnabled = installing == nil && busy == nil && !titlesLoading
            && !hub.padd.cli.isEmpty
        sidebar.buttons["uninstall"]?.isEnabled = link.connected && uninstallSheet == nil
            && (link.hello?.flags ?? 0) & PMCP.flagUninstall != 0
        sidebar.setButton("install", title: installing == nil ? "Install…" : "Installing…",
                          symbol: "square.and.arrow.down")
        for id in ["home", "closeApp", "releaseAll"] { sidebar.buttons[id]?.isEnabled = link.connected }
        sidebar.buttons["launch"]?.isEnabled = link.connected && selectedTitle != nil
        sidebar.buttons["reloadTitles"]?.isEnabled = !titlesLoading && busy == nil && installing == nil
        sidebar.titles.isEnabled = !titleList.isEmpty
        let recorder = hub.recorder
        if let recorder {
            let seconds = Int(uptimeSeconds() - recorder.started)
            sidebar.setButton("record", title: String(format: "Stop %d:%02d", seconds / 60, seconds % 60),
                              symbol: "stop.circle.fill")
        } else {
            sidebar.setButton("record", title: "Record", symbol: "record.circle")
        }
        sidebar.buttons["record"]?.contentTintColor = recorder == nil ? nil : .systemRed
        sidebar.buttons["record"]?.isEnabled = playing == nil
        sidebar.setButton("play", title: playing == nil ? "Play" : "Stop",
                          symbol: playing == nil ? "play.fill" : "stop.fill")
        sidebar.buttons["play"]?.isEnabled = playing != nil
            || (link.connected && recorder == nil && sidebar.recordings.selectedItem?.representedObject != nil)
        sidebar.recordings.isEnabled = playing == nil && sidebar.recordings.numberOfItems > 0
            && sidebar.recordings.itemArray.contains { $0.representedObject != nil }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let sidebar else { return true }
        func enabled(_ id: String) -> Bool { sidebar.buttons[id]?.isEnabled ?? false }
        switch menuItem.action {
        case #selector(launchTitle):
            menuItem.title = selectedTitle.map { "Launch \($0.name)" } ?? "Launch Game/App"
            return enabled("launch")
        case #selector(closeApp): return enabled("closeApp")
        case #selector(home): return enabled("home")
        case #selector(releaseAll): return enabled("releaseAll")
        case #selector(toggleRecording):
            menuItem.title = hub.recorder == nil ? "Start Recording" : "Stop Recording…"
            return enabled("record")
        case #selector(togglePlayback):
            menuItem.title = playing == nil ? "Play Recording" : "Stop Playback"
            return enabled("play")
        case #selector(reloadTitles): return enabled("reloadTitles")
        case #selector(installFile): return enabled("install")
        case #selector(showUninstall): return enabled("uninstall")
        default: return true
        }
    }

    private func confirm(_ title: String, _ text: String, _ action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
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

    @objc func showSettings() {
        if settings == nil {
            settings = SettingsWindow(hub: hub) { [weak self] in
                self?.reloadTitles()  // another console: fetch its games/apps
                self?.refresh()
            }
        }
        settings?.show()
    }

    @objc func startPadd() {
        guard confirm("Start padd on \(hub.host)?",
                      "This uploads build/padd.elf through Payload Manager, launches it once and archives the run "
                      + "under results/. If the PS5 asks \"Who's using this controller?\", the virtual pad answers it, "
                      + "and that turns your DualSense off: press its PS button and pick the same user.", "Start")
        else { return }
        hub.notice = "Starting padd…"
        background { _ = try self.hub.padd.run("start", firmware: nil) }
    }

    @objc func stopPadd() {
        guard confirm("Stop padd?", "padd releases input, removes the virtual pad and exits. The run is archived.",
                      "Stop") else { return }
        hub.notice = "Stopping padd…"
        background { _ = try self.hub.padd.run("stop", firmware: nil) }
    }

    @objc func home() {
        background { _ = try self.hub.command("home", "", link: self.hub.controller.currentLink()) }
    }

    @objc func closeApp() {
        guard confirm("Close the running game or app?", "Unsaved progress is lost. The console returns to the home screen.",
                      "Close") else { return }
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
                      + "source folder or image is deleted too. This cannot be undone.", "Uninstall")
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
        popup.addItem(withTitle: "Choose…")  // nothing plays until one is picked
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
        alert.addButton(withTitle: "Discard")
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

    @objc func saveSnapshot() {
        guard let image = hub.sink.latestImage() else {
            hub.notice = "No frame to save yet."
            return
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "PS5 \(stamp.string(from: Date())).png"
        panel.beginSheetModal(for: window) { response in
            defer { self.window.makeFirstResponder(self.video) }
            guard response == .OK, let url = panel.url else { return }
            do {
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw BadInput("could not encode the frame")
                }
                try png.write(to: url)
                self.hub.notice = "Saved snapshot to \(url.lastPathComponent)."
            } catch {
                self.hub.notice = "Snapshot not saved: \(error.localizedDescription)"
            }
        }
    }

    @objc func releaseAll() {
        hub.controller.releaseAll()
        window.makeFirstResponder(video)
    }

    // Closing the window keeps the hub (capture, padd link, API) running; Quit ends it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        setVisible(false)
        return false
    }

    func windowDidResignKey(_ notification: Notification) { keys?.releaseHeld() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        hub.quit()
        return .terminateNow
    }
}
