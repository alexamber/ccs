import AppKit
import Carbon
import CCSCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let terminals = TerminalRegistry.system()
    let engine = Engine(), hotkey = HotKey()
    private let nextSessionKey = HotKey(id: 2), previousSessionKey = HotKey(id: 3)
    var settings = Settings.load()
    var popup: Popup!, preferences: Preferences!, status: NSStatusItem!
    var showObserver: NSObjectProtocol?
    var settingsObserver: NSObjectProtocol?
    var dismissal: TransientUIDismissal?
    private let terminalPopup = TerminalSessionPopup()
    private let sessionOverview = SessionOverview()
    private lazy var activity = SessionActivityCoordinator(load: { [weak self] providers, done in
        self?.engine.loadTerminalActivity(enabledProviders: providers, completion: done)
    }, remember: { [weak self] in self?.engine.rememberActivity($0) })
    private let codexEvents = CodexActivityListener()
    private var claudeEvents: NSObjectProtocol?
    private var eventConfiguration = 0
    private var eventSettings: String?
    private var lastClaudeEvent = [String: Double]()
    private var terminalMonitor: TerminalSessionMonitor?
    var cliMenuItem: NSMenuItem?
    var newMenuItem: NSMenuItem?
    private let statusMenu = NSMenu()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        popup = Popup(engine: engine, settings: settings)
        terminalPopup.onBrowseFiles = { [weak self] session in self?.popup.showFiles(for: session) }
        terminalPopup.onShowSessions = { [weak self] anchor in self?.showSessionOverview(anchor: anchor) }
        terminalPopup.onDragStart = { [weak self] in self?.sessionOverview.close() }
        terminalPopup.onNotificationOpen = { [weak self] target in
            guard let self else { return }
            self.focus(target, sessions: self.activity.targets.compactMap(\.session))
        }
        terminalPopup.onNotificationHover = { [weak self] value in self?.activity.hovered = value }
        activity.canPresent = { [weak self] in self?.terminalPopup.canShowNotification == true }
        activity.onShow = { [weak self] update in
            guard let self else { return }
            self.terminalPopup.notify(update, bubble: self.settings.notificationBubble, wiggle: self.settings.notificationWiggle, sound: self.settings.notificationSound)
        }
        activity.onHide = { [weak self] in self?.terminalPopup.speech.hide() }
        activity.onUnreadChange = { [weak self] in self?.terminalPopup.setUpdateCount($0) }
        activity.onSnapshot = { [weak self] snapshot, finished in
            guard let self else { return }
            self.popup.updateFinished(finished)
            guard self.sessionOverview.isShown else { return }
            self.sessionOverview.supply(snapshot, finished: finished, generation: self.sessionOverview.generation)
        }
        claudeEvents = DistributedNotificationCenter.default().addObserver(forName: ClaudeActivityHook.notification, object: nil, queue: .main) { [weak self] note in
            self?.receiveClaudeEvent(note.userInfo)
        }
        sessionOverview.onSelect = { [weak self] target, sessions in self?.focus(target, sessions: sessions) }
        sessionOverview.onBrowse = { [weak self] in self?.popup.show() }
        sessionOverview.onClose = { [weak self] in self?.terminalPopup.sessionOverviewClosed() }
        sessionOverview.onRefresh = { [weak self] in
            guard let self else { return }; self.refreshSessionOverview(generation: self.sessionOverview.generation)
        }
        popup.onSettings = { [weak self] in self?.showSettings() }
        preferences = Preferences(settings: settings, engine: engine, terminals: terminals)
        preferences.onSave = { [weak self] value in try self?.updateSettings(value) }
        let terminalQueue = DispatchQueue(label: "io.github.alexamber.ccs.terminal", qos: .utility)
        terminalMonitor = TerminalSessionMonitor(frontmost: { [terminals] in
            terminals.supported(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) != nil
        }, isCurrentTerminal: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == $0 }, readTab: { [terminals] completion in
            let adapter = terminals.supported(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            terminalQueue.async {
                let tab = adapter?.frontTab()
                DispatchQueue.main.async { completion(tab) }
            }
        }, loadSession: { [weak self] tab, completion in
            guard let self else { completion(nil); return }
            self.engine.perform(background: true, { service, env in
                let enabled = Settings.load().resolvingProviders(environment: env).enabledProviders
                return try service.session(inTerminalTab: tab, enabledProviders: enabled)
            }) { result in completion(try? result.get()) }
        }, show: { [weak self] session, tab in
            self?.terminalPopup.show(session, tab: tab)
        },
           hide: { [weak self] reason in self?.terminalPopup.contextEnded(reason) })
        terminalMonitor?.onFocus = { [weak self] key in self?.activity.observe(key) }
        popup.onSave = { [weak self] value in try self?.updateSettings(value) }
        hotkey.onPress = { [weak self] in
            guard let self, !self.preferences.finishRecordingCurrentShortcut() else { return }
            self.popup.show(repeatedHotkey: true)
        }
        nextSessionKey.onPress = { [weak self] in self?.switchSession(step: 1) }
        previousSessionKey.onPress = { [weak self] in self?.switchSession(step: -1) }
        let appMenu = NSMenu()
        appMenu.addItem(item("About CCS", #selector(about)))
        appMenu.addItem(item("Settings…", #selector(showSettings), key: ","))
        appMenu.addItem(.separator()); appMenu.addItem(item("Quit CCS", #selector(quit), key: "q"))
        let main = NSMenu(), root = NSMenuItem(); root.submenu = appMenu; main.addItem(root)
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editRoot.submenu = edit; main.addItem(editRoot)
        NSApp.mainMenu = main
        let menu = statusMenu
        menu.delegate = self
        menu.addItem(item("Show Sessions", #selector(showPopup)))
        newMenuItem = item("New Dated Session", #selector(newSession)); menu.addItem(newMenuItem!)
        menu.addItem(.separator()); menu.addItem(item("Settings…", #selector(showSettings)))
        cliMenuItem = item("Command-Line Tool…", #selector(installCLI)); menu.addItem(cliMenuItem!)
        menu.addItem(item("About CCS", #selector(about)))
        if Product.donationURL != nil { menu.addItem(item("Buy me a coffee", #selector(tip))) }
        menu.addItem(.separator()); menu.addItem(item("Quit CCS", #selector(quit), key: "q"))
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = BrandIcon.image(template: true, size: min(27, NSStatusBar.system.thickness - 4))
        status.button?.image?.isTemplate = true; status.button?.toolTip = "CCS · Claude Code and Codex sessions"
        status.button?.target = self; status.button?.action = #selector(showStatusMenu)
        dismissal = TransientUIDismissal(popup: popup, menu: menu)
        showObserver = DistributedNotificationCenter.default().addObserver(forName: Product.showNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            if let raw = note.userInfo?["provider"] as? String, let filter = ProviderFilter(rawValue: raw) { self.popup.selectFilter(filter) }
            self.popup.show()
        }
        settingsObserver = DistributedNotificationCenter.default().addObserver(forName: Product.settingsNotification, object: nil, queue: .main) { [weak self] _ in
            do { try self?.updateSettings(Settings.load(), save: false) } catch { showError(error) }
        }
        do { try hotkey.register(code: settings.hotkeyCode, modifiers: settings.hotkeyModifiers) }
        catch { showError(error); showSettings() }
        do {
            try nextSessionKey.register(code: 48, modifiers: UInt32(optionKey))
            try previousSessionKey.register(code: 48, modifiers: UInt32(optionKey | shiftKey))
        } catch {
            nextSessionKey.unregister(); previousSessionKey.unregister()
            showError(CCSError.message("Option-Tab session switching is unavailable because another shortcut is using it."))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--provider"), index + 1 < CommandLine.arguments.count,
           let filter = ProviderFilter(rawValue: CommandLine.arguments[index + 1]) { popup.selectFilter(filter) }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let login = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        engine.perform({ _, env in Settings.load().resolvingProviders(environment: env) }) { [weak self] result in
            guard let self else { return }
            do {
                let value = try result.get()
                try self.updateSettings(value, save: !value.needsProviderSetup)
                self.popup.refresh()
                if !login { self.popup.show() }
            } catch { showError(error) }
        }
    }
    private func updateSettings(_ value: Settings, save: Bool = true) throws {
        let old = settings
        let shortcutChanged = old.hotkeyCode != value.hotkeyCode || old.hotkeyModifiers != value.hotkeyModifiers
        if shortcutChanged, value.hotkeyCode == 48, [UInt32(optionKey), UInt32(optionKey | shiftKey)].contains(value.hotkeyModifiers) {
            throw CCSError.message("Option-Tab and Option-Shift-Tab are reserved for switching active sessions. Choose another picker shortcut.")
        }
        do {
            if shortcutChanged { try hotkey.register(code: value.hotkeyCode, modifiers: value.hotkeyModifiers) }
            if save { try value.save() }
            settings = value; popup.apply(value); preferences.apply(value)
            terminalMonitor?.configure(enabled: value.terminalPopups)
            terminalPopup.configureFloating(enabled: value.terminalPopups, allSpaces: value.unicornAllSpaces, size: value.unicornSize)
            let reset = old.enabledProviders != value.enabledProviders || old.terminalPopups != value.terminalPopups
            if reset { sessionOverview.close(); popup.updateFinished([]) }
            activity.configure(value)
            configureActivityEvents()
        } catch {
            if shortcutChanged { try? hotkey.register(code: old.hotkeyCode, modifiers: old.hotkeyModifiers) }
            throw error
        }
    }
    private func configureActivityEvents() {
        let enabled = settings.terminalPopups
        let signature = "\(enabled):" + settings.enabledProviders.map(\.rawValue).joined(separator: ",")
        guard signature != eventSettings else { return }
        eventSettings = signature; eventConfiguration += 1
        let revision = eventConfiguration, providers = settings.enabledProviders
        codexEvents.stop()
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ccs").path
        engine.perform({ _, environment in
            try ClaudeActivityHook.configure(enabled: enabled && providers.contains(.claude), cli: cli, environment: environment)
            return environment
        }) { [weak self] result in
            guard let self, revision == self.eventConfiguration else { return }
            switch result {
            case .success(let environment):
                if enabled && providers.contains(.codex) {
                    self.codexEvents.start(environment: environment) { [weak self] session in self?.receiveEvent(session) }
                }
            case .failure(let error):
                self.eventSettings = nil
                showError(CCSError.message("Claude notification setup failed: \(error.localizedDescription) Status polling remains available."))
                // A Claude configuration problem must not disable Codex events.
                if enabled && providers.contains(.codex) {
                    self.engine.perform({ _, environment in environment }) { [weak self] value in
                        guard let self, revision == self.eventConfiguration, let environment = try? value.get() else { return }
                        self.codexEvents.start(environment: environment) { [weak self] session in self?.receiveEvent(session) }
                    }
                }
            }
        }
    }
    private func receiveEvent(_ session: Session) { activity.ingest(session) }
    private func receiveClaudeEvent(_ payload: [AnyHashable: Any]?) {
        guard settings.enabledProviders.contains(.claude),
              let id = payload?["id"] as? String, !id.isEmpty, id.count < 200,
              let status = payload?["status"] as? String, ["active", "idle", "error", "waiting_for_approval", "waiting_input"].contains(status),
              let stamp = payload?["time"] as? String, let time = Double(stamp), time.isFinite,
              abs(Date().timeIntervalSince1970 - time) < 60, time > (lastClaudeEvent[id] ?? 0),
              let eventID = payload?["eventID"] as? String, UUID(uuidString: eventID) != nil else { return }
        lastClaudeEvent[id] = time
        lastClaudeEvent = lastClaudeEvent.filter { Date().timeIntervalSince1970 - $0.value < 3600 }
        var session = activity.targets.compactMap(\.session).first { $0.provider == .claude && $0.id == id }
            ?? Session(id: id, cwd: payload?["cwd"] as? String ?? "", provider: .claude)
        session.status = status; session.mtime = time; session.activityTurn = nil
        if status == "idle" { session.activityTurn = SessionActivityTurn(id: eventID, status: "completed") }
        receiveEvent(session)
    }
    private func focus(_ target: TerminalSwitchTarget, sessions: [Session]) {
        sessionOverview.close()
        engine.perform({ service, _ in try service.focusTerminalTarget(target, sessions: sessions) }) { result in
            if case .failure(let error) = result { showError(error) }
        }
    }
    private func showSessionOverview(anchor: NSView) {
        if sessionOverview.isShown { sessionOverview.close(); return }
        let generation = openSessionOverview(anchor: anchor)
        refreshSessionOverview(generation: generation)
    }
    private func openSessionOverview(anchor: NSView) -> Int {
        popup.hide(restoreFocus: false)
        return sessionOverview.show(anchor: anchor, cached: activity.recentSnapshot, finished: activity.finished)
    }
    private func refreshSessionOverview(generation: Int) {
        activity.refresh { [weak self] result in
            guard let self, self.sessionOverview.generation == generation, self.sessionOverview.isShown else { return }
            switch result {
            case .success(let snapshot):
                self.sessionOverview.supply(snapshot, finished: self.activity.finished, generation: generation)
            case .failure(let error): self.sessionOverview.fail(error, generation: generation)
            }
        }
    }
    private func switchSession(step: Int) {
        guard !preferences.finishRecordingCurrentShortcut() else { return }
        if sessionOverview.isSwitching { sessionOverview.cycle(step); return }
        if sessionOverview.isShown {
            sessionOverview.beginSwitch(step: step, fromSelection: true)
            return
        }
        let previous = NSWorkspace.shared.frontmostApplication
        let origin = terminals.supported(bundleID: previous?.bundleIdentifier)
        let anchor = terminalPopup.panel.isVisible && terminalPopup.panel.isOnActiveSpace
            ? terminalPopup.prepareSessionMenu() : status.button
        guard let anchor else { return }
        let generation = openSessionOverview(anchor: anchor)
        sessionOverview.beginSwitch(step: step, previous: previous)
        if let origin {
            engine.loadSwitchOrigin(terminalID: origin.bundleID) { [weak self] result in
                guard let menu = self?.sessionOverview, menu.isSwitching, menu.generation == generation else { return }
                switch result {
                case .success(let tty): menu.supplyOrigin(tty: tty, generation: generation)
                case .failure(let error): menu.endSwitch(); menu.fail(error, generation: generation)
                }
            }
        } else {
            sessionOverview.supplyOrigin(tty: nil, generation: generation)
        }
        refreshSessionOverview(generation: generation)
    }
    func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; return item
    }
    @objc func showPopup() { popup.show() }
    @objc private func showStatusMenu() {
        guard let button = status.button else { return }
        popup.hide(restoreFocus: false)
        // A menu opened by an inactive LSUIElement can keep tracking after an
        // outside click. Activate first, then begin native tracking next cycle.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self, weak button] in
            guard let self, let button else { return }
            self.statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 2), in: button)
        }
    }
    @objc func newSession() { popup.newSession() }
    @objc func showSettings() { popup.hide(restoreFocus: false); preferences.show() }
    @objc func installCLI() { showSettings(); if !preferences.isCLIInstalled { preferences.installCLI() } }
    func menuWillOpen(_ menu: NSMenu) {
        dismissal?.menuWillOpen()
        preferences.refreshInstallation()
        cliMenuItem?.title = preferences.isCLIInstalled ? "Command-Line Tool…" : "Install Command-Line Tool…"
        newMenuItem?.title = "New \(settings.newProvider.title) Session in Dated Folder"
    }
    func menuDidClose(_ menu: NSMenu) { dismissal?.menuDidClose() }
    func applicationWillTerminate(_ notification: Notification) {
        codexEvents.stop(); activity.stop()
        if let claudeEvents { DistributedNotificationCenter.default().removeObserver(claudeEvents) }
        dismissal?.stop()
        if let showObserver { DistributedNotificationCenter.default().removeObserver(showObserver) }
        if let settingsObserver { DistributedNotificationCenter.default().removeObserver(settingsObserver) }
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func tip() { if let url = Product.donationURL { NSWorkspace.shared.open(url) } }
    @objc func about() {
        popup.hide()
        let alert = NSAlert(); alert.messageText = "CCS \(Product.version)"
        alert.informativeText = "A quick way back to your Claude Code and Codex sessions.\n\nNative macOS popup and terminal picker. Session data stays on your Mac.\n\nMIT licensed · github.com/alexamber/ccs"
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Project Website")
        if Product.donationURL != nil { alert.addButton(withTitle: "Buy me a coffee") }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertSecondButtonReturn { NSWorkspace.shared.open(Product.website) }
        if response == .alertThirdButtonReturn { tip() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { popup.show(); return true }
}
