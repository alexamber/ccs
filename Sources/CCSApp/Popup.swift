import AppKit
import CCSCore

final class Popup: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let panel: PickerPanel
    let engine: Engine
    let artifactBrowser: ArtifactBrowser
    private let drafts = VisibleDrafts()
    private let reportSearch: ReportSearch
    private var evidence = [String: [ReportReference]]()
    var settings: Settings
    var onSettings: (() -> Void)?
    var onSave: ((Settings) throws -> Void)?
    private let search = NSSearchField(), table = NSTableView(), scroll = NSScrollView()
    private let fileScope = NSButton(title: "Search files across sessions", target: nil, action: nil)
    private var searchingAllFolders = false
    private var reportOnlyKeys = Set<String>()
    private var explicitFolder = false
    private var artifactWidth: NSLayoutConstraint!
    private let views = NSSegmentedControl(labels: ["Recent", "Folders"], trackingMode: .selectOne, target: nil, action: nil)
    private let ranges = NSSegmentedControl(labels: ["1d", "3d", "7d", "30d", "All"], trackingMode: .selectOne, target: nil, action: nil)
    private let providers = NSSegmentedControl(labels: ProviderFilter.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let newProvider = NSPopUpButton()
    private let newProviderValue = NSTextField(labelWithString: "")
    private let keys = NSTextField(labelWithString: "⇧↵ New here   ⌃⇥ Recent / Folders   ⌘N New")
    private let shortcuts = NSButton(title: "Shortcuts", target: nil, action: nil)
    private var shortcutsPopover: NSPopover?
    private let count = NSTextField(labelWithString: ""), message = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "Loading sessions…")
    private var sessions = [Session](), rows = [SessionRow](), timer: Timer?, monitor: Any?
    private var generation = 0, loading = false, asking = false
    private var reloading = false
    private var wantsFileFocus = false
    private var hasLoaded = false
    private var finishedKeys = Set<String>()
    func updateFinished(_ keys: Set<String>) {
        let changed = finishedKeys.symmetricDifference(keys)
        finishedKeys = keys
        guard panel.isVisible, !changed.isEmpty else { return }
        let affected = IndexSet(rows.indices.filter { rows[$0].session.map { changed.contains($0.key) } == true })
        table.reloadData(forRowIndexes: affected, columnIndexes: IndexSet(integer: 0))
    }
    private var terminalTargets: [String: TerminalSwitchTarget]?
    private var terminalStatusCurrent = false
    private var terminalInventoryComplete = false
    private var refreshError: String?
    private let loadHistory: (@escaping (Result<HistorySnapshot, Error>) -> Void) -> Void
    private var launching = false, issues = [Provider: String]()
    private var installedProviders: [Provider]?
    private var previousApplication: NSRunningApplication?
    private var days: Int, recent: Bool
    init(engine: Engine, settings: Settings,
         loadHistory: ((@escaping (Result<HistorySnapshot, Error>) -> Void) -> Void)? = nil,
         artifactBrowser: ArtifactBrowser? = nil, reportLoader: ReportSearch.Loader? = nil) {
        self.engine = engine; self.settings = settings
        self.artifactBrowser = artifactBrowser ?? ArtifactBrowser()
        self.reportSearch = ReportSearch(load: reportLoader ?? engine.loadReportReferences)
        self.loadHistory = loadHistory ?? engine.loadHistory
        days = settings.defaultDays; recent = !settings.folders
        panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 560), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        drafts.onUpdate = { [weak self] in
            guard let self else { return }
            self.table.reloadData(forRowIndexes: IndexSet(self.rows.indices), columnIndexes: IndexSet(integer: 0))
        }
        reportSearch.onUpdate = { [weak self] in self?.reload() }
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
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -16)])
        search.placeholderString = "Search sessions and files"; search.font = .systemFont(ofSize: 17)
        search.delegate = self; search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Search sessions and artifact filenames")
        fileScope.target = self; fileScope.action = #selector(toggleFileScope)
        fileScope.controlSize = .small; fileScope.isHidden = true
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let searchRow = NSStackView(views: [search, fileScope]); searchRow.alignment = .centerY
        stack.addArrangedSubview(searchRow); searchRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let bar = NSStackView(); bar.spacing = 10
        views.toolTip = "Recent: newest sessions first. Folders: group sessions by project folder. Switch with Control-Tab."
        views.target = self; views.action = #selector(changeView); views.selectedSegment = recent ? 0 : 1
        ranges.target = self; ranges.action = #selector(changeRange); ranges.selectedSegment = dateWindows.firstIndex(of: days) ?? 2
        views.setAccessibilityLabel("Session grouping"); ranges.setAccessibilityLabel("Date range")
        providers.target = self; providers.action = #selector(changeProvider)
        providers.selectedSegment = ProviderFilter.allCases.firstIndex(of: settings.providerFilter) ?? 0
        providers.isHidden = settings.enabledProviders.count == 1
        providers.setAccessibilityLabel("Session provider"); providers.toolTip = "⌘1 All · ⌘2 Claude · ⌘3 Codex"
        count.font = .systemFont(ofSize: 11); count.textColor = .secondaryLabelColor
        bar.addArrangedSubview(views); bar.addArrangedSubview(providers); bar.addArrangedSubview(ranges)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal); bar.addArrangedSubview(spacer)
        for control in [views, providers, ranges] { control.controlSize = .small; control.font = .systemFont(ofSize: 11) }
        bar.spacing = 8
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session")))
        table.headerView = nil; table.backgroundColor = .clear; table.style = .fullWidth
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(clicked)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.setAccessibilityLabel("Claude Code and Codex sessions")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let sectionTitle = NSTextField(labelWithString: "Sessions")
        sectionTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        let headingSpace = NSView(); headingSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let sectionHeading = NSStackView(views: [sectionTitle, count, headingSpace]); sectionHeading.spacing = 8
        sectionTitle.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentHuggingPriority(.required, for: .horizontal)
        let header = NSView()
        for view in [sectionHeading, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(view)
            view.leadingAnchor.constraint(equalTo: header.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: header.trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([header.heightAnchor.constraint(equalToConstant: 44),
            sectionHeading.topAnchor.constraint(equalTo: header.topAnchor), bar.bottomAnchor.constraint(equalTo: header.bottomAnchor)])
        let left = NSStackView(views: [header, scroll]); left.orientation = .vertical; left.alignment = .leading; left.spacing = 8
        header.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        let divider = NSBox(); divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        let body = NSStackView(views: [left, divider, self.artifactBrowser]); body.orientation = .horizontal; body.alignment = .top; body.spacing = 16
        stack.addArrangedSubview(body); body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        body.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        left.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        divider.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
        artifactWidth = self.artifactBrowser.widthAnchor.constraint(equalToConstant: 320)
        artifactWidth.isActive = true
        self.artifactBrowser.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        self.artifactBrowser.onBack = { [weak self] in guard let self else { return }; self.panel.makeFirstResponder(self.table) }
        self.artifactBrowser.onOpened = { [weak self] in self?.hide(restoreFocus: false) }
        self.artifactBrowser.onLoaded = { [weak self] _ in
            guard let self, self.wantsFileFocus else { return }
            self.wantsFileFocus = false; _ = self.artifactBrowser.focusFiles()
        }
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
        let footerSpace = NSView(); footerSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(footerSpace); footer.addArrangedSubview(shortcuts)
        let gear = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!, target: self, action: #selector(settingsClicked)); gear.isBordered = false; gear.toolTip = "Settings (⌘,)"
        footer.addArrangedSubview(gear)
        let footerDivider = NSBox(); footerDivider.boxType = .separator
        stack.addArrangedSubview(footerDivider); footerDivider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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
        if sourcesChanged { generation += 1; terminalTargets = nil; terminalStatusCurrent = false }
        if self.settings.defaultDays != settings.defaultDays { days = settings.defaultDays }
        if self.settings.folders != settings.folders { recent = !settings.folders }
        self.settings = settings
        search.placeholderString = "Search sessions and files"
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
        if panel.isVisible { reload() }
        if sourcesChanged { refresh() }
    }
    func show(repeatedHotkey: Bool = false) {
        guard !launching else { return }
        if panel.isVisible {
            if repeatedHotkey { newSession() } else { panel.makeKeyAndOrderFront(nil) }
            return
        }
        // Keep the last snapshot searchable while fresh metadata is collected.
        // Cached conversation metadata does not establish that its tab is still open.
        terminalStatusCurrent = false
        searchingAllFolders = false; search.stringValue = ""; reload()
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        panel.setContentSize(NSSize(width: min(1000, f.width - 32), height: min(560, f.height - 50)))
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2,
                                     y: max(f.minY + 16, f.maxY - f.height * 0.18 - size.height)))
        let front = NSWorkspace.shared.frontmostApplication
        previousApplication = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(search)
        updateArtifacts(refresh: true)
        refresh()
        timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func hide(restoreFocus: Bool = true) {
        guard panel.isVisible, !asking else { return }
        let wasActive = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        shortcutsPopover?.close()
        panel.orderOut(nil); timer?.invalidate(); timer = nil
        artifactBrowser.cancel(); reportSearch.stop(); drafts.clear()
        if restoreFocus && wasActive {
            if let previousApplication { previousApplication.activate(options: []) }
            else { NSApp.hide(nil) }
        }
        previousApplication = nil
        wantsFileFocus = false
    }
    func showFiles(for session: Session) {
        if !sessions.contains(where: { $0.key == session.key }) { sessions.append(session) }
        if !settings.providerFilter.includes(session.provider) {
            settings.providerFilter = ProviderFilter(rawValue: session.provider.rawValue) ?? .all
            providers.selectedSegment = ProviderFilter.allCases.firstIndex(of: settings.providerFilter) ?? 0
        }
        show(); search.stringValue = ""; reload()
        if let row = rows.firstIndex(where: { $0.session?.key == session.key }) { select(row) }
        wantsFileFocus = true
        artifactBrowser.show(folder: session.cwd, refresh: true)
    }
    func owns(_ window: NSWindow) -> Bool {
        window === panel || window === shortcutsPopover?.contentViewController?.view.window
    }
    func windowDidResignKey(_ notification: Notification) {
        if shortcutsPopover?.isShown != true { hide(restoreFocus: false) }
    }
    func refresh() {
        guard !loading else { return }; loading = true
        refreshError = nil
        if panel.isVisible { reload() }
        let request = generation
        loadHistory { [weak self] result in
            guard let self else { return }; self.loading = false
            guard request == self.generation else {
                self.refresh(); return
            }
            switch result {
            case .success(let payload):
                self.sessions = payload.sessions; self.issues = payload.issues
                self.terminalTargets = payload.terminalTargets
                self.terminalStatusCurrent = payload.terminalTargets != nil
                self.terminalInventoryComplete = payload.terminalInventoryComplete
                self.installedProviders = payload.installedProviders; self.hasLoaded = true
            case .failure(let error): self.refreshError = error.localizedDescription; self.terminalTargets = nil; self.terminalStatusCurrent = false
            }
            if self.panel.isVisible { self.drafts.check(self.terminalTargets.map { Array($0.values) } ?? []) }
            // Finishing while hidden still warms the next opening.
            self.reload()
            if self.panel.isVisible { self.updateArtifacts(refresh: true) }
        }
    }
    func reload() {
        reloading = true
        defer { reloading = false; if panel.isVisible { updateArtifacts() } }
        let keep = selected?.key
        let cutoff = days == 0 ? 0 : Date().timeIntervalSince1970 - Double(days) * 86400
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = sessions.filter { settings.enabledProviders.contains($0.provider) && settings.providerFilter.includes($0.provider) }
        rows = sessionRows(scoped.filter { (terminalStatusCurrent && terminalTargets?[$0.key] != nil) || $0.mtime >= cutoff },
                           query: search.stringValue, recent: recent, tree: false)
        evidence.removeAll(keepingCapacity: true); reportOnlyKeys.removeAll(keepingCapacity: true)
        if panel.isVisible, !query.isEmpty {
            reportSearch.search(scoped)
            let ordinary = Set(rows.compactMap { $0.session?.key })
            var related = [(session: Session, action: ReportReference.Action)]()
            for session in scoped {
                let hits = reportSearch.matches(query, for: session)
                guard let best = hits.first else { continue }
                evidence[session.key] = hits
                if !ordinary.contains(session.key) { related.append((session, best.action)) }
            }
            if !related.isEmpty {
                reportOnlyKeys = Set(related.map { $0.session.key })
                rows.append(SessionRow(label: "Sessions referencing matching files · all dates"))
                related.sort {
                    $0.action == $1.action ? $0.session.mtime > $1.session.mtime : $0.action.rawValue < $1.action.rawValue
                }
                rows += related.map { SessionRow(session: $0.session) }
            }
        } else { reportSearch.stop() }
        let sessionCount = rows.filter { $0.session != nil }.count
        table.reloadData(); count.stringValue = "\(sessionCount) \(sessionCount == 1 ? "session" : "sessions")"
        empty.isHidden = rows.contains { $0.session != nil }; empty.stringValue = search.stringValue.isEmpty ? "No sessions in this range" : "No sessions match"
        if sessions.isEmpty, let installedProviders, installedProviders.isEmpty {
            empty.stringValue = "Install " + settings.enabledProviders.map { $0 == .claude ? "Claude Code" : "Codex" }.joined(separator: " or ") + " to get started"
        }
        if !hasLoaded { empty.stringValue = refreshError == nil ? "Loading sessions…" : "Couldn’t load sessions. Press ⌘R to retry." }
        let warnings = issues.filter { settings.enabledProviders.contains($0.key) && settings.providerFilter.includes($0.key) }.sorted { $0.key.rawValue < $1.key.rawValue }.map(\.value)
        message.stringValue = warnings.isEmpty ? "Refreshes every 5 seconds · \(settings.hotkeyLabel) again starts a new \(settings.newProvider.title) session" : warnings.joined(separator: " · ")
        if let refreshError { message.stringValue = (hasLoaded ? "Showing previous results · " : "") + refreshError }
        else if loading, hasLoaded { message.stringValue = "Updating sessions… · " + message.stringValue }
        if reportSearch.searching { message.stringValue = "Searching session file references… · " + message.stringValue }
        else if reportSearch.failed > 0 { message.stringValue = "File references unavailable for \(reportSearch.failed) sessions · " + message.stringValue }
        if hasLoaded, !query.isEmpty, sessionCount == 0 {
            empty.stringValue = reportSearch.searching ? "Searching session file references…" : "No matching session reference found"
        }
        message.toolTip = message.stringValue
        if let keep, let row = rows.firstIndex(where: { $0.session?.key == keep }) { select(row) }
        else if let row = rows.firstIndex(where: { $0.session != nil }) { select(row) }
    }
    private func updateArtifacts(refresh: Bool = false) {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        fileScope.isHidden = query.isEmpty || selected == nil
        let globalSearch = !query.isEmpty && (selected == nil || searchingAllFolders || (selected.map { reportOnlyKeys.contains($0.key) } == true && !explicitFolder))
        fileScope.title = globalSearch ? "Show session files" : "Search files across sessions"
        artifactWidth.constant = min(globalSearch ? 420 : 320, max(240, panel.frame.width - 503))
        if !globalSearch { artifactBrowser.show(folder: selected?.cwd, refresh: refresh) }
        else {
            // Date filters apply to conversation history. Global file search
            // includes all known folders for the selected providers.
            let folders = sessions.filter { settings.enabledProviders.contains($0.provider) && settings.providerFilter.includes($0.provider) }
                .sorted { $0.mtime > $1.mtime }.map(\.cwd)
            artifactBrowser.showSearch(query: query, folders: folders)
        }
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
        case 36, 76:
            if selected == nil, artifactBrowser.isGlobalSearch, !event.modifierFlags.contains(.shift) { artifactBrowser.openSelected() }
            else { activateSelected(fresh: event.modifierFlags.contains(.shift)) }
        case 125:
            if selected == nil, artifactBrowser.isGlobalSearch { return artifactBrowser.focusFiles() }
            move(1)
        case 126: move(-1)
        case 124 where !command && !control && !event.modifierFlags.contains(.option) && navigatingSessions:
            return artifactBrowser.focusFiles()
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
        case 15 where command: reportSearch.stop(); artifactBrowser.invalidateSearch(); refresh()
        case 3 where command: panel.makeFirstResponder(search); search.selectText(nil)
        case 43 where command: settingsClicked()
        case 44 where command: showShortcuts()
        default: return false
        }
        return true
    }
    @objc func toggleFileScope() {
        searchingAllFolders = !artifactBrowser.isGlobalSearch
        explicitFolder = !searchingAllFolders
        updateArtifacts()
        panel.makeFirstResponder(search)
    }
    func controlTextDidChange(_ obj: Notification) { searchingAllFolders = false; explicitFolder = false; reload() }
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
            ("⌥⇥ / ⌥⇧⇥", "Cycle active Terminal sessions; release Option to switch"),
            ("⌘F", "Return to search"),
            ("↑ / ↓", "Select session; Down enters files when only files match"),
            ("Page Up / Down", "Move ten sessions"),
            ("Home / End", "First / last session"),
            ("↵", "Open selected session"),
            ("→ / ←", "Move between sessions and files"),
            ("⇧↵", "Start clean in the selected folder"),
            ("⌃⇥", "Switch Recent / Folders"),
            ("⇥ / ⇧⇥", "Move keyboard focus"),
            ("⌘← / ⌘→", "Change date range"),
            ("⌘N", "New dated session · " + settings.newProvider.title)
        ]
        if settings.enabledProviders.count > 1 {
            reference += [("⌘1 / ⌘2 / ⌘3", "All / Claude / Codex filter"), ("⌘⇧N", "Choose provider for new sessions")]
        }
        reference += [("⌘R", "Refresh sessions"), ("⎋", "Close picker or cancel dialog"),
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
        confirmActivation(s, fresh: fresh, inPicker: true) { [weak self] fresh in self?.activate(s, fresh: fresh) }
    }
    func resumeFromReport(_ session: Session) {
        confirmActivation(session, fresh: false, inPicker: false) { [weak self] fresh in
            self?.engine.perform({ service, _ in try service.activate(session, fresh: fresh) }) {
                if case .failure(let error) = $0 { showError(error) }
            }
        }
    }
    private func confirmActivation(_ s: Session, fresh: Bool, inPicker: Bool, activate: @escaping (Bool) -> Void) {
        if s.isLarge && !fresh {
            asking = true
            let alert = NSAlert(); alert.messageText = "Resume a large session?"
            alert.informativeText = "\(s.turns) prompts\(s.cost.map { " · $\(formattedCost($0)) recorded" } ?? ""). Resuming includes the saved conversation in future prompts. A clean session starts empty in \(shortPath(s.cwd))."
            alert.addButton(withTitle: "Resume"); alert.addButton(withTitle: "Start clean here"); alert.addButton(withTitle: "Cancel")
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self else { return }; self.asking = false
                if response == .alertFirstButtonReturn { activate(false) }
                else if response == .alertSecondButtonReturn { activate(true) }
                else if inPicker { self.panel.makeFirstResponder(self.search) }
            }
            if inPicker { alert.beginSheetModal(for: panel, completionHandler: respond) }
            else { NSApp.activate(ignoringOtherApps: true); respond(alert.runModal()) }
        } else { activate(fresh) }
    }
    func activate(_ s: Session, fresh: Bool) {
        let target = terminalTargets?[s.key], candidates = sessions
        hide(restoreFocus: fresh || target == nil)
        engine.perform({ service, _ in
            if !fresh, let target { try service.activate(s, target: target, sessions: candidates) }
            else { try service.activate(s, fresh: fresh) }
        }) { if case .failure(let error) = $0 { showError(error) } }
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
    func tableViewSelectionDidChange(_ notification: Notification) {
        if !reloading, panel.isVisible { searchingAllFolders = false; explicitFolder = false; updateArtifacts() }
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].session != nil }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].session == nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].session == nil ? 26 : 48 }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PickerRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if let s = rows[row].session {
            let matched = terminalTargets?[s.key] != nil
            let known = terminalStatusCurrent && (matched || terminalInventoryComplete)
            return SessionCell(session: s, recent: recent, terminalOpen: known ? matched : nil, unattended: finishedKeys.contains(s.key), references: evidence[s.key] ?? [], possibleDraft: known && matched && drafts.keys.contains(s.key))
        }
        let label = NSTextField(labelWithString: rows[row].label); label.font = .systemFont(ofSize: 11, weight: .semibold); label.textColor = .secondaryLabelColor; label.lineBreakMode = .byTruncatingMiddle
        return label
    }
}
