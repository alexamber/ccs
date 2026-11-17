import AppKit
import Carbon
import CCSCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = Engine(), hotkey = HotKey()
    private let nextSessionKey = HotKey(id: 2), previousSessionKey = HotKey(id: 3)
    private let sessionSwitcher = SessionSwitcher()
    private var switchUpdated = Date.distantPast
    private var switchTargets = [TerminalSwitchTarget](), switchHistory = [String]()
    var settings = Settings.load()
    var popup: Popup!, preferences: Preferences!, status: NSStatusItem!
    var showObserver: NSObjectProtocol?
    var settingsObserver: NSObjectProtocol?
    var dismissal: TransientUIDismissal?
    private let terminalPopup = TerminalSessionPopup()
    private var terminalMonitor: TerminalSessionMonitor?
    var cliMenuItem: NSMenuItem?
    var newMenuItem: NSMenuItem?
    private let statusMenu = NSMenu()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        popup = Popup(engine: engine, settings: settings)
        terminalPopup.onBrowseFiles = { [weak self] session in self?.popup.showFiles(for: session) }
        popup.onSettings = { [weak self] in self?.showSettings() }
        preferences = Preferences(settings: settings, engine: engine)
        preferences.onSave = { [weak self] value in try self?.updateSettings(value) }
        let terminalQueue = DispatchQueue(label: "io.github.alexamber.ccs.terminal", qos: .utility)
        terminalMonitor = TerminalSessionMonitor(readTab: { completion in
            terminalQueue.async {
                let tab = TerminalTabSnapshot.read()
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
        popup.onSave = { [weak self] value in try self?.updateSettings(value) }
        hotkey.onPress = { [weak self] in
            guard let self, !self.preferences.finishRecordingCurrentShortcut() else { return }
            self.popup.show(repeatedHotkey: true)
        }
        nextSessionKey.onPress = { [weak self] in self?.switchSession(step: 1) }
        previousSessionKey.onPress = { [weak self] in self?.switchSession(step: -1) }
        sessionSwitcher.onCommit = { [weak self] target, sessions in
            guard let self else { return }
            self.engine.perform({ service, _ in try service.focusTerminalTarget(target, sessions: sessions) }) { [weak self] result in
                switch result {
                case .success:
                    self?.rememberSwitch(target.session.key)
                case .failure(let error):
                    self?.switchUpdated = .distantPast
                    showError(error)
                }
            }
        }
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
        } catch {
            if shortcutChanged { try? hotkey.register(code: old.hotkeyCode, modifiers: old.hotkeyModifiers) }
            throw error
        }
    }
    private func rememberSwitch(_ key: String) {
        switchHistory.removeAll { $0 == key }; switchHistory.insert(key, at: 0)
        switchHistory = Array(switchHistory.prefix(100))
    }
    private func orderedTargets(_ targets: [TerminalSwitchTarget]) -> [TerminalSwitchTarget] {
        targets.sorted {
            let a = switchHistory.firstIndex(of: $0.session.key) ?? Int.max
            let b = switchHistory.firstIndex(of: $1.session.key) ?? Int.max
            return a == b ? $0.session.mtime > $1.session.mtime : a < b
        }
    }
    private func switchSession(step: Int) {
        guard !preferences.finishRecordingCurrentShortcut() else { return }
        if sessionSwitcher.panel.isVisible { sessionSwitcher.cycle(step); return }
        let sourceWasTerminal = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal"
        let cached = Date().timeIntervalSince(switchUpdated) < 30 ? orderedTargets(switchTargets) : []
        popup.hide(restoreFocus: false); terminalPopup.hide()
        let presentation = sessionSwitcher.show(targets: cached, step: step)
        let enabled = settings.enabledProviders
        engine.perform(background: true, { service, _ in
            // A session started since the picker last opened must be switchable.
            let sessions = try service.collect(days: 0, provider: .all, enabledProviders: enabled)
            return try service.terminalSwitchContext(sessions: sessions.filter { enabled.contains($0.provider) })
        }) { [weak self] result in
            guard let self, self.sessionSwitcher.presentation == presentation else { return }
            do {
                let context = try result.get()
                let current = sourceWasTerminal ? context.currentKey : nil
                if let current { self.rememberSwitch(current) }
                self.switchTargets = self.orderedTargets(context.targets)
                self.switchUpdated = Date()
                self.sessionSwitcher.supply(self.switchTargets, currentKey: current, presentation: presentation)
            } catch { self.sessionSwitcher.showFailure("Couldn’t refresh sessions. Press Esc and try again.", presentation: presentation) }
        }
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
