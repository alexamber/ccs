import AppKit
import CCSCore
import ServiceManagement

final class Preferences: NSObject {
    let window: NSWindow
    var settings: Settings
    var onSave: ((Settings) throws -> Void)?
    private let engine: Engine
    private let shortcut = ShortcutRecorder()
    private let days = NSPopUpButton()
    private let newProvider = NSPopUpButton()
    private let newProviderValue = NSTextField(labelWithString: "")
    private let claudeToggle = NSButton(checkboxWithTitle: "Claude", target: nil, action: nil)
    private let codexToggle = NSButton(checkboxWithTitle: "Codex", target: nil, action: nil)
    private let grouping = NSSegmentedControl(labels: ["Recent", "Folders"], trackingMode: .selectOne, target: nil, action: nil)
    private let folder = NSTextField(labelWithString: "")
    private let folderHint = NSTextField(labelWithString: "")
    private let choose = NSButton(title: "Choose…", target: nil, action: nil)
    private let cleanup = NSSwitch(), login = NSSwitch()
    private let cliIcon = NSImageView(), cliTitle = NSTextField(labelWithString: ""), cliDetail = NSTextField(labelWithString: "")
    private let cliAction = NSButton(title: "", target: nil, action: nil)
    private var environment = ProcessInfo.processInfo.environment
    private var installedCLI: URL?, commandOnPath = false
    private var popover: NSPopover?
    var isCLIInstalled: Bool { installedCLI != nil }
    func finishRecordingCurrentShortcut() -> Bool {
        guard shortcut.recording else { return false }
        shortcut.cancelRecording(); return true
    }

