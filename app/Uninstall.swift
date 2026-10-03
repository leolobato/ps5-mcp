// The Uninstall sheet: every installed game/app with a checkbox; the caller uninstalls the checked ones.

import AppKit

final class UninstallSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    private let titles: [Title]
    private var checked = Set<String>()
    private let table = NSTableView()
    private let uninstall = NSButton(title: "Uninstall", target: nil, action: nil)
    private let onDone: ([Title]) -> Void

    /// `onDone` gets the checked titles, or an empty list on Cancel.
    init(titles: [Title], onDone: @escaping ([Title]) -> Void) {
        self.titles = titles
        self.onDone = onDone
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 440), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.minSize = NSSize(width: 380, height: 300)

        let heading = NSTextField(labelWithString: "Uninstall games/apps")
        heading.font = .boldSystemFont(ofSize: 13)
        let detail = NSTextField(wrappingLabelWithString:
            "Their data on the console is deleted, and for ShadowMountPlus titles their source too. "
            + "The console refuses while a game is running; close it first.")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor

        for (id, title, width) in [("check", "", 24.0), ("name", "Name", 260.0), ("id", "ID", 90.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            if id == "check" { column.minWidth = 24; column.maxWidth = 24 }
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelled))
        cancel.keyEquivalent = "\u{1b}"
        uninstall.target = self
        uninstall.action = #selector(confirmed)
        uninstall.hasDestructiveAction = true
        uninstall.isEnabled = false
        let buttons = NSStackView(views: [NSView(), cancel, uninstall])
        buttons.spacing = 8

        let content = NSStackView(views: [heading, detail, scroll, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [detail, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true
        }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        window.contentView = content
    }

    func numberOfRows(in tableView: NSTableView) -> Int { titles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let title = titles[row]
        switch tableColumn?.identifier.rawValue {
        case "check":
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
            box.tag = row
            box.state = checked.contains(title.id) ? .on : .off
            box.setAccessibilityLabel("Uninstall \(title.name)")
            return box
        case "name":
            let label = NSTextField(labelWithString: title.name)
            label.lineBreakMode = .byTruncatingTail
            let icon = NSImageView(image: title.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
            let cell = NSStackView(views: [icon, label])
            cell.spacing = 6
            return cell
        default:
            let label = NSTextField(labelWithString: title.id)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            return NSStackView(views: [label])  // centred vertically, like the name
        }
    }

    @objc private func toggled(_ sender: NSButton) { set(sender.tag, sender.state == .on) }

    private func set(_ row: Int, _ on: Bool) {
        if on { checked.insert(titles[row].id) } else { checked.remove(titles[row].id) }
        uninstall.title = checked.isEmpty ? "Uninstall" : "Uninstall \(checked.count)"
        uninstall.isEnabled = !checked.isEmpty
    }

    @objc private func cancelled() { finish([]) }
    @objc private func confirmed() { finish(titles.filter { checked.contains($0.id) }) }

    private func finish(_ chosen: [Title]) {
        window.sheetParent?.endSheet(window)
        onDone(chosen)
    }
}
