// The Settings window (⌘,): the PS5's IP address, saved for the next launches and applied at once, the video source
// with only that source's controls, the folder snapshots and videos go to (Desktop by default), whether snapshots include
// the frame meter, and the keyboard panel.
//
// --host and PS5_HOST still win at launch (the MCP server passes PS5_HOST), so the window says when one of them set
// this launch's address. Saving here switches the running app to the new address either way.

import AppKit
import AVFoundation

let captureVideoKey = "captureVideoID"
/// The SSH destination of a Linux hub to use instead of this Mac (empty or missing: this Mac).
let linuxHubKey = "linuxHub"
let captureAudioKey = "captureAudioID"

/// The UserDefaults key for the capture folder chosen in Settings (its name is from when only snapshots used it).
let captureFolderKey = "snapshotFolder"

/// The UserDefaults key for drawing the frame meter into saved snapshots while it shows. Off by default.
let snapshotIncludesFrameMeterKey = "snapshotIncludesFrameMeter"

/// The UserDefaults key for `Hub.pickByHand`. Off by default.
let pickUserByHandKey = "pickUserByHand"

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
    private let hubPicker = NSSegmentedControl(labels: ["This Mac", "Linux machine"], trackingMode: .selectOne,
                                               target: nil, action: nil)
    private let hubAddress = NSTextField()
    private let useHub = NSButton(title: "", target: nil, action: nil)
    private let hubNote = NSTextField(wrappingLabelWithString: "")
    private let hubTarget = NSStackView()
    private var videoSection: NSView!
    private let sourcePicker = NSSegmentedControl()
    private var sources = ["", "remoteplay"]
    private let useSource = NSButton(title: "", target: nil, action: nil)
    private let captureControls = NSStackView()
    private let remoteControls = NSStackView()
    private let floatOverAll = NSButton(checkboxWithTitle: "Float over all windows, on every Space", target: nil, action: nil)
    private let snapshotFrameMeter = NSButton(checkboxWithTitle: "Include the frame meter in snapshots when it is showing", target: nil, action: nil)
    private let pickByHand = NSButton(checkboxWithTitle: "Let me pick the user when I start padd or add a controller", target: nil, action: nil)
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

        hubPicker.segmentDistribution = .fillEqually
        hubPicker.target = self
        hubPicker.action = #selector(hubChanged)
        hubPicker.setAccessibilityLabel("Hub")
        hubAddress.placeholderString = "user@linux-box"
        hubAddress.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hubAddress.delegate = self
        useHub.target = self
        useHub.action = #selector(applyHub)

        var notes = [note, captureNote, remotePlayNote, connectionNote, hubNote]
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

        snapshotFrameMeter.target = self
        snapshotFrameMeter.action = #selector(snapshotFrameMeterChanged)
        floatOverAll.target = self
        floatOverAll.action = #selector(floatChanged)
        let hotKey = NSTextField(labelWithString: "Show or hide it from any app with ⌃⌥K, or with the toolbar's keyboard button.")
        hotKey.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hotKey.textColor = .secondaryLabelColor
        pickByHand.target = self
        pickByHand.action = #selector(pickByHandChanged)
        let pickNote = NSTextField(wrappingLabelWithString: "The PS5 asks who is using each new controller. Answer with the arrow "
            + "keys and Enter in the window. When this is off, the app moves to the controller's user and presses Cross for you.")
        pickNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pickNote.textColor = .secondaryLabelColor
        pickNote.preferredMaxLayoutWidth = Self.innerWidth

        hubTarget.addArrangedSubview(NSTextField(labelWithString: "SSH destination"))
        hubTarget.addArrangedSubview(hubAddress)
        hubTarget.spacing = 8
        videoSection = section("Video and audio", [sourcePicker] + panes + [row([spacer(), useSource])])
        let body = column([
            section("Hub", [hubPicker, hubTarget, hubNote, row([spacer(), useHub])]),
            section("Console", [row([NSTextField(labelWithString: "PS5 IP address"), address, save]), note]),
            videoSection,
            section("Capture files", [row([NSTextField(labelWithString: "Save snapshots and videos to"), folder, choose]), snapshotFrameMeter]),
            section("Controllers", [pickByHand, pickNote]),
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
            if !(view is NSButton) && !(view is NSTextField) || view === sourcePicker || view === hubPicker {
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
        snapshotFrameMeter.state = UserDefaults.standard.bool(forKey: snapshotIncludesFrameMeterKey) ? .on : .off
        pickByHand.state = hub.pickByHand ? .on : .off
        floatOverAll.state = KeyboardPanel.floats ? .on : .off
        let linux = hub.linuxHub
        hubPicker.selectedSegment = linux == nil ? 0 : 1
        hubAddress.stringValue = linux?.target ?? UserDefaults.standard.string(forKey: linuxHubKey) ?? ""
        fillDevices(video: linux == nil ? hub.captureVideo : UserDefaults.standard.string(forKey: captureVideoKey),
                    audio: linux == nil ? hub.captureAudio : UserDefaults.standard.string(forKey: captureAudioKey))
        hubChanged()
        refreshCaptureStatus()
        update()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(address)
    }

    private var entered: String { address.stringValue.trimmingCharacters(in: .whitespaces) }

    private func fill(_ popup: NSPopUpButton, devices: [AVCaptureDevice], selection: String?, remembered: CaptureDevices.Remembered?,
                      empty: String) {
        popup.removeAllItems()
        popup.addItem(withTitle: empty)
        popup.lastItem?.representedObject = ""
        for device in devices {
            let duplicate = devices.filter { $0.localizedName == device.localizedName }.count > 1
            popup.addItem(withTitle: device.localizedName + (duplicate ? " (\(device.uniqueID))" : ""))
            popup.lastItem?.representedObject = device.uniqueID
        }
        if let device = CaptureDevices.resolve(selection, in: devices, remembered: remembered) {
            popup.selectItem(at: popup.indexOfItem(withRepresentedObject: device.uniqueID))
            return
        }
        guard let selection, !selection.isEmpty else { return }
        popup.addItem(withTitle: "Unavailable: \(selection)")
        popup.lastItem?.representedObject = selection
        popup.select(popup.lastItem)
    }

    private func fillDevices(video: String?, audio: String?) {
        let network = sources.contains(video ?? "") && !(video ?? "").isEmpty
        // A network source leaves the card's popups on the card that last captured, ready to switch back to.
        fill(videoDevice, devices: CaptureDevices.video, selection: network ? nil : video,
             remembered: CaptureDevices.rememberedVideo, empty: "Choose a video device…")
        let audioSelection = network ? nil : audio
        // "No audio" chosen on purpose stays chosen; only a lost or missing selection falls back to the remembered input.
        fill(audioDevice, devices: CaptureDevices.audio, selection: audioSelection,
             remembered: network || audioSelection?.isEmpty == false ? CaptureDevices.rememberedAudio : nil, empty: "No audio")
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
        refreshHubStatus()
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
        loadPBS.isEnabled = !streaming && !pbsBusy  // also when PBS is not the source, to see what loading it says
        reconnectPBS.isEnabled = pbs != nil
        stopPBS.isEnabled = streaming && !pbsBusy
        pbsNote.stringValue = pbsMessage ?? pbs.map { $0.status.summary } ?? "PBS is not the active capture source."
    }

    @objc private func reconnectToPBS() {
        pbsMessage = nil
        (hub.source as? PBSSource)?.reconnect()
        refreshPBSStatus()
    }

    /// Stop takes the picture away from whoever is watching, so it respects an agent's claim as Remote Play's Reconnect does.
    /// Load only starts PBS beside the running game, so it works during a claim.
    private func consoleIsFreeForPBS() -> Bool {
        guard let owner = hub.lease.json["owner"] as? [String: Any] else { return true }
        pbsMessage = "The console is claimed by \(owner["client"] as? String ?? "another client"). Wait for its claim to be released."
        refreshPBSStatus()
        return false
    }

    @objc private func loadPBSPayload() {
        pbsBusy = true
        pbsMessage = "Loading PBS…"
        refreshPBSStatus()
        PBSSource.loadPayload(host: hub.host) { [weak self] result in
            guard let self else { return }
            self.pbsBusy = false
            switch result {
            case .started(let name):
                // Only an active PBS source clears this when video arrives.
                self.pbsMessage = self.hub.source is PBSSource ? "Started \(name). Waiting for video…"
                    : "Started \(name). Use PBS as the source to watch it."
            case .notInLibrary: self.offerPBSDownload()
            case .unreachable: self.pbsMessage = "Payload Manager did not answer on \(self.hub.host):8084."
            case .refused(let reason): self.pbsMessage = reason
            }
            self.refreshPBSStatus()
        }
    }

    /// The app does not carry PBS (GPL-3.0). With the person's consent, `ps5mcp get-pbs` downloads the pinned upstream
    /// release, checks its SHA256, adds it to Payload Manager's library and starts it.
    private func offerPBSDownload() {
        let cli = hub.padd.cli
        guard !cli.isEmpty else {
            pbsMessage = "PBS is not in Payload Manager's library. Add its .elf with `ps5mcp install`, then try again."
            return
        }
        let host = hub.host
        let alert = NSAlert()
        alert.messageText = "Download PBS?"
        alert.informativeText = "PBS is not in Payload Manager's library on \(host). PS5 MCP can download the tested "
            + "release from github.com/seregonwar/PBS-Payload, check its checksum, add it to Payload Manager and start it. "
            + "PBS is a separate program under the GPL-3.0 license."
        alert.addButton(withTitle: "Download and Start"); alert.addButton(withTitle: "Cancel")
        pbsMessage = "PBS is not in Payload Manager's library."
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard self.hub.host == host else { return }
            self.runGetPBS(cli, host: host)
        }
    }

    private func runGetPBS(_ cli: [String], host: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli[0])
        process.arguments = Array(cli.dropFirst()) + ["get-pbs", "--run", "--host", host]
        process.environment = hub.padd.cliEnvironment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        var lastLine = ""
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let line = text.split(separator: "\n").last.map(String.init), !line.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                lastLine = line
                self?.pbsMessage = line.prefix(1).uppercased() + line.dropFirst()
                self?.refreshPBSStatus()
            }
        }
        process.terminationHandler = { process in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pbsBusy = false
                if process.terminationStatus == 0 {
                    self.pbsMessage = "PBS installed and started. Waiting for video…"
                } else if !lastLine.hasPrefix("install failed") {
                    self.pbsMessage = "Could not get PBS (exit \(process.terminationStatus))."
                }
                self.refreshPBSStatus()
            }
        }
        do {
            try process.run()
            pbsBusy = true
            pbsMessage = "Downloading PBS…"
        } catch {
            pbsMessage = "Could not start ps5mcp: \(error.localizedDescription)"
        }
        refreshPBSStatus()
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

    // MARK: hub

    private var enteredHub: String { hubAddress.stringValue.trimmingCharacters(in: .whitespaces) }

    /// An SSH destination as `ssh` takes it: a host alias, host or user@host. No spaces, and no option.
    private var validHub: Bool {
        !enteredHub.isEmpty && !enteredHub.hasPrefix("-") && enteredHub.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    @objc private func hubChanged() {
        hubTarget.isHidden = hubPicker.selectedSegment == 0
        videoSection.isHidden = hub.linuxHub != nil
        refreshHubStatus()
        fitWindow()
    }

    private func refreshHubStatus() {
        let wantLinux = hubPicker.selectedSegment == 1
        let current = hub.linuxHub
        if wantLinux {
            useHub.title = current == nil ? "Use Linux Machine" : "Reconnect"
            useHub.isEnabled = validHub
        } else {
            useHub.title = "Use This Mac"
            useHub.isEnabled = current != nil
        }
        useHub.isHidden = !wantLinux && current == nil
        guard wantLinux else {
            hubNote.stringValue = current == nil
                ? "This Mac owns the capture card, the padd link and the claims."
                : "Switching back reconnects this Mac's padd link and capture device."
            return
        }
        guard let current else {
            hubNote.stringValue = "A Linux machine running the PS5 MCP hub (ps5mcp capture start) owns the capture card, the padd "
                + "link and the claims. This app shows its picture over SSH, with your SSH keys, and passes this Mac's agents to it."
            return
        }
        let status = current.status
        var text = status.issue.map { "Not connected: \($0)" } ?? (status.phase == .streaming
            ? "Showing \(current.target)'s picture." : "Connecting to \(current.target)…")
        if let pad = status.remote?["pad"] as? [String: Any] {
            text += pad["connected"] as? Bool == true
                ? " padd \(pad["version"] as? String ?? "") is connected there." : " padd is not connected there."
        }
        hubNote.stringValue = text
    }

    @objc private func applyHub() {
        let linux = hubPicker.selectedSegment == 1
        guard !linux || validHub else { NSSound.beep(); return }
        let video = linux ? LinuxHubSource.prefix + enteredHub : UserDefaults.standard.string(forKey: captureVideoKey) ?? ""
        let audio = linux ? nil : UserDefaults.standard.string(forKey: captureAudioKey)
        do {
            guard let ui = hub.ui else { throw BadInput("Capture is not ready.") }
            try ui.restartCapture(video: video, audio: audio)
            if linux { UserDefaults.standard.set(enteredHub, forKey: linuxHubKey) }
            else { UserDefaults.standard.removeObject(forKey: linuxHubKey) }
            hubChanged()
            refreshCaptureStatus()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the hub"
            alert.informativeText = (error as? BadInput)?.description ?? error.localizedDescription
            alert.beginSheetModal(for: window)
        }
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

    @objc private func snapshotFrameMeterChanged() {
        UserDefaults.standard.set(snapshotFrameMeter.state == .on, forKey: snapshotIncludesFrameMeterKey)
    }

    @objc private func pickByHandChanged() { hub.pickByHand = pickByHand.state == .on }

    /// The Controllers menu changed it while this window is open.
    func refreshPickByHand() { pickByHand.state = hub.pickByHand ? .on : .off }

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

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === hubAddress { refreshHubStatus() } else { update() }
    }

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
        // Return in the SSH destination reaches the Console section's default button first.
        if (window.firstResponder as? NSTextView)?.delegate === hubAddress {
            if hubPicker.selectedSegment == 1 && validHub { applyHub() } else { NSSound.beep() }
            return
        }
        guard valid else { NSSound.beep(); return }
        hub.setHost(entered)
        update()
        onSaved()
        window.close()
    }
}