    init(settings: Settings, engine: Engine) {
        self.settings = settings; self.engine = engine
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 426), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "CCS Settings"; window.isReleasedWhenClosed = false; window.center()
        shortcut.controlSize = .small; shortcut.font = .systemFont(ofSize: 12)
        shortcut.title = settings.hotkeyLabel; shortcut.savedTitle = settings.hotkeyLabel
        shortcut.setAccessibilityLabel("Change global shortcut")
        shortcut.onRecord = { [weak self] code, modifiers, label in
            guard let self else { return }
            let old = self.settings
            self.settings.hotkeyCode = code; self.settings.hotkeyModifiers = modifiers; self.settings.hotkeyLabel = label
            do { try self.onSave?(self.settings); self.shortcut.savedTitle = label }
            catch { self.settings = old; self.shortcut.title = old.hotkeyLabel; showError(error, window: self.window) }
        }
        days.addItems(withTitles: ["1 day", "3 days", "7 days", "30 days", "All"])
        days.selectItem(at: dateWindows.firstIndex(of: settings.defaultDays) ?? 2)
        days.toolTip = "Date range when opening the picker. Running sessions are always included."
        days.setAccessibilityLabel("Default date range")
        grouping.selectedSegment = settings.folders ? 1 : 0
        grouping.setAccessibilityLabel("Default session view")
        newProvider.addItems(withTitles: Provider.allCases.map(\.title))
        newProvider.selectItem(at: Provider.allCases.firstIndex(of: settings.newProvider) ?? 0)
        newProvider.controlSize = .small; newProvider.font = .systemFont(ofSize: 12)
        newProvider.target = self; newProvider.action = #selector(changeNewProvider)
        newProvider.setAccessibilityLabel("Provider for new dated sessions")
        newProviderValue.font = .systemFont(ofSize: 12)
        newProvider.toolTip = "Used by \(settings.hotkeyLabel) again, ⌘N, and ccs --new. Shift-Enter uses the selected session’s provider."
        for toggle in [claudeToggle, codexToggle] {
            toggle.controlSize = .small; toggle.font = .systemFont(ofSize: 12)
            toggle.target = self; toggle.action = #selector(changeEnabledProviders)
        }
        cleanup.state = settings.cleanup ? .on : .off; cleanup.setAccessibilityLabel("Clean up empty session folders")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off; login.setAccessibilityLabel("Start at login")
        for control in [days as NSControl, grouping, cleanup] {
            control.controlSize = .small; control.font = .systemFont(ofSize: 12)
            control.target = self; control.action = #selector(changed)
        }
        login.controlSize = .small; login.target = self; login.action = #selector(changeLogin)
        choose.controlSize = .small; choose.bezelStyle = .rounded; choose.target = self; choose.action = #selector(chooseDirectory)
        choose.setAccessibilityLabel("Choose new-session folder")
        folder.font = .monospacedSystemFont(ofSize: 11, weight: .regular); folder.lineBreakMode = .byTruncatingMiddle
        folderHint.font = .systemFont(ofSize: 10); folderHint.textColor = .secondaryLabelColor; folderHint.isHidden = true
        let folderText = NSStackView(views: [folder, folderHint]); folderText.orientation = .vertical; folderText.alignment = .leading; folderText.spacing = 1
        let cleanupHelp = NSButton(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About folder cleanup")!, target: self, action: #selector(cleanupHelp))
        cleanupHelp.isBordered = false; cleanupHelp.contentTintColor = .secondaryLabelColor
        cleanupHelp.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let cleanupLabel = NSStackView(views: [label("Clean up empty folders"), cleanupHelp]); cleanupLabel.spacing = 5
        let defaults = NSStackView(views: [grouping, days]); defaults.spacing = 8
        let sources = NSStackView(views: [claudeToggle, codexToggle]); sources.spacing = 14
        let newChoice = NSStackView(views: [newProvider, newProviderValue])
        let picker = section("Picker", rows: [row(label("Providers"), sources), row(label("Shortcut"), shortcut), row(label("Open with"), defaults), row(label("New sessions"), newChoice), row(label("Start at login"), login)])
        let sessions = section("Sessions", rows: [row(folderText, choose, minimumHeight: 28), row(cleanupLabel, cleanup)])
        cliTitle.font = .systemFont(ofSize: 12, weight: .medium)
        cliDetail.font = .systemFont(ofSize: 10); cliDetail.textColor = .secondaryLabelColor; cliDetail.lineBreakMode = .byTruncatingMiddle
        let cliText = NSStackView(views: [cliTitle, cliDetail]); cliText.orientation = .vertical; cliText.alignment = .leading; cliText.spacing = 2
        cliIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true; cliIcon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let cliLeading = NSStackView(views: [cliIcon, cliText]); cliLeading.spacing = 9
        cliAction.controlSize = .small; cliAction.bezelStyle = .rounded; cliAction.target = self; cliAction.action = #selector(cliClicked)
        let terminal = section("Command-line tool", rows: [row(cliLeading, cliAction, minimumHeight: 32)])
        let version = label("CCS " + Product.version); version.font = .systemFont(ofSize: 10); version.textColor = .tertiaryLabelColor
        let help = NSButton(title: "Help", target: self, action: #selector(openHelp)); help.isBordered = false; help.font = .systemFont(ofSize: 11); help.contentTintColor = .linkColor
        let footer = row(version, help, minimumHeight: 16)
        let stack = NSStackView(views: [picker, sessions, terminal, footer]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 14), stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -10)])
        window.initialFirstResponder = shortcut
        apply(settings); refreshInstallation(); refreshEnvironment()
    }
    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: 12); return field
    }
    private func row(_ leading: NSView, _ trailing: NSView, minimumHeight: CGFloat = 24) -> NSStackView {
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [leading, spacer, trailing]); row.spacing = 8; row.alignment = .centerY
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }
    private func section(_ title: String, rows: [NSView]) -> NSView {
        let heading = label(title); heading.font = .systemFont(ofSize: 11, weight: .semibold); heading.textColor = .secondaryLabelColor
        let card = SettingsCard(), contents = NSStackView(); contents.orientation = .vertical; contents.alignment = .leading; contents.spacing = 4
        for (index, row) in rows.enumerated() {
            if index > 0 { let line = NSBox(); line.boxType = .separator; contents.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: contents.widthAnchor).isActive = true }
            contents.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: contents.widthAnchor).isActive = true
        }
        contents.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(contents)
        NSLayoutConstraint.activate([contents.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10), contents.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10), contents.topAnchor.constraint(equalTo: card.topAnchor, constant: 6), contents.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6)])
        let section = NSStackView(views: [heading, card]); section.orientation = .vertical; section.alignment = .leading; section.spacing = 5
        card.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }
    func show() {
        refreshInstallation(); refreshEnvironment()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func apply(_ value: Settings) {
        let shortcutChanged = settings.hotkeyCode != value.hotkeyCode || settings.hotkeyModifiers != value.hotkeyModifiers
        settings = value
        if shortcutChanged { shortcut.cancelRecording() }
        if !shortcut.recording { shortcut.title = value.hotkeyLabel; shortcut.savedTitle = value.hotkeyLabel }
        days.selectItem(at: dateWindows.firstIndex(of: value.defaultDays) ?? 2)
        grouping.selectedSegment = value.folders ? 1 : 0
        newProvider.removeAllItems(); newProvider.addItems(withTitles: value.enabledProviders.map(\.title))
        newProvider.selectItem(at: value.enabledProviders.firstIndex(of: value.newProvider) ?? 0)
        newProvider.isEnabled = value.enabledProviders.count > 1
        newProvider.isHidden = value.enabledProviders.count == 1
        newProviderValue.isHidden = value.enabledProviders.count > 1
        newProviderValue.stringValue = value.newProvider.title
        for (provider, toggle) in [(Provider.claude, claudeToggle), (Provider.codex, codexToggle)] {
            let enabled = value.enabledProviders.contains(provider)
            toggle.state = enabled ? .on : .off; toggle.isEnabled = !enabled || value.enabledProviders.count > 1
            toggle.toolTip = !toggle.isEnabled ? "Enable another provider before turning this one off" : provider.isInstalled(environment: environment) ? "Show \(provider.title) sessions" : "\(provider.title) command is not on your shell PATH; install it to open sessions"
        }
        cleanup.state = value.cleanup ? .on : .off
        refreshFolder()
    }
    @objc private func changeNewProvider() {
        let old = settings
        settings.newProvider = settings.enabledProviders[max(0, newProvider.indexOfSelectedItem)]
        do { try onSave?(settings) }
        catch { apply(old); showError(error, window: window) }
    }
    @objc private func changeEnabledProviders() {
        let old = settings
        settings.enabledProviders = [(Provider.claude, claudeToggle), (Provider.codex, codexToggle)].filter { $0.1.state == .on }.map(\.0)
        settings = settings.resolvingProviders(environment: environment)
        do { try onSave?(settings) }
        catch { apply(old); showError(error, window: window) }
    }
    private func refreshEnvironment() {
        engine.perform({ _, env in env }) { [weak self] result in
            guard let self, case .success(let env) = result else { return }
            self.environment = env; self.apply(self.settings); self.refreshInstallation()
        }
    }
    private func refreshFolder() {
        let override = environment["CCS_NEW_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let path = CCSPaths.expand(override ?? settings.newDirectory)
        folder.stringValue = shortPath(path); folder.toolTip = path
        folderHint.stringValue = override == nil ? "" : "Set by your shell"
        folderHint.isHidden = override == nil; choose.isEnabled = override == nil
        choose.toolTip = override == nil ? "Choose where dated session folders are created" : "CCS_NEW_DIR in your shell sets this folder. Remove that override and restart CCS to choose a folder here."
        if override != nil { folderHint.toolTip = choose.toolTip }
    }
    func refreshInstallation() {
        let installation = CLIInstaller.status(source: AppInstallation.cli, environment: environment)
        installedCLI = installation.location; commandOnPath = installation.isOnPath
        cliIcon.image = NSImage(systemSymbolName: installedCLI == nil ? "terminal" : "checkmark.circle.fill", accessibilityDescription: installedCLI == nil ? "Not installed" : "Installed")
        cliIcon.contentTintColor = installedCLI == nil ? .secondaryLabelColor : .systemGreen
        cliTitle.stringValue = installedCLI == nil ? "Add the ccs command" : commandOnPath ? "ccs · Installed" : "ccs · Shell setup needed"
        cliDetail.stringValue = installedCLI == nil ? "Browse sessions by typing ccs in Terminal" : commandOnPath ? "Type ccs in Terminal to browse sessions" : "One step to enable ccs in Terminal"
        cliAction.title = installedCLI == nil ? "Install…" : commandOnPath ? "Copy ccs" : "Set up…"
        cliAction.toolTip = installedCLI == nil ? "Link the bundled command into ~/.local/bin" : commandOnPath ? "Copy ccs to the clipboard" : "Show how to enable the command in your shell"
    }
    @objc private func cliClicked() {
        if let installedCLI {
            guard commandOnPath else { showCLISetup(installedCLI); return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString("ccs", forType: .string)
            cliAction.title = "Copied"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refreshInstallation() }
        } else { installCLI() }
    }
    @objc private func changed() {
        let old = settings
        settings.defaultDays = dateWindows[max(0, days.indexOfSelectedItem)]; settings.folders = grouping.selectedSegment == 1; settings.cleanup = cleanup.state == .on
        do { try onSave?(settings) }
        catch { settings = old; days.selectItem(at: dateWindows.firstIndex(of: old.defaultDays) ?? 2); grouping.selectedSegment = old.folders ? 1 : 0; cleanup.state = old.cleanup ? .on : .off; showError(error, window: window) }
    }
    @objc private func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: CCSPaths.expand(settings.newDirectory)); panel.prompt = "Choose folder"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let old = self.settings; self.settings.newDirectory = shortPath(url.path)
            do { try self.onSave?(self.settings); self.refreshFolder() }
            catch { self.settings = old; showError(error, window: self.window) }
        }
    }
    @objc private func changeLogin() {
        let enable = login.state == .on; login.isEnabled = false
        Task { @MainActor in
            defer { login.isEnabled = true }
            do {
                if enable { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
                login.toolTip = SMAppService.mainApp.status == .requiresApproval ? "Approve CCS in System Settings → General → Login Items" : nil
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } catch { login.state = SMAppService.mainApp.status == .enabled ? .on : .off; showError(error, window: window) }
        }
    }
    @objc func installCLI() {
        do {
            _ = try CLIInstaller.install(source: AppInstallation.cli)
            refreshInstallation()
            if !commandOnPath, let installedCLI { showCLISetup(installedCLI) }
        } catch { showError(error, window: window) }
    }
    private func showCLISetup(_ command: URL) {
        let directory = shellQuote(command.deletingLastPathComponent().path)
        let shell = URL(fileURLWithPath: environment["SHELL"] ?? "/bin/zsh").lastPathComponent
        let file = shell == "bash" ? "~/.bash_profile" : shell == "fish" ? "~/.config/fish/config.fish" : "~/.zshrc"
        let line = shell == "fish" ? "fish_add_path \(directory)" : "export PATH=\(directory):\"$PATH\""
        explain("Your shell is not using this copy of ccs yet. Add this line to \(file), then open a new Terminal window:\n\n\(line)\n\nType ccs to browse sessions, or ccs --gui to open the popup. You can select and copy the setup line above.", from: cliAction)
    }
    @objc private func cleanupHelp(_ sender: NSButton) {
        explain("Removes empty dated folders after Claude exits, and checks abandoned folders after five minutes. Folders with files, saved sessions, or a process using them are kept. If CCS cannot verify that a folder is unused, it keeps it.", from: sender)
    }
    private func explain(_ text: String, from view: NSView) {
        let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: 12); label.preferredMaxLayoutWidth = 280
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        let controller = NSViewController(); controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 308, height: 150)); controller.view.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 14), label.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -14), label.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 12), label.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -12), label.widthAnchor.constraint(equalToConstant: 280)])
        controller.view.setFrameSize(NSSize(width: 308, height: label.fittingSize.height + 24))
        let popover = NSPopover(); popover.contentViewController = controller; popover.behavior = .transient; self.popover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }
    @objc private func openHelp() { NSWorkspace.shared.open(Product.website) }
}

private final class SettingsCard: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 9; layer?.borderWidth = 0.5; layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
