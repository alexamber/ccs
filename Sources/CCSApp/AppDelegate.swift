import AppKit
import Carbon
import CCSCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = Engine(), hotkey = HotKey()
    var settings = Settings.load()
    var popup: Popup!, preferences: Preferences!, status: NSStatusItem!
    var showObserver: NSObjectProtocol?
    var settingsObserver: NSObjectProtocol?
    var dismissal: TransientUIDismissal?
    var cliMenuItem: NSMenuItem?
    var newMenuItem: NSMenuItem?
    private let statusMenu = NSMenu()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        popup = Popup(engine: engine, settings: settings)
        popup.onSettings = { [weak self] in self?.showSettings() }
        preferences = Preferences(settings: settings, engine: engine)
        preferences.onSave = { [weak self] value in try self?.updateSettings(value) }
        popup.onSave = { [weak self] value in try self?.updateSettings(value) }
        hotkey.onPress = { [weak self] in
            guard let self, !self.preferences.finishRecordingCurrentShortcut() else { return }
            self.popup.show(repeatedHotkey: true)
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
        status.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "CCS sessions")
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
        if let index = CommandLine.arguments.firstIndex(of: "--provider"), index + 1 < CommandLine.arguments.count,
           let filter = ProviderFilter(rawValue: CommandLine.arguments[index + 1]) { popup.selectFilter(filter) }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let login = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        engine.perform({ _, env in Settings.load().resolvingProviders(environment: env) }) { [weak self] result in
            guard let self else { return }
            do {
                let value = try result.get()
                try self.updateSettings(value, save: !value.needsProviderSetup)
                if !login { self.popup.show() }
            } catch { showError(error) }
        }
    }
    private func updateSettings(_ value: Settings, save: Bool = true) throws {
        let old = settings
        let shortcutChanged = old.hotkeyCode != value.hotkeyCode || old.hotkeyModifiers != value.hotkeyModifiers
        do {
            if shortcutChanged { try hotkey.register(code: value.hotkeyCode, modifiers: value.hotkeyModifiers) }
            if save { try value.save() }
            settings = value; popup.apply(value); preferences.apply(value)
        } catch {
            if shortcutChanged { try? hotkey.register(code: old.hotkeyCode, modifiers: old.hotkeyModifiers) }
            throw error
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
