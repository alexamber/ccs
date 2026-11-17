import AppKit
import CCSCore

/// Establish the current tab before showing a selection. The first highlight
/// includes the opening key press; later refreshes never change this gesture.
final class SessionSwitcher: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 130), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let table = NSTableView(), scroll = NSScrollView()
    private let message = NSTextField(labelWithString: "Finding active Terminal sessions…")
    private let hint = NSTextField(labelWithString: "⌥Tab Next · ⇧ Reverse · Release ⌥ to switch · Esc Cancel")
    private var targets = [TerminalSwitchTarget](), steps = 1
    private var ready = false
    private(set) var presentation = 0
    private var timer: Timer?, monitor: Any?
    private var held: () -> Bool = { NSEvent.modifierFlags.contains(.option) }
    private var previousApplication: NSRunningApplication?
    var onCommit: ((TerminalSwitchTarget, [Session]) -> Void)?
    var highlighted: TerminalSwitchTarget? { targets.indices.contains(table.selectedRow) ? targets[table.selectedRow] : nil }
    var selected: TerminalSwitchTarget? { ready ? highlighted : nil }

    override init() {
        super.init()
        panel.delegate = self; panel.isReleasedWhenClosed = false; panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        let surface = NSVisualEffectView(); surface.material = .popover; surface.state = .active
        surface.wantsLayer = true; surface.layer?.cornerRadius = 16; surface.layer?.masksToBounds = true
        panel.contentView = surface
        let icon = NSImageView(image: BrandIcon.image(size: 30))
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let title = NSTextField(labelWithString: "Active sessions"); title.font = .systemFont(ofSize: 13, weight: .semibold)
        let heading = NSStackView(views: [icon, title]); heading.spacing = 8
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session")))
        table.headerView = nil; table.backgroundColor = .clear; table.style = .plain
        table.rowHeight = 46; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(commit)
        scroll.documentView = table; scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        message.font = .systemFont(ofSize: 12); message.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, message, scroll, hint]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -12)])
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, event.window === self.panel else { return event }
            switch event.keyCode {
            case 53: self.hide(restoreFocus: true)
            case 48: self.cycle(event.modifierFlags.contains(.shift) ? -1 : 1)
            case 125: self.cycle(1)
            case 126: self.cycle(-1)
            case 36, 76: self.commit()
            default: return event
            }
            return nil
        }
    }
    deinit { timer?.invalidate(); if let monitor { NSEvent.removeMonitor(monitor) } }
    @discardableResult
    func show(targets: [TerminalSwitchTarget] = [], step: Int,
              optionHeld: @escaping () -> Bool = { NSEvent.modifierFlags.contains(.option) }) -> Int {
        presentation += 1; ready = false
        self.targets = targets; steps = step; held = optionHeld
        previousApplication = NSWorkspace.shared.frontmostApplication
        message.stringValue = "Finding active Terminal sessions…"; message.isHidden = !targets.isEmpty
        table.reloadData(); table.deselectAll(nil)
        resize()
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(table)
        timer?.invalidate()
        timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self, self.ready, !self.held(), !self.targets.isEmpty else { return }; self.commit()
        }
        RunLoop.main.add(timer!, forMode: .common)
        return presentation
    }
    func supply(_ values: [TerminalSwitchTarget], currentKey: String?, presentation: Int) {
        guard panel.isVisible, presentation == self.presentation, !ready else { return }
        ready = true
        targets = values; table.reloadData()
        message.stringValue = "No active Terminal sessions found."; message.isHidden = !targets.isEmpty
        resize()
        guard !targets.isEmpty else { return }
        let origin = currentKey.flatMap { key in targets.firstIndex { $0.key == key } }
        let index = origin ?? (steps >= 0 ? -1 : 0)
        select(index + steps)
    }
    func showFailure(_ text: String, presentation: Int) {
        guard panel.isVisible, presentation == self.presentation, !ready else { return }
        targets = []; table.reloadData(); message.isHidden = false; message.stringValue = text; resize()
    }
    func cycle(_ delta: Int) {
        if !ready { steps += delta; return }
        guard !targets.isEmpty else { return }
        select(max(0, table.selectedRow) + delta)
    }
    private func select(_ value: Int) {
        let index = (value % targets.count + targets.count) % targets.count
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); table.scrollRowToVisible(index)
    }
    @objc func commit() {
        guard panel.isVisible, let selected else { return }
        let sessions = targets.compactMap(\.session)
        hide(); onCommit?(selected, sessions)
    }
    func hide(restoreFocus: Bool = false) {
        presentation += 1
        timer?.invalidate(); timer = nil; panel.orderOut(nil)
        if restoreFocus, previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication?.activate(options: []) }
        previousApplication = nil
    }
    func windowDidResignKey(_ notification: Notification) { hide() }
    private func resize() {
        let height = targets.isEmpty ? 116 : 86 + min(targets.count, 5) * 48
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let area = screen.visibleFrame
        panel.setFrame(NSRect(x: area.midX - 200, y: area.midY - CGFloat(height) / 2, width: 400, height: CGFloat(height)), display: true)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { targets.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { ready }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PickerRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let target = targets[row]
        let name = NSTextField(labelWithString: target.title); name.font = .systemFont(ofSize: 13, weight: .medium)
        let path = NSTextField(labelWithString: target.subtitle); path.font = .systemFont(ofSize: 11); path.textColor = .secondaryLabelColor
        let cell = NSTableCellView()
        let text = NSStackView(views: [name, path]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(text)
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        for field in [name, path] { field.lineBreakMode = .byTruncatingMiddle; field.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true; field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        return cell
    }
}
