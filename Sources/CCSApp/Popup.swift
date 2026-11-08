import AppKit
import CCSCore

final class Popup: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let panel: PickerPanel
    let engine: Engine
    var settings: Settings
    var onSettings: (() -> Void)?
    var onSave: ((Settings) throws -> Void)?
    private let search = NSSearchField(), table = NSTableView(), scroll = NSScrollView()
    private let views = NSSegmentedControl(labels: ["Recent", "Folders"], trackingMode: .selectOne, target: nil, action: nil)
    private let ranges = NSSegmentedControl(labels: ["1d", "3d", "7d", "30d", "All"], trackingMode: .selectOne, target: nil, action: nil)
    private let providers = NSSegmentedControl(labels: ProviderFilter.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let newProvider = NSPopUpButton()
    private let newProviderValue = NSTextField(labelWithString: "")
    private let keys = NSTextField(labelWithString: "↵ Open   ⇧↵ New here   ⌃⇥ View   ⌘N New   Esc Close")
    private let shortcuts = NSButton(title: "Shortcuts", target: nil, action: nil)
    private var shortcutsPopover: NSPopover?
    private let count = NSTextField(labelWithString: ""), message = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "Loading sessions…")
    private var sessions = [Session](), rows = [SessionRow](), timer: Timer?, monitor: Any?
    private var generation = 0, loading = false, asking = false
    private var launching = false, issues = [Provider: String]()
    private var installedProviders: [Provider]?
    private var previousApplication: NSRunningApplication?
    private var days: Int, recent: Bool
    init(engine: Engine, settings: Settings) {
        self.engine = engine; self.settings = settings
        days = settings.defaultDays; recent = !settings.folders
        panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 470), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.autorecalculatesKeyViewLoop = true
        panel.delegate = self; panel.isReleasedWhenClosed = false
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = false; panel.title = "CCS session picker"
        let background = NSVisualEffectView(); background.material = .popover; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 14; background.layer?.masksToBounds = true
        panel.contentView = background
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; background.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12)])
        search.placeholderString = "Search Claude and Codex sessions"; search.font = .systemFont(ofSize: 17)
        search.delegate = self; search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Search sessions")
        stack.addArrangedSubview(search); search.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let bar = NSStackView(); bar.spacing = 10
        views.target = self; views.action = #selector(changeView); views.selectedSegment = recent ? 0 : 1
        ranges.target = self; ranges.action = #selector(changeRange); ranges.selectedSegment = dateWindows.firstIndex(of: days) ?? 2
        views.toolTip = "Control-Tab switches Recent / Folders"
        views.setAccessibilityLabel("Session grouping"); ranges.setAccessibilityLabel("Date range")
        providers.target = self; providers.action = #selector(changeProvider)
        providers.selectedSegment = ProviderFilter.allCases.firstIndex(of: settings.providerFilter) ?? 0
        providers.isHidden = settings.enabledProviders.count == 1
        providers.setAccessibilityLabel("Session provider"); providers.toolTip = "⌘1 All · ⌘2 Claude · ⌘3 Codex"
        count.font = .systemFont(ofSize: 11); count.textColor = .secondaryLabelColor
        bar.addArrangedSubview(views); bar.addArrangedSubview(providers); bar.addArrangedSubview(ranges)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal); bar.addArrangedSubview(spacer); bar.addArrangedSubview(count)
        stack.addArrangedSubview(bar); bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session")))
        table.headerView = nil; table.backgroundColor = .clear; table.style = .fullWidth
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(clicked)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.setAccessibilityLabel("Claude Code and Codex sessions")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        stack.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        empty.textColor = .secondaryLabelColor; empty.font = .systemFont(ofSize: 13)
        empty.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(empty)
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)])
        message.font = .systemFont(ofSize: 11); message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail; message.setAccessibilityLabel("Session status")
        stack.addArrangedSubview(message); message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let footer = NSStackView(); footer.spacing = 8
        newProvider.addItems(withTitles: Provider.allCases.map { "New: " + $0.title })
        newProvider.selectItem(at: Provider.allCases.firstIndex(of: settings.newProvider) ?? 0)
        newProvider.controlSize = .small; newProvider.font = .systemFont(ofSize: 11)
        newProvider.target = self; newProvider.action = #selector(changeNewProvider)
        newProvider.setAccessibilityLabel("Provider for new dated sessions")
        newProvider.toolTip = "Used by ⌘N and \(settings.hotkeyLabel) again. ⇧↵ uses the selected row’s provider."
        footer.addArrangedSubview(newProvider)
        newProviderValue.font = .systemFont(ofSize: 11, weight: .medium)
        footer.addArrangedSubview(newProviderValue)
        keys.font = .systemFont(ofSize: 10); keys.textColor = .secondaryLabelColor
        footer.addArrangedSubview(keys)
        shortcuts.target = self; shortcuts.action = #selector(showShortcuts)
        shortcuts.isBordered = false; shortcuts.font = .systemFont(ofSize: 10)
        shortcuts.contentTintColor = .secondaryLabelColor
        shortcuts.toolTip = "All keyboard shortcuts (⌘/)"; shortcuts.setAccessibilityLabel("Keyboard shortcuts")
        footer.addArrangedSubview(shortcuts)
        let gear = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!, target: self, action: #selector(settingsClicked)); gear.isBordered = false; gear.toolTip = "Settings (⌘,)"
        footer.addArrangedSubview(gear); stack.addArrangedSubview(footer)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, !self.asking else { return event }
            if self.shortcutsPopover?.isShown == true {
                if event.keyCode == 53 || (event.keyCode == 44 && event.modifierFlags.contains(.command)) {
                    self.shortcutsPopover?.close(); return nil
                }
                return event
            }
            guard event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) }; timer?.invalidate() }
    func apply(_ settings: Settings) {
        let sourcesChanged = self.settings.enabledProviders != settings.enabledProviders
        if sourcesChanged { generation += 1 }
        if self.settings.defaultDays != settings.defaultDays { days = settings.defaultDays }
        if self.settings.folders != settings.folders { recent = !settings.folders }
        self.settings = settings
        search.placeholderString = "Search " + settings.enabledProviders.map(\.title).joined(separator: " and ") + " sessions"
        table.setAccessibilityLabel(settings.enabledProviders.map(\.title).joined(separator: " and ") + " sessions")
        views.selectedSegment = recent ? 0 : 1
        ranges.selectedSegment = dateWindows.firstIndex(of: days) ?? 2
        providers.selectedSegment = ProviderFilter.allCases.firstIndex(of: settings.providerFilter) ?? 0
        providers.isHidden = settings.enabledProviders.count == 1
        for (index, filter) in ProviderFilter.allCases.enumerated() {
            providers.setEnabled(filter == .all || settings.enabledProviders.contains(where: { filter.includes($0) }), forSegment: index)
        }
        newProvider.removeAllItems(); newProvider.addItems(withTitles: settings.enabledProviders.map { "New: " + $0.title })
        newProvider.selectItem(at: settings.enabledProviders.firstIndex(of: settings.newProvider) ?? 0)
        newProvider.isEnabled = settings.enabledProviders.count > 1
        newProvider.isHidden = settings.enabledProviders.count == 1
        newProviderValue.isHidden = settings.enabledProviders.count > 1
        newProviderValue.stringValue = "New: " + settings.newProvider.title
        shortcutsPopover?.close()
        if panel.isVisible { reload(); if sourcesChanged { refresh() } }
    }
    func show(repeatedHotkey: Bool = false) {
        guard !launching else { return }
        if panel.isVisible {
            if repeatedHotkey { newSession() } else { panel.makeKeyAndOrderFront(nil) }
            return
        }
        generation += 1; sessions = []; search.stringValue = ""; reload()
        empty.stringValue = "Loading sessions…"; message.stringValue = ""
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame, size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - f.height * 0.18 - size.height))
        let front = NSWorkspace.shared.frontmostApplication
        previousApplication = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(search)
        refresh()
        timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func hide(restoreFocus: Bool = true) {
        guard panel.isVisible, !asking else { return }
        let wasActive = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        shortcutsPopover?.close()
        generation += 1; panel.orderOut(nil); timer?.invalidate(); timer = nil
        if restoreFocus && wasActive {
            if let previousApplication { previousApplication.activate(options: []) }
            else { NSApp.hide(nil) }
        }
        previousApplication = nil
    }
    func owns(_ window: NSWindow) -> Bool {
        window === panel || window === shortcutsPopover?.contentViewController?.view.window
    }
    func windowDidResignKey(_ notification: Notification) {
        if shortcutsPopover?.isShown != true { hide(restoreFocus: false) }
    }
    func refresh() {
        guard !loading else { return }; loading = true
        let request = generation
        engine.perform(background: true, { service, env in
            let enabled = Settings.load().resolvingProviders(environment: env).enabledProviders
            let sessions = try service.collect(days: 0, provider: .all, enabledProviders: enabled)
            return (sessions, service.issues, enabled.filter { $0.isInstalled(environment: env) })
        }) { [weak self] result in
            guard let self else { return }; self.loading = false
            guard self.panel.isVisible, request == self.generation else {
                if self.panel.isVisible { self.refresh() }; return
            }
            switch result {
            case .success(let payload):
                self.sessions = payload.0; self.issues = payload.1; self.installedProviders = payload.2; self.reload()
            case .failure(let error): self.message.stringValue = error.localizedDescription; self.empty.stringValue = "Couldn’t load sessions. Press ⌘R to retry."
            }
        }
    }
    func reload() {
        let keep = selected?.key
        let cutoff = days == 0 ? 0 : Date().timeIntervalSince1970 - Double(days) * 86400
        rows = sessionRows(sessions.filter { settings.enabledProviders.contains($0.provider) && settings.providerFilter.includes($0.provider) && ($0.isLive || $0.mtime >= cutoff) }, query: search.stringValue, recent: recent, tree: false)
        table.reloadData(); count.stringValue = "\(rows.filter { $0.session != nil }.count) sessions"
        empty.isHidden = rows.contains { $0.session != nil }; empty.stringValue = search.stringValue.isEmpty ? "No sessions in this range" : "No sessions match"
        if sessions.isEmpty, let installedProviders, installedProviders.isEmpty {
            empty.stringValue = "Install " + settings.enabledProviders.map { $0 == .claude ? "Claude Code" : "Codex" }.joined(separator: " or ") + " to get started"
        }
        let warnings = issues.filter { settings.enabledProviders.contains($0.key) && settings.providerFilter.includes($0.key) }.sorted { $0.key.rawValue < $1.key.rawValue }.map(\.value)
        message.stringValue = warnings.isEmpty ? "Refreshes every 5 seconds · \(settings.hotkeyLabel) again starts a new \(settings.newProvider.title) session" : warnings.joined(separator: " · ")
        message.toolTip = message.stringValue
        if let keep, let row = rows.firstIndex(where: { $0.session?.key == keep }) { select(row) }
        else if let row = rows.firstIndex(where: { $0.session != nil }) { select(row) }
    }
    var selected: Session? { table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow].session : nil }
    func select(_ row: Int) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
    func move(_ delta: Int) {
        let choices = rows.indices.filter { rows[$0].session != nil }
        guard !choices.isEmpty else { return }
        let current = choices.firstIndex(of: table.selectedRow) ?? 0
        select(choices[min(max(0, current + delta), choices.count - 1)])
    }
    func handle(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        let control = event.modifierFlags.contains(.control)
        let responder = panel.firstResponder
        let navigatingSessions = responder === table || responder === search || responder === search.currentEditor()
        // Other controls retain their native arrows, Return, Tab and Shift-Tab.
        if [36, 76, 125, 126, 121, 116, 115, 119].contains(event.keyCode), (!navigatingSessions || !event.modifierFlags.intersection([.control, .option, .command]).isEmpty) { return false }
        switch event.keyCode {
        case 53: hide()
        case 36, 76: activateSelected(fresh: event.modifierFlags.contains(.shift))
        case 125: move(1)
        case 126: move(-1)
        case 121: move(10)
        case 116: move(-10)
        case 115: move(-rows.count)
        case 119: move(rows.count)
        case 48 where control && !command: recent.toggle(); views.selectedSegment = recent ? 0 : 1; reload()
        case 123 where command, 124 where command:
            days = cycleWindow(days, step: event.keyCode == 124 ? 1 : -1)
            ranges.selectedSegment = dateWindows.firstIndex(of: days) ?? 2; reload()
        case 45 where command:
            if event.modifierFlags.contains(.shift) { newProvider.performClick(nil) } else { newSession() }
        case 18 where command: selectFilter(.all)
        case 19 where command: selectFilter(.claude)
        case 20 where command: selectFilter(.codex)
        case 15 where command: refresh()
        case 43 where command: settingsClicked()
        case 44 where command: showShortcuts()
        default: return false
        }
        return true
    }
    func controlTextDidChange(_ obj: Notification) { reload() }
    @objc func changeView() { recent = views.selectedSegment == 0; reload() }
    @objc func changeRange() { days = dateWindows[ranges.selectedSegment]; reload() }
    @objc private func changeProvider() { selectFilter(ProviderFilter.allCases[providers.selectedSegment]) }
    func selectFilter(_ filter: ProviderFilter) {
        guard filter == .all || settings.enabledProviders.contains(where: { filter.includes($0) }) else { return }
        var value = Settings.load(); value.providerFilter = filter
        do { try onSave?(value) }
        catch { providers.selectedSegment = ProviderFilter.allCases.firstIndex(of: settings.providerFilter) ?? 0; showError(error, window: panel) }
    }
    @objc private func changeNewProvider() {
        var value = Settings.load(); value.newProvider = settings.enabledProviders[max(0, newProvider.indexOfSelectedItem)]
        do { try onSave?(value) }
        catch { newProvider.selectItem(at: settings.enabledProviders.firstIndex(of: settings.newProvider) ?? 0); showError(error, window: panel) }
    }
    @objc func clicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row), rows[row].session != nil else { return }
        select(row); activateSelected(fresh: NSEvent.modifierFlags.contains(.shift))
    }
    @objc func showShortcuts() {
        if shortcutsPopover?.isShown == true { shortcutsPopover?.close(); return }
        guard panel.isVisible else { return }
        var reference: [(String, String)] = [
            (settings.hotkeyLabel, "Open picker; press again for a new dated session"),
            ("↑ / ↓", "Select session in search or list"),
            ("Page Up / Down", "Move ten sessions"),
            ("Home / End", "First / last session"),
            ("↵", "Open selected session"),
            ("⇧↵", "Start clean in the selected folder"),
            ("⌃⇥", "Switch Recent / Folders"),
            ("⇥ / ⇧⇥", "Move keyboard focus"),
            ("⌘← / ⌘→", "Change date range"),
            ("⌘N", "New dated session · " + settings.newProvider.title)
        ]
        if settings.enabledProviders.count > 1 {
            reference += [("⌘1 / ⌘2 / ⌘3", "All / Claude / Codex filter"), ("⌘⇧N", "Choose provider for new sessions")]
        }
        reference += [("⌘R", "Refresh sessions"), ("Esc", "Close picker or cancel dialog"),
                      ("⌘,", "Settings"), ("⌘/", "Show / hide shortcuts"), ("⌘Q", "Quit CCS")]
        let title = NSTextField(labelWithString: "Keyboard shortcuts")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let cells = reference.map { key, action -> [NSView] in
            let keyLabel = NSTextField(labelWithString: key), label = NSTextField(labelWithString: action)
            keyLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            return [keyLabel, label]
        }
        let grid = NSGridView(views: cells); grid.columnSpacing = 14; grid.rowSpacing = 7
        grid.column(at: 0).xPlacement = .trailing
        let stack = NSStackView(views: [title, grid]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        let controller = NSViewController(); controller.view = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -14)])
        controller.view.setFrameSize(NSSize(width: stack.fittingSize.width + 32, height: stack.fittingSize.height + 28))
        let popover = NSPopover(); popover.contentViewController = controller
        popover.behavior = .transient; popover.animates = false; shortcutsPopover = popover
        popover.show(relativeTo: shortcuts.bounds, of: shortcuts, preferredEdge: .maxY)
    }
    @objc func settingsClicked() { onSettings?() }
    func activateSelected(fresh: Bool) {
        guard let s = selected else { return }
        if s.isLarge && !fresh {
            asking = true
            let alert = NSAlert(); alert.messageText = "Resume a large session?"
            alert.informativeText = "\(s.turns) prompts\(s.cost.map { " · $\(formattedCost($0)) recorded" } ?? ""). Resuming includes the saved conversation in future prompts. A clean session starts empty in \(shortPath(s.cwd))."
            alert.addButton(withTitle: "Resume"); alert.addButton(withTitle: "Start clean here"); alert.addButton(withTitle: "Cancel")
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            alert.beginSheetModal(for: panel) { [weak self] response in
                guard let self else { return }; self.asking = false
                if response == .alertFirstButtonReturn { self.activate(s, fresh: false) }
                else if response == .alertSecondButtonReturn { self.activate(s, fresh: true) }
                else { self.panel.makeFirstResponder(self.search) }
            }
        } else { activate(s, fresh: fresh) }
    }
    func activate(_ s: Session, fresh: Bool) {
        hide()
        engine.perform({ service, _ in try service.activate(s, fresh: fresh) }) { if case .failure(let error) = $0 { showError(error) } }
    }
    func newSession() {
        guard !asking, !launching else { return }; launching = true; hide()
        let preferences = settings
        let cli = AppInstallation.cli.path
        engine.perform({ service, env in try NewSessions(service: service, settings: preferences, environment: env).start(cliPath: cli) }) { [weak self] result in
            self?.launching = false
            if case .failure(let error) = result { showError(error) }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].session != nil }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].session == nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].session == nil ? 26 : 46 }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PickerRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if let s = rows[row].session { return SessionCell(session: s, recent: recent) }
        let label = NSTextField(labelWithString: rows[row].label); label.font = .systemFont(ofSize: 11, weight: .semibold); label.textColor = .secondaryLabelColor; label.lineBreakMode = .byTruncatingMiddle
        return label
    }
}
