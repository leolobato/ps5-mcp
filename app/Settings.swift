// The Settings window (⌘,): the PS5's IP address, saved for the next launches and applied at once, the video source
// with only that source's controls, the folder snapshots and videos go to (Desktop by default), and the keyboard panel.
//
// --host and PS5_HOST still win at launch (the MCP server passes PS5_HOST), so the window says when one of them set
// this launch's address. Saving here switches the running app to the new address either way.

import AppKit
import AVFoundation

let captureVideoKey = "captureVideoID"
let captureAudioKey = "captureAudioID"

/// The UserDefaults key for the capture folder chosen in Settings (its name is from when only snapshots used it).
let captureFolderKey = "snapshotFolder"

/// Where snapshots are saved, and where saving a video starts: the folder chosen in Settings, else the Desktop.
var captureFolder: URL {
    if let path = UserDefaults.standard.string(forKey: captureFolderKey), !path.isEmpty {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
}

final class SettingsWindow: NSObject, NSTextFieldDelegate {
    let window: NSWindow
    private let hub: Hub
    private let address = NSTextField()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let save = NSButton(title: "Save", target: nil, action: nil)
    private let folder = NSPathControl()
    private let onSaved: () -> Void
    private let onFloatingChanged: () -> Void
    private let sourcePicker = NSSegmentedControl()
    private var sources = ["", "remoteplay"]
    private let useSource = NSButton(title: "", target: nil, action: nil)
    private let captureControls = NSStackView()
    private let remoteControls = NSStackView()
    private let floatOverAll = NSButton(checkboxWithTitle: "Float over all windows, on every Space", target: nil, action: nil)
    private let videoDevice = NSPopUpButton()
    private let audioDevice = NSPopUpButton()
    private let captureNote = NSTextField(wrappingLabelWithString: "")
    private let remotePlayNote = NSTextField(wrappingLabelWithString: "")
    private let setupRemotePlay = NSButton(title: "Set Up…", target: nil, action: nil)
    private let reconnectRemotePlay = NSButton(title: "Reconnect", target: nil, action: nil)
    private let connectionNote = NSTextField(wrappingLabelWithString: "")
    private let forgetRemotePlay = NSButton(title: "Forget…", target: nil, action: nil)
    private var remotePlaySetupWindow: RemotePlaySetupWindow?
    #if PS5MCP_PBS
    private let stopPBS = NSButton(title: "Stop PBS", target: nil, action: nil)
    private let reconnectPBS = NSButton(title: "Reconnect", target: nil, action: nil)
    private let pbsNote = NSTextField(wrappingLabelWithString: "")
    private let loadPBS = NSButton(title: "Load PBS", target: nil, action: nil)
    private var pbsBusy = false
    private var pbsMessage: String?
    private var pbsWasStreaming = false
    private let pbsControls = NSStackView()
    #endif

    init(hub: Hub, onSaved: @escaping () -> Void, onFloatingChanged: @escaping () -> Void) {
        self.hub = hub
        self.onSaved = onSaved
        self.onFloatingChanged = onFloatingChanged
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Settings"
        window.isReleasedWhenClosed = false

        address.placeholderString = "192.168.1.20"
        address.delegate = self
        address.target = self
        address.action = #selector(saved)
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        save.target = self
        save.action = #selector(saved)
        save.keyEquivalent = "\r"

        for popup in [videoDevice, audioDevice] {
            popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
            popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let refresh = NSButton(title: "Refresh Devices", target: self, action: #selector(refreshDevices))
        let apply = NSButton(title: "Apply & Restart Capture", target: self, action: #selector(applyCapture))
        setupRemotePlay.target = self; setupRemotePlay.action = #selector(setUpRemotePlay)
        forgetRemotePlay.target = self; forgetRemotePlay.action = #selector(forgetPairing)
        forgetRemotePlay.hasDestructiveAction = true
        reconnectRemotePlay.target = self; reconnectRemotePlay.action = #selector(reconnect)
        useSource.target = self; useSource.action = #selector(applyCapture)
        useSource.keyEquivalent = ""

        var labels = ["Capture card", "Remote Play"]
        #if PS5MCP_PBS
        labels.append("PBS")
        sources.append("pbs")
        #endif
        sourcePicker.segmentCount = labels.count
        for (index, label) in labels.enumerated() { sourcePicker.setLabel(label, forSegment: index) }
        sourcePicker.segmentDistribution = .fillEqually
        sourcePicker.trackingMode = .selectOne
        sourcePicker.target = self
        sourcePicker.action = #selector(sourceChanged)
        sourcePicker.setAccessibilityLabel("Video source")

        folder.pathStyle = .popUp
        folder.isEditable = false
        folder.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))

        var notes = [note, captureNote, remotePlayNote, connectionNote]
        #if PS5MCP_PBS
        notes.append(pbsNote)
        #endif
        for text in notes {
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.textColor = .secondaryLabelColor
            text.preferredMaxLayoutWidth = Self.innerWidth
        }

        func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.spacing = spacing
            stack.distribution = .fill
            return stack
        }
        func spacer() -> NSView {
            let view = NSView()
            view.setContentHuggingPriority(.init(1), for: .horizontal)
            return view
        }
        func column(_ views: [NSView], into stack: NSStackView = NSStackView(), spacing: CGFloat = 8,
                    inset: CGFloat = 0) -> NSStackView {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = spacing
            for view in views {
                stack.addArrangedSubview(view)
                if view is NSStackView || view is NSGridView {
                    view.translatesAutoresizingMaskIntoConstraints = false
                    view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset).isActive = true
                }
            }
            return stack
        }
        let devices = NSGridView(views: [
            [NSTextField(labelWithString: "Video device"), videoDevice],
            [NSTextField(labelWithString: "Audio device"), audioDevice],
        ])
        devices.rowSpacing = 8
        devices.columnSpacing = 8
        devices.rowAlignment = .firstBaseline
        devices.column(at: 1).xPlacement = .fill
        _ = column([devices, captureNote, row([spacer(), refresh, apply])], into: captureControls)
        _ = column([connectionNote, remotePlayNote,
                    row([forgetRemotePlay, spacer(), setupRemotePlay, reconnectRemotePlay])], into: remoteControls)
        var panes: [NSView] = [captureControls, remoteControls]
        #if PS5MCP_PBS
        stopPBS.target = self; stopPBS.action = #selector(stopPBSPayload)
        reconnectPBS.target = self; reconnectPBS.action = #selector(reconnectToPBS)
        loadPBS.target = self; loadPBS.action = #selector(loadPBSPayload)
        _ = column([pbsNote, row([spacer(), loadPBS, reconnectPBS, stopPBS])], into: pbsControls)
        panes.append(pbsControls)
        #endif

        floatOverAll.target = self
        floatOverAll.action = #selector(floatChanged)
        let hotKey = NSTextField(labelWithString: "Show or hide it from any app with ⌃⌥K, or with the toolbar's keyboard button.")
        hotKey.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hotKey.textColor = .secondaryLabelColor

        let body = column([
            section("Console", [row([NSTextField(labelWithString: "PS5 IP address"), address, save]), note]),
            section("Video and audio", [sourcePicker] + panes + [row([spacer(), useSource])]),
            section("Capture files", [row([NSTextField(labelWithString: "Save snapshots and videos to"), folder, choose])]),
            section("Keyboard panel", [floatOverAll, hotKey]),
        ], spacing: 14, inset: 48)
        body.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 20, right: 24)
        body.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(equalToConstant: 600).isActive = true
        window.contentView = body
    }

    private static let innerWidth: CGFloat = 600 - 48 - 28

    private func section(_ title: String, _ views: [NSView]) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 10
        inner.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.pin(inner)
        for view in views {
            inner.addArrangedSubview(view)
            if !(view is NSButton) && !(view is NSTextField) || view === sourcePicker {
                view.translatesAutoresizingMaskIntoConstraints = false
                view.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -28).isActive = true
            }
        }
        let stack = NSStackView(views: [heading, box])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    func show() {
        address.stringValue = hub.host
        folder.url = captureFolder
        floatOverAll.state = KeyboardPanel.floats ? .on : .off
        fillDevices(video: hub.captureVideo, audio: hub.captureAudio)
        refreshCaptureStatus()
        update()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(address)
    }

    private var entered: String { address.stringValue.trimmingCharacters(in: .whitespaces) }

    private func fill(_ popup: NSPopUpButton, devices: [AVCaptureDevice], selection: String?, empty: String) {
        popup.removeAllItems()
        popup.addItem(withTitle: empty)
        popup.lastItem?.representedObject = ""
        for device in devices {
            let duplicate = devices.filter { $0.localizedName == device.localizedName }.count > 1
            popup.addItem(withTitle: device.localizedName + (duplicate ? " (\(device.uniqueID))" : ""))
            popup.lastItem?.representedObject = device.uniqueID
        }
        guard let selection, !selection.isEmpty else { return }
        let id = CaptureDevices.find(selection, in: devices)?.uniqueID ?? selection
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == id }) {
            popup.select(item)
        } else {
            popup.addItem(withTitle: "Unavailable: \(selection)")
            popup.lastItem?.representedObject = selection
            popup.select(popup.lastItem)
        }
    }

    private func fillDevices(video: String?, audio: String?) {
        let network = sources.contains(video ?? "") && !(video ?? "").isEmpty
        fill(videoDevice, devices: CaptureDevices.video, selection: network ? nil : video, empty: "Choose a video device…")
        fill(audioDevice, devices: CaptureDevices.audio, selection: network ? nil : audio, empty: "No audio")
        sourcePicker.selectedSegment = sources.firstIndex(of: network ? video ?? "" : "") ?? 0
        sourceChanged()
    }

    @objc private func refreshDevices() {
        let source = selectedSource
        fillDevices(video: videoDevice.selectedItem?.representedObject as? String,
                    audio: audioDevice.selectedItem?.representedObject as? String)
        sourcePicker.selectedSegment = sources.firstIndex(of: source) ?? 0
        sourceChanged()
        refreshCaptureStatus()
    }

    func refreshCaptureStatus() {
        // The hub's messages point to Settings, which is this window.
        captureNote.stringValue = hub.captureIssue?.replacingOccurrences(of: " in Settings (⌘,)", with: "")
            .replacingOccurrences(of: " in Settings", with: "")
            ?? "Selections are saved for future launches. Restarting capture keeps connected MCP clients running."
        refreshRemotePlayStatus()
        updateUseSource()
        #if PS5MCP_PBS
        refreshPBSStatus()
        #endif
        remotePlaySetupWindow?.refreshVerification()
    }

    #if PS5MCP_PBS
    private func refreshPBSStatus() {
        let pbs = hub.source as? PBSSource
        let streaming = pbs?.status.videoReady == true
        if streaming, !pbsWasStreaming { pbsMessage = nil }  // only video arriving answers "Started…"; refusals stay
        pbsWasStreaming = streaming
        loadPBS.isEnabled = pbs != nil && !streaming && !pbsBusy
        reconnectPBS.isEnabled = pbs != nil
        stopPBS.isEnabled = streaming && !pbsBusy
        pbsNote.stringValue = pbsMessage ?? pbs.map { $0.status.summary } ?? "PBS is not the active capture source."
    }

    @objc private func reconnectToPBS() {
        pbsMessage = nil
        (hub.source as? PBSSource)?.reconnect()
        refreshPBSStatus()
    }

    /// Load and Stop change what runs on the shared console, so they respect an agent's claim as Remote Play's Reconnect does.
    private func consoleIsFreeForPBS() -> Bool {
        guard let owner = hub.lease.json["owner"] as? [String: Any] else { return true }
        pbsMessage = "The console is claimed by \(owner["client"] as? String ?? "another client"). Wait for its claim to be released."
        refreshPBSStatus()
        return false
    }

    @objc private func loadPBSPayload() {
        guard let pbs = hub.source as? PBSSource, consoleIsFreeForPBS() else { return }
        pbsBusy = true
        pbsMessage = "Loading PBS…"
        refreshPBSStatus()
        pbs.loadPayload { [weak self] result in
            guard let self else { return }
            self.pbsBusy = false
            switch result {
            case .started(let name): self.pbsMessage = "Started \(name). Waiting for video…"
            case .notInLibrary: self.pbsMessage = "PBS is not in Payload Manager's library. Add its .elf with `ps5mcp install`, then try again."
            case .unreachable: self.pbsMessage = "Payload Manager did not answer on the console."
            }
            self.refreshPBSStatus()
        }
    }

    @objc private func stopPBSPayload() {
        guard let pbs = hub.source as? PBSSource, consoleIsFreeForPBS() else { return }
        pbsBusy = true
        pbsMessage = "Stopping PBS…"
        refreshPBSStatus()
        pbs.stopPayload { [weak self] answered in
            guard let self else { return }
            self.pbsBusy = false
            self.pbsMessage = answered ? nil : "PBS did not answer. It may already be stopped."
            self.refreshPBSStatus()
        }
    }
    #endif

    private func refreshRemotePlayStatus() {
        setupRemotePlay.isEnabled = !hub.host.isEmpty
        let remote = hub.source as? RemotePlaySource
        connectionNote.stringValue = remote?.status.summary ?? (hub.captureVideo == "remoteplay" ? (hub.captureIssue ?? "Set up Remote Play.") : "Remote Play is not the active capture source.")
        reconnectRemotePlay.isEnabled = remote != nil && ![.connecting, .applyingAdmission, .waitingForVideo].contains(remote!.status.phase)
        do {
            if let record = try hub.remotePlayCredentials.load(host: hub.host) {
                remotePlayNote.stringValue = "Paired with \(record.nickname) at \(hub.host). Pairing is saved in Keychain."
                forgetRemotePlay.isEnabled = true
            } else {
                remotePlayNote.stringValue = "Not paired for \(hub.host.isEmpty ? "this console" : hub.host). Set Up supports local offline users and an existing Base64 account ID."
                forgetRemotePlay.isEnabled = false
            }
        } catch {
            remotePlayNote.stringValue = error.localizedDescription
            forgetRemotePlay.isEnabled = true
        }
    }

    @objc private func reconnect() {
        do {
            guard hub.captureVideo == "remoteplay", let ui = hub.ui else { return }
            if let owner = hub.lease.json["owner"] as? [String: Any] {
                throw RemotePlaySetupError("The console is claimed by \(owner["client"] as? String ?? "another client"). Wait for its claim to be released.")
            }
            try ui.restartCapture(video: "remoteplay", audio: "remoteplay")
        } catch { connectionNote.stringValue = error.localizedDescription }
    }

    /// "" is the capture card; the others are network sources, with their own id.
    private var selectedSource: String { sources[max(0, sourcePicker.selectedSegment)] }

    /// Only the chosen source's controls show, and the window fits them.
    @objc private func sourceChanged() {
        let source = selectedSource
        captureControls.isHidden = source != ""
        remoteControls.isHidden = source != "remoteplay"
        #if PS5MCP_PBS
        pbsControls.isHidden = source != "pbs"
        #endif
        updateUseSource()
        fitWindow()
    }

    /// A network source applies with one button: it has no devices to choose first.
    private func updateUseSource() {
        let source = selectedSource
        useSource.isHidden = source == "" || hub.captureVideo == source
        useSource.title = "Use \(sourcePicker.label(forSegment: max(0, sourcePicker.selectedSegment)) ?? "This Source")"
    }

    private func fitWindow() {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: 600, height: content.fittingSize.height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    @objc private func floatChanged() {
        KeyboardPanel.floats = floatOverAll.state == .on
        onFloatingChanged()
    }

    @objc func setUpRemotePlay() {
        do {
            if let existing = remotePlaySetupWindow, existing.window.isVisible {
                existing.show(); return
            }
            let setup = try RemotePlaySetupWindow(hub: hub) { [weak self] in
                guard let self else { return }
                self.fillDevices(video: self.hub.captureVideo, audio: self.hub.captureAudio)
                self.refreshCaptureStatus()
            }
            remotePlaySetupWindow = setup
            setup.show()
        } catch {
            let alert = NSAlert(); alert.messageText = "Could not open Remote Play setup"
            alert.informativeText = error.localizedDescription; alert.beginSheetModal(for: window)
        }
    }

    @objc private func forgetPairing() {
        let host = hub.host
        let video = hub.captureVideo
        let alert = NSAlert()
        alert.messageText = "Forget Remote Play pairing?"
        alert.informativeText = "Remove the saved Keychain registration for \(host). You will need a new Link Device PIN to pair again. Console account values are unchanged."
        alert.addButton(withTitle: "Forget Pairing"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                guard self.hub.host == host, self.hub.captureVideo == video else {
                    throw RemotePlaySetupError("The console address or capture source changed. Review Settings before forgetting pairing.")
                }
                if let owner = self.hub.lease.json["owner"] as? [String: Any] {
                    throw RemotePlaySetupError("The PS5 is claimed by \(owner["client"] as? String ?? "another client"). Wait for its claim to be released before forgetting pairing.")
                }
                // A recording (including its pending save) must finish before removing
                // credentials; otherwise restart would fail and leave the old stream live.
                let captureUI = self.hub.ui
                if video == "remoteplay" {
                    guard let captureUI else { throw RemotePlaySetupError("Capture is not ready. Pairing has been kept.") }
                    try captureUI.validateCaptureChange()
                }
                try self.hub.remotePlayCredentials.forget(host: host)
                if video == "remoteplay" {
                    try captureUI?.restartCapture(video: "remoteplay", audio: "remoteplay")
                }
                self.refreshCaptureStatus()
            } catch {
                self.remotePlayNote.stringValue = (error as? BadInput)?.description ?? error.localizedDescription
            }
        }
    }

    @objc private func applyCapture() {
        let network = selectedSource
        let video = network.isEmpty ? videoDevice.selectedItem?.representedObject as? String ?? "" : network
        let audio = network.isEmpty ? audioDevice.selectedItem?.representedObject as? String ?? "" : network
        do {
            guard let ui = hub.ui else { throw BadInput("Capture is not ready.") }
            try ui.restartCapture(video: video, audio: audio.isEmpty ? nil : audio)
            UserDefaults.standard.set(video, forKey: captureVideoKey)
            if audio.isEmpty { UserDefaults.standard.removeObject(forKey: captureAudioKey) }
            else { UserDefaults.standard.set(audio, forKey: captureAudioKey) }
            refreshCaptureStatus()
            fitWindow()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not restart capture"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
        }
    }

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

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = captureFolder
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            UserDefaults.standard.set(url.path, forKey: captureFolderKey)
            self.folder.url = url
        }
    }

    @objc private func saved() {
        guard valid else { NSSound.beep(); return }
        hub.setHost(entered)
        update()
        onSaved()
        window.close()
    }
}
