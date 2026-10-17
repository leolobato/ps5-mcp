import AppKit

private final class RemotePlaySetupDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// A retained, cancelable setup window. Its target never follows later changes in Settings.
final class RemotePlaySetupWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let hub: Hub
    private let targetHost: String
    private let client: RemotePlaySetupClient
    private let onPaired: () -> Void
    private let accounts = NSPopUpButton()
    private let accountID = NSTextField()
    private let pin = NSSecureTextField()
    private let status = NSTextField(wrappingLabelWithString: "Check the console to choose an account, or use an existing account ID under Advanced.")
    private let accountStatus = NSTextField(wrappingLabelWithString: "No account inspected.")
    private var users: [RemotePlaySetupAccount] = []
    private var actions: [NSButton] = []
    private var registration: RemotePlayRegistration?
    private var generation: UInt64 = 0
    private var busy = false
    private var prepareButton: NSButton?
    private let verificationStatus = NSTextField(wrappingLabelWithString: "Pair the console, then verify live video and audio.")
    private let retryVerification = NSButton(title: "Retry Verification", target: nil, action: nil)
    private var verification = RemotePlaySetupVerification()
    private weak var verificationSource: RemotePlaySource?
    private var verificationTimer: Timer?
    private var advancedViews: [NSView] = []

    init(hub: Hub, onPaired: @escaping () -> Void) throws {
        let host = hub.host
        self.hub = hub; targetHost = host; self.onPaired = onPaired
        client = try RemotePlaySetupClient(host: host, authorizeMutation: { [weak hub] in
            guard let hub, hub.host == host else {
                throw RemotePlaySetupError("The console address changed. Close setup and open it for the new address.")
            }
            if let owner = hub.lease.json["owner"] as? [String: Any] {
                throw RemotePlaySetupError("The PS5 is claimed by \(owner["client"] as? String ?? "another client"). Wait for its claim to be released before setup.")
            }
        })
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Set Up Remote Play"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 560, height: 360)

        func text(_ value: String, bold: Bool = false) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: value)
            label.preferredMaxLayoutWidth = 590
            if bold { label.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
            return label
        }
        func button(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            actions.append(button)
            return button
        }
        func row(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views); stack.spacing = 8; return stack
        }
        let helperButtons = row([button("Check Console", #selector(startHelper))])
        accounts.target = self; accounts.action = #selector(selectedAccount)
        accounts.addItem(withTitle: "Inspect accounts first…")
        accounts.isEnabled = false
        let prepare = button("Prepare Selected Account…", #selector(prepareAccount))
        prepareButton = prepare; prepare.isEnabled = false
        accountID.placeholderString = "Base64 account ID (8 bytes)"
        pin.placeholderString = "Eight-digit PIN from Pair Device"
        // Placeholders vanish once filled, so VoiceOver needs real labels.
        accounts.setAccessibilityLabel("Account")
        accountID.setAccessibilityLabel("Account ID")
        pin.setAccessibilityLabel("Pairing PIN")
        accountID.widthAnchor.constraint(equalToConstant: 370).isActive = true
        pin.widthAnchor.constraint(equalToConstant: 250).isActive = true
        for label in [status, accountStatus, verificationStatus] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 590
        }
        let divider = NSBox(); divider.boxType = .separator
        let cancel = NSButton(title: "Close", target: self, action: #selector(close))
        let advanced = NSButton(checkboxWithTitle: "Advanced: enter an existing account ID", target: self, action: #selector(toggleAdvanced(_:)))
        let accountRow = row([text("Account ID:"), accountID])
        accountRow.isHidden = true; advancedViews = [accountRow]
        retryVerification.target = self; retryVerification.action = #selector(retryCapture)
        retryVerification.isEnabled = false
        let content = NSStackView(views: [
            text("Target PS5: \(host)", bold: true),
            text("1. Choose an account", bold: true),
            text("Keep the PS5 on and Payload Manager available. The helper inspects local users without changing them. Preparation needs your separate confirmation and creates a console backup before changing the selected user."),
            helperButtons, accounts, accountStatus, prepare,
            divider,
            text("2. Prepare and pair", bold: true),
            text("Sign into the selected local user on the PS5. Open Settings → System → Remote Play, enable Remote Play, then choose Pair Device. Enter its eight-digit PIN here before it expires. An offline user can use the account ID produced above; an existing registration can use a manually entered Base64 account ID."),
            advanced, accountRow,
            row([text("Pairing PIN:"), pin]),
            row([button("Pair & Use Remote Play", #selector(pair)), cancel]),
            status,
            text("3. Verify capture", bold: true),
            text("On the supported offline console, the app may apply a temporary Remote Play fix after the PS5 restarts. Payload Manager must be available."),
            verificationStatus, retryVerification,
        ])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        let root = RemotePlaySetupDocumentView(); root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            divider.widthAnchor.constraint(equalTo: content.widthAnchor),
            status.widthAnchor.constraint(equalTo: content.widthAnchor),
            accountStatus.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = root
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        window.contentView = scroll
    }

    func show() {
        if let screen = window.screen ?? NSScreen.main {
            var frame = window.frame
            frame.size.height = min(frame.height, screen.visibleFrame.height)
            window.setFrame(frame, display: false)
        }
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        retryVerification.isEnabled = (try? hub.remotePlayCredentials.load(host: targetHost)) != nil
    }

    private func authorize() throws {
        guard hub.host == targetHost else {
            throw RemotePlaySetupError("The console address changed. Reopen setup from Settings for the new address.")
        }
        if let owner = hub.lease.json["owner"] as? [String: Any] {
            throw RemotePlaySetupError("The PS5 is claimed by \(owner["client"] as? String ?? "another client"). Wait for its claim to be released.")
        }
    }

    private func setBusy(_ value: Bool, message: String? = nil) {
        busy = value
        for button in actions { button.isEnabled = !value }
        prepareButton?.isEnabled = !value && selected != nil && selected?.preparationVerified != true
        accounts.isEnabled = !value && !users.isEmpty
        accountID.isEnabled = !value; pin.isEnabled = !value
        if let message { status.stringValue = message }
    }

    @objc private func startHelper() {
        guard !busy else { return }
        do {
            try authorize()
            guard let path = Bundle.main.resourceURL?.appendingPathComponent("remoteplay/remoteplay-setup.elf"),
                  let payload = try? Data(contentsOf: path), !payload.isEmpty else {
                throw RemotePlaySetupError("The bundled setup helper is missing. Rebuild the app with its payload resources.")
            }
            users = []; selectedAccount()
            setBusy(true, message: "Uploading and starting the inspection helper on \(targetHost)…")
            client.startHelper(payload: payload) { [weak self] result in
                guard let self else { return }
                self.setBusy(false)
                switch result {
                case .success: self.inspect()
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
            }
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc private func inspect() {
        guard !busy else { return }
        users = []; accounts.removeAllItems(); selectedAccount()
        setBusy(true, message: "Inspecting accounts on \(targetHost)…")
        client.inspect { [weak self] result in
            guard let self else { return }
            self.setBusy(false)
            switch result {
            case .success(let snapshot):
                self.users = snapshot.accounts
                self.accounts.addItems(withTitles: snapshot.accounts.map { $0.name })
                if let foreground = snapshot.accounts.firstIndex(where: \.foreground) { self.accounts.selectItem(at: foreground) }
                self.accounts.isEnabled = !self.users.isEmpty
                self.selectedAccount()
                self.status.stringValue = self.users.isEmpty ? "No local users found. Create a local user on the TV, then inspect again." : "Accounts inspected. Select the intended user before preparation. Firmware: \(snapshot.firmware)."
            case .failure(let error): self.status.stringValue = error.localizedDescription
            }
        }
    }

    private var selected: RemotePlaySetupAccount? {
        let index = accounts.indexOfSelectedItem
        return users.indices.contains(index) ? users[index] : nil
    }

    @objc private func selectedAccount() {
        prepareButton?.isEnabled = !busy && selected != nil && selected?.preparationVerified != true
        guard let account = selected else { accountStatus.stringValue = "No account inspected."; return }
        accounts.toolTip = "User \(account.userId), slot \(account.slot)"
        let zero = (try? RemotePlayCredentials.parseAccountID(account.accountIdB64).allSatisfy { $0 == 0 }) == true
        accountStatus.stringValue = "\(account.name): " + (account.preparationVerified ? "persisted preparation verified." : "persisted preparation not verified.")
            + (zero ? " No account ID assigned yet." : " Existing account ID will be preserved.")
        accountID.stringValue = zero ? "" : account.accountIdB64
    }

    @objc private func prepareAccount() {
        guard !busy else { return }
        do {
            try authorize()
            guard let account = selected else { throw RemotePlaySetupError("Inspect and select a user first.") }
            let zero = try RemotePlayCredentials.parseAccountID(account.accountIdB64).allSatisfy { $0 == 0 }
            let alert = NSAlert()
            alert.messageText = "Prepare \(account.name) for Remote Play?"
            alert.informativeText = "Target: \(targetHost)\nUser: \(account.name) (\(account.userId)), slot \(account.slot)\n\n"
                + (zero ? "This assigns a persistent offline account ID to this user. " : "This preserves the existing account ID. ")
                + "The helper backs up original values on the console, then writes this user's NP auth.dat/config.dat files and selected-slot account registry values. Persisted readback does not verify live streaming readiness. Saves remain associated with this user's account identity; changing that identity later can affect save ownership and access. Only continue for the user you intend to keep. Other users are not changed. No automatic reboot occurs."
            alert.addButton(withTitle: "Prepare Account"); alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                self.setBusy(true, message: "Preparing the confirmed user on \(self.targetHost)…")
                self.client.prepare(account: account, confirmed: true) { [weak self] result in
                    guard let self else { return }
                    self.setBusy(false)
                    // Drop the inspection selection after any write attempt; retry needs fresh inspection and consent.
                    self.users = []; self.accounts.removeAllItems(); self.accounts.isEnabled = false
                    switch result {
                    case .success(let result):
                        self.accountID.stringValue = result.account.accountIdB64
                        self.accountStatus.stringValue = "\(result.account.name): persisted preparation verified."
                        self.status.stringValue = "Persisted preparation verified; live streaming is unverified. Enable Remote Play and obtain a fresh Pair Device PIN on the TV. A user-coordinated reboot may be needed if the console has not refreshed account state."
                            + (result.backupPath.isEmpty ? "" : " Backup: \(result.backupPath)")
                    case .failure(let error): self.status.stringValue = error.localizedDescription
                    }
                }
            }
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc private func pair() {
        guard !busy else { return }
        do {
            try authorize()
            let account = try RemotePlayCredentials.parseAccountID(accountID.stringValue)
            guard account.contains(where: { $0 != 0 }) else { throw RemotePlaySetupError("Prepare the selected offline account or enter an existing nonzero account ID.") }
            let pinText = pin.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try RemotePlayCredentials.parsePIN(pinText)
            generation &+= 1
            let token = generation, host = targetHost
            let target = RemotePlayPairingTarget(host: host, captureGeneration: hub.captureGeneration)
            let registration = RemotePlayRegistration()
            self.registration = registration
            setBusy(true, message: "Pairing with \(host)…")
            registration.start(host: host, accountID: account, pin: pinText) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.registration = nil; self.pin.stringValue = ""; self.setBusy(false)
                    do {
                        let result = try result.get()
                        let credentials = try RemotePlayCredentials(consoleID: result.consoleMAC.map { String(format: "%02x", $0) }.joined(),
                            nickname: result.nickname, accountID: account, registrationKey: result.registrationKey,
                            sessionKey: result.rpKey, host: host)
                        try self.hub.remotePlayCredentials.save(credentials)
                        self.onPaired()
                        guard target.matches(host: self.hub.host, captureGeneration: self.hub.captureGeneration) else {
                            self.status.stringValue = "Paired with \(host) and saved in Keychain. The console or capture source changed; select Remote Play for \(host) in Settings to connect."
                            return
                        }
                        try self.authorize()
                        guard let ui = self.hub.ui else { throw RemotePlaySetupError("Pairing saved. Capture is not ready yet.") }
                        try ui.restartCapture(video: "remoteplay", audio: "remoteplay")
                        UserDefaults.standard.set("remoteplay", forKey: captureVideoKey)
                        UserDefaults.standard.set("remoteplay", forKey: captureAudioKey)
                        self.onPaired()
                        self.status.stringValue = "Paired and saved in Keychain. Verifying capture…"
                        self.announce(self.status.stringValue)
                        self.beginVerification()
                    } catch {
                        self.status.stringValue = error.localizedDescription + " If pairing failed or the PIN expired, obtain a fresh Pair Device PIN and try Pair again. Account preparation is never repeated automatically."
                        self.announce(self.status.stringValue)
                    }
                }
            }
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc private func toggleAdvanced(_ sender: NSButton) {
        for view in advancedViews { view.isHidden = sender.state != .on }
    }

    @objc private func retryCapture() {
        do {
            try authorize()
            guard try hub.remotePlayCredentials.load(host: targetHost) != nil, let ui = hub.ui else {
                throw RemotePlaySetupError("Pair this console first.")
            }
            try ui.restartCapture(video: "remoteplay", audio: "remoteplay")
            beginVerification()
        } catch { verificationStatus.stringValue = error.localizedDescription }
    }

    private func beginVerification() {
        verificationTimer?.invalidate()
        verification = RemotePlaySetupVerification()
        verificationSource = hub.source as? RemotePlaySource
        retryVerification.isEnabled = false
        verificationStatus.stringValue = "Connecting to verify video and audio…"
        verificationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshVerification()
        }
    }

    func refreshVerification() {
        guard verificationTimer != nil else { return }
        guard hub.host == targetHost, let source = verificationSource, hub.source === source else {
            verificationStatus.stringValue = "Capture changed. Pairing is kept; reopen setup for the selected console."
            verificationTimer?.invalidate(); verificationTimer = nil
            return
        }
        let state = source.status
        // start() is queued; do not mistake the initial stopped state for a failed connection.
        if state.phase == .stopped && state.generation == 0 { return }
        switch verification.observe(state, now: ProcessInfo.processInfo.systemUptime) {
        case .pending: verificationStatus.stringValue = state.summary
        case .verified:
            verificationStatus.stringValue = "Verified: live video and audio received. Remote Play is ready."
            verificationTimer?.invalidate(); verificationTimer = nil
            retryVerification.isEnabled = true
            announce(verificationStatus.stringValue)
        case .incomplete:
            verificationStatus.stringValue = (state.issue ?? "Video and audio were not both received within ten seconds.") + " Pairing is kept. Retry verification after checking the console."
            verificationTimer?.invalidate(); verificationTimer = nil
            retryVerification.isEnabled = true
            announce(verificationStatus.stringValue)
        }
    }

    /// Status text changes silently for VoiceOver; outcomes are announced.
    private func announce(_ message: String) {
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    @objc private func close() { window.close() }
    func windowWillClose(_ notification: Notification) {
        generation &+= 1
        verificationTimer?.invalidate(); verificationTimer = nil
        client.cancel(); registration?.cancel(); registration = nil
        pin.stringValue = ""
    }
}
