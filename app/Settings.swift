// The Settings window (⌘,): the PS5's IP address, saved for the next launches and applied at once, and the folder
// snapshots are saved to (Desktop by default), which applies as soon as it is chosen.
//
// --host and PS5_HOST still win at launch (the MCP server passes PS5_HOST), so the window says when one of them set
// this launch's address. Saving here switches the running app to the new address either way.

import AppKit
import AVFoundation

let captureVideoKey = "captureVideoID"
let captureAudioKey = "captureAudioID"

/// The UserDefaults key for the snapshot folder chosen in Settings.
let snapshotFolderKey = "snapshotFolder"

/// Where Snapshot saves its PNGs: the folder chosen in Settings, else the Desktop.
var snapshotFolder: URL {
    if let path = UserDefaults.standard.string(forKey: snapshotFolderKey), !path.isEmpty {
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
    private let videoDevice = NSPopUpButton()
    private let audioDevice = NSPopUpButton()
    private let captureNote = NSTextField(wrappingLabelWithString: "")

    init(hub: Hub, onSaved: @escaping () -> Void) {
        self.hub = hub
        self.onSaved = onSaved
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled, .closable],
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
        let addressRow = NSStackView(views: [address, save])
        addressRow.spacing = 8

        for popup in [videoDevice, audioDevice] {
            popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
            popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let refresh = NSButton(title: "Refresh Devices", target: self, action: #selector(refreshDevices))
        let apply = NSButton(title: "Apply & Restart Capture", target: self, action: #selector(applyCapture))
        let captureButtons = NSStackView(views: [refresh, apply])
        captureButtons.spacing = 8

        folder.pathStyle = .popUp
        folder.isEditable = false
        folder.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        let folderRow = NSStackView(views: [folder, choose])
        folderRow.spacing = 8

        for text in [note, captureNote] {
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.textColor = .secondaryLabelColor
            text.preferredMaxLayoutWidth = 380
        }

        // A standard macOS form: right-aligned labels, controls in one column, a line between the sections.
        func label(_ title: String) -> NSTextField { NSTextField(labelWithString: title) }
        func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
        let empty = NSGridCell.emptyContentView
        let grid = NSGridView(views: [
            [label("PS5 IP address:"), addressRow],
            [empty, note],
            [separator(), empty],
            [label("Video device:"), videoDevice],
            [label("Audio device:"), audioDevice],
            [empty, captureNote],
            [empty, captureButtons],
            [separator(), empty],
            [label("Save snapshots to:"), folderRow],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 380
        for row in [2, 7] {
            grid.row(at: row).mergeCells(in: NSRange(location: 0, length: 2))
            grid.cell(atColumnIndex: 0, rowIndex: row).xPlacement = .fill
            grid.row(at: row).topPadding = 6
            grid.row(at: row).bottomPadding = 6
        }
        grid.cell(for: captureButtons)?.xPlacement = .leading

        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        window.contentView = content
    }

    func show() {
        address.stringValue = hub.host
        folder.url = snapshotFolder
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
        fill(videoDevice, devices: CaptureDevices.video, selection: video, empty: "Choose a video device…")
        fill(audioDevice, devices: CaptureDevices.audio, selection: audio, empty: "No audio")
    }

    @objc private func refreshDevices() {
        fillDevices(video: videoDevice.selectedItem?.representedObject as? String,
                    audio: audioDevice.selectedItem?.representedObject as? String)
        refreshCaptureStatus()
    }

    func refreshCaptureStatus() {
        // The hub's messages point to Settings, which is this window.
        captureNote.stringValue = hub.captureIssue?.replacingOccurrences(of: " in Settings (⌘,)", with: "")
            .replacingOccurrences(of: " in Settings", with: "")
            ?? "Selections are saved for future launches. Restarting capture keeps connected MCP clients running."
    }

    @objc private func applyCapture() {
        let video = videoDevice.selectedItem?.representedObject as? String ?? ""
        let audio = audioDevice.selectedItem?.representedObject as? String ?? ""
        do {
            guard let ui = hub.ui else { throw BadInput("Capture is not ready.") }
            try ui.restartCapture(video: video, audio: audio.isEmpty ? nil : audio)
            UserDefaults.standard.set(video, forKey: captureVideoKey)
            if audio.isEmpty { UserDefaults.standard.removeObject(forKey: captureAudioKey) }
            else { UserDefaults.standard.set(audio, forKey: captureAudioKey) }
            refreshCaptureStatus()
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
        panel.directoryURL = snapshotFolder
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            UserDefaults.standard.set(url.path, forKey: snapshotFolderKey)
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
