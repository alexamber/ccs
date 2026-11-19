import AppKit
import CCSCore

/// Opens immediately from recent state. Fresh status can replace an untouched
/// list; once navigation starts, rows stay under the same pointer/selection.
final class SessionOverview: NSObject, NSPopoverDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private final class StatusDot: NSView {
        let color: NSColor
        init(color: NSColor) { self.color = color; super.init(frame: .zero); setAccessibilityElement(false) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var allowsVibrancy: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            color.setFill(); NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
        }
    }
    private final class Table: NSTableView {
        var onOpen: (() -> Void)?, onClose: (() -> Void)?, onInteract: (() -> Void)?, onSearch: (() -> Void)?
        private var pointerArea: NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let pointerArea { removeTrackingArea(pointerArea) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(area); pointerArea = area
        }
        override func mouseEntered(with event: NSEvent) { onInteract?() }
        override func mouseDown(with event: NSEvent) { onInteract?(); super.mouseDown(with: event) }
        override func scrollWheel(with event: NSEvent) { onInteract?(); super.scrollWheel(with: event) }
        override func keyDown(with event: NSEvent) {
            onInteract?()
            if event.keyCode == 3 && event.modifierFlags.contains(.command) { onSearch?(); return }
            if event.keyCode == 126 && selectedRow <= 0 { onSearch?(); return }
            if event.keyCode == 53 { onClose?(); return }
            if event.keyCode == 36 || event.keyCode == 76 { onOpen?(); return }
            super.keyDown(with: event)
        }
    }
    let popover = NSPopover()
    private let table = Table(), scroll = NSScrollView()
    let search = NSSearchField()
    private let message = NSTextField(labelWithString: "Checking active sessions…")
    private let heading = NSTextField(labelWithString: "Active sessions")
    private let refreshButton = NSButton()
    private var allTargets = [TerminalSwitchTarget](), targets = [TerminalSwitchTarget](), available = Set<String>(), finished = Set<String>()
    private var pending: TerminalActivitySnapshot?
    private var interacted = false
    private var statusText = ""
    private var maximumListHeight: CGFloat = 408
    private var listHeight: NSLayoutConstraint!
    private(set) var generation = 0
    var onSelect: ((TerminalSwitchTarget, [Session]) -> Void)?, onBrowse: (() -> Void)?, onRefresh: (() -> Void)?
    var onClose: (() -> Void)?
    var isShown: Bool { popover.isShown }
    var visibleKeys: [String] { targets.map(\.key) }
    var visibleListHeight: CGFloat { listHeight.constant }
    var hasPendingReorder: Bool { pending != nil }
    var selectableKeys: Set<String> { available }

    override init() {
        super.init()
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
        let controller = NSViewController(); controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        popover.contentViewController = controller
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        message.font = .systemFont(ofSize: 10); message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        search.placeholderString = "Filter active sessions"
        search.controlSize = .small; search.delegate = self; search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Filter active sessions by name, folder, provider, or status")
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session")))
        table.headerView = nil; table.style = .plain; table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.rowHeight = 32
        table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(openClicked)
        table.onOpen = { [weak self] in self?.openSelected() }; table.onClose = { [weak self] in self?.cancelSearchOrClose() }
        table.onInteract = { [weak self] in self?.noteInteraction() }
        table.onSearch = { [weak self] in
            guard let self else { return }
            self.popover.contentViewController?.view.window?.makeFirstResponder(self.search)
        }
        table.setAccessibilityLabel("Active sessions, attention first, then working, then ready")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 0); listHeight.isActive = true
        let browse = NSButton(title: "All sessions…", target: self, action: #selector(browse))
        browse.isBordered = false; browse.contentTintColor = .linkColor; browse.font = .systemFont(ofSize: 11)
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh sessions")
        refreshButton.isBordered = false; refreshButton.target = self; refreshButton.action = #selector(refreshList)
        refreshButton.toolTip = "Refresh sessions and their order"
        refreshButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [browse, spacer, refreshButton]); footer.alignment = .centerY
        let stack = NSStackView(views: [heading, search, message, scroll, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -10)])
        for view in [heading, search, message, scroll, footer] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    @discardableResult func show(anchor: NSView, cached: TerminalActivitySnapshot? = nil, finished: Set<String> = []) -> Int {
        generation += 1; interacted = false; pending = nil; allTargets = []; targets = []; available = []; self.finished = finished
        search.stringValue = ""
        maximumListHeight = min(408, max(102, (anchor.window?.screen?.visibleFrame.height ?? 700) - 210))
        if let cached { replaceList(cached) }
        else { table.reloadData(); heading.stringValue = "Active sessions" }
        statusText = cached == nil ? "Checking active sessions…" : "Recent sessions · updating…"
        updateMessage()
        refreshButton.contentTintColor = .secondaryLabelColor
        resize()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeFirstResponder(search)
        return generation
    }
    func noteInteraction() { interacted = true }
    func supply(_ snapshot: TerminalActivitySnapshot, finished: Set<String>, generation: Int) {
        guard isShown, self.generation == generation else { return }
        self.finished = finished
        let fresh = SessionActivity.sorted(snapshot.context.targets)
        if interacted, !allTargets.isEmpty {
            let byKey = Dictionary(fresh.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            available = Set(byKey.keys)
            pending = allTargets.map(\.key) == fresh.map(\.key) ? nil : snapshot
            allTargets = allTargets.map { byKey[$0.key] ?? $0 }
            applyFilter()
        } else {
            replaceList(snapshot)
            resize()
        }
        statusText = fresh.isEmpty ? "No active Terminal sessions found." : pending == nil ? "Up to date" : "List changed · refresh to reorder"
        if !snapshot.unavailableProviders.isEmpty {
            statusText = snapshot.unavailableProviders.map(\.title).joined(separator: ", ") + " status unavailable; some sessions may be missing."
        }
        updateMessage()
        refreshButton.contentTintColor = pending == nil ? .secondaryLabelColor : .controlAccentColor
    }
    private func replaceList(_ snapshot: TerminalActivitySnapshot) {
        allTargets = SessionActivity.sorted(snapshot.context.targets)
        available = Set(allTargets.map(\.key)); pending = nil
        applyFilter()
    }
    private func applyFilter() {
        let keep = targets.indices.contains(table.selectedRow) ? targets[table.selectedRow].key : nil
        let terms = search.stringValue.split(whereSeparator: \.isWhitespace).map(String.init)
        targets = allTargets.filter { target in
            let status = finished.contains(target.key) ? "Finished" : SessionActivity.description(for: target.session)
            let text = [target.title, target.subtitle, target.session?.cwd ?? "", target.session?.status ?? "", status,
                        SessionActivity(status: target.session?.status ?? "unknown").title].joined(separator: " ")
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }
        table.reloadData()
        if let row = keep.flatMap({ key in targets.firstIndex { $0.key == key } }) ?? targets.firstIndex(where: { available.contains($0.key) }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        resize(); updateMessage()
    }
    private func updateMessage() {
        heading.stringValue = search.stringValue.isEmpty ? "Active sessions · \(allTargets.count)" : "Active sessions · \(targets.count) of \(allTargets.count)"
        message.stringValue = !search.stringValue.isEmpty && targets.isEmpty ? "No active sessions match. Try a name, folder, or status." : statusText
        message.toolTip = statusText
    }
    func controlTextDidChange(_ obj: Notification) { noteInteraction(); applyFilter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.moveDown(_:)) { focusList(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { openSelected(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancelSearchOrClose(); return true }
        return false
    }
    private func cancelSearchOrClose() {
        if search.stringValue.isEmpty { close() }
        else { search.stringValue = ""; applyFilter(); popover.contentViewController?.view.window?.makeFirstResponder(search) }
    }
    func fail(_ error: Error, generation: Int) {
        guard isShown, self.generation == generation else { return }
        statusText = allTargets.isEmpty ? "Couldn’t load sessions. Try refresh." : "Couldn’t refresh · showing recent sessions"
        updateMessage()
        message.toolTip = error.localizedDescription
    }
    func close() { generation += 1; popover.performClose(nil); onClose?() }
    func popoverDidClose(_ notification: Notification) { generation += 1; onClose?() }
    private func resize() {
        listHeight.constant = min(CGFloat(targets.count * 34), maximumListHeight)
        popover.contentSize = NSSize(width: 400, height: 114 + listHeight.constant)
    }
    private func focusList() {
        if !targets.isEmpty { popover.contentViewController?.view.window?.makeFirstResponder(table) }
    }
    @objc func refreshList() {
        interacted = false
        if let snapshot = pending {
            supply(snapshot, finished: finished, generation: generation)
        } else {
            message.stringValue = "Updating…"; onRefresh?()
        }
    }
    @objc private func browse() { close(); onBrowse?() }
    @objc private func openClicked() { openRow(table.clickedRow) }
    private func openSelected() { openRow(table.selectedRow) }
    func openRow(_ row: Int) {
        guard targets.indices.contains(row) else { return }
        let target = targets[row]
        guard available.contains(target.key) else { return }
        let sessions = allTargets.compactMap(\.session)
        close(); onSelect?(target, sessions)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { targets.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { available.contains(targets[row].key) }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 32 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let target = targets[row], enabled = available.contains(targets[row].key)
        let activity = enabled ? SessionActivity(status: target.session?.status ?? "unknown") : .unknown
        let name = NSTextField(labelWithString: target.title); name.font = .systemFont(ofSize: 12, weight: .medium)
        name.textColor = enabled ? .labelColor : .secondaryLabelColor
        let status = !enabled ? "No longer confirmed" : finished.contains(target.key) ? "Finished" : SessionActivity.description(for: target.session)
        let detail = NSTextField(labelWithString: status + " · " + target.subtitle)
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
        let dot = StatusDot(color: activity.tint)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true; dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        let text = NSStackView(views: [name, detail]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 0
        let view = NSView(); text.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dot); view.addSubview(text)
        NSLayoutConstraint.activate([dot.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3), dot.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7), text.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        for label in [name, detail] {
            label.lineBreakMode = .byTruncatingMiddle; label.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        view.toolTip = target.title + "\n" + status + "\n" + target.subtitle
        view.setAccessibilityLabel(target.title + ", " + detail.stringValue)
        return view
    }
}
