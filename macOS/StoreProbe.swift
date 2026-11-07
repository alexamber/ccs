import AppKit
import Carbon
import Foundation

// This executable deliberately runs inside App Sandbox. It tests CCS's actual
// integration points before choosing the release architecture.
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var output: NSTextView!
    var report: [String: Any] = [:]
    var selectedFolder: URL?
    var selectedClaude: URL?
    var hotkey: EventHotKeyRef?
    var handler: EventHandlerRef?
    var liveButton: NSButton!
    let fm = FileManager.default

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "CCS · App Store feasibility"
        window.center(); window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let title = NSTextField(labelWithString: "Can CCS work inside App Sandbox?")
        title.font = .systemFont(ofSize: 22, weight: .semibold); stack.addArrangedSubview(title)
        let intro = NSTextField(wrappingLabelWithString: "This diagnostic tests the real macOS restrictions. Folder selection grants access only to the chosen folder. Terminal tests need your Automation approval. Nothing is purchased or published.")
        stack.addArrangedSubview(intro)
        let row1 = NSStackView(); row1.spacing = 8
        row1.addArrangedSubview(button("1. Grant Claude data folder…", #selector(chooseFolder)))
        row1.addArrangedSubview(button("2. Choose Claude executable…", #selector(chooseClaude)))
        stack.addArrangedSubview(row1)
        let row2 = NSStackView(); row2.spacing = 8
        liveButton = button("3. Test live-session discovery", #selector(testLive)); liveButton.isEnabled = false
        row2.addArrangedSubview(liveButton)
        row2.addArrangedSubview(button("4. Test Terminal tab access", #selector(testTerminal)))
        row2.addArrangedSubview(button("5. Test new Terminal window", #selector(testLaunch)))
        stack.addArrangedSubview(row2)
        let row3 = NSStackView(); row3.spacing = 8
        row3.addArrangedSubview(button("Retest basic checks", #selector(basicChecks)))
        row3.addArrangedSubview(button("Copy diagnostic report", #selector(copyReport)))
        row3.addArrangedSubview(button("Show report in Finder", #selector(revealReport)))
        stack.addArrangedSubview(row3)
        output = NSTextView(); output.isEditable = false; output.isSelectable = true
        output.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        output.textContainerInset = NSSize(width: 10, height: 10)
        let scroll = NSScrollView(); scroll.documentView = output; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        stack.addArrangedSubview(scroll)
        window.contentView = stack
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        basicChecks()
        restoreSelections()
        registerHotkey()
    }

    func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }
    var reportURL: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CCS/feasibility.json")
    }
    func record(_ key: String, _ value: Any) {
        report[key] = value
        report["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            output?.string = String(decoding: data, as: UTF8.self)
            try? fm.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: reportURL, options: .atomic)
        }
    }
    @objc func basicChecks() {
        record("claudeExecutionException", Bundle.main.object(forInfoDictionaryKey: "CCSExecutionException") as? Bool ?? false)
        let actualHome = fm.homeDirectoryForCurrentUser.path
        record("sandboxContainer", actualHome)
        record("sandboxEnabled", ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil || actualHome.contains("/Containers/"))
        // FileManager's home is redirected in a sandbox. Resolve the account's
        // real home for the negative control and the initial Open-panel location.
        let realHome = accountHome
        record("ungrantedTranscriptRead", fm.isReadableFile(atPath: realHome + "/.claude/projects"))
        run("/bin/ps", ["-axo", "pid=,ppid=,tty=,command="], key: "processListing", redactOutput: true)
        run("/usr/sbin/lsof", ["-w", "-d", "cwd", "-Fn"], key: "workingDirectories", redactOutput: true)
    }
    var accountHome: String {
        guard let entry = getpwuid(getuid()), let value = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: value)
    }
    func restoreSelections() {
        for (key, folder) in [("claudeFolder", true), ("claudeExecutable", false)] {
            guard let data = UserDefaults.standard.data(forKey: key) else { continue }
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
                let accessed = url.startAccessingSecurityScopedResource()
                if folder {
                    selectedFolder = url
                    let contents = try fm.contentsOfDirectory(at: url.appendingPathComponent("projects"), includingPropertiesForKeys: nil)
                    record("folderAccessAfterRelaunch", ["success": accessed, "projectFolders": contents.count, "stale": stale])
                } else {
                    selectedClaude = url; liveButton?.isEnabled = true
                    record("executableAccessAfterRelaunch", ["success": accessed, "stale": stale])
                }
            } catch { record(key + "Restore", ["success": false, "error": error.localizedDescription]) }
        }
    }
    @objc func chooseFolder() {
        let panel = NSOpenPanel(); panel.title = "Choose your .claude folder"
        panel.message = "CCS needs read access to saved Claude session metadata. Choose .claude, not your entire home folder."
        panel.prompt = "Grant access"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.showsHiddenFiles = true; panel.directoryURL = URL(fileURLWithPath: accountHome + "/.claude")
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            if let previous = selectedFolder { previous.stopAccessingSecurityScopedResource() }
            selectedFolder = url
            _ = url.startAccessingSecurityScopedResource()
            let projects = url.appendingPathComponent("projects")
            do {
                let dirs = try fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)
                let count = dirs.reduce(0) { total, dir in
                    total + ((try? fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".jsonl") }.count) ?? 0)
                }
                let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(bookmark, forKey: "claudeFolder")
                var stale = false
                let restored = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
                let accessed = restored.startAccessingSecurityScopedResource()
                defer { if accessed { restored.stopAccessingSecurityScopedResource() } }
                record("selectedFolderRead", ["success": true, "transcripts": count, "bookmarkRestored": accessed, "bookmarkStale": stale])
            } catch { record("selectedFolderRead", ["success": false, "error": error.localizedDescription]) }
        }
    }
    @objc func chooseClaude() {
        let panel = NSOpenPanel(); panel.title = "Choose the Claude Code executable"
        panel.message = "Select the installed claude executable. This grants execution access for a read-only agents --json test."
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: accountHome + "/.local/bin")
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            if let previous = selectedClaude { previous.stopAccessingSecurityScopedResource() }
            selectedClaude = url; _ = url.startAccessingSecurityScopedResource()
            if let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(bookmark, forKey: "claudeExecutable")
            }
            liveButton.isEnabled = true
            record("claudeExecutableSelected", true)
        }
    }
    @objc func testLive() {
        guard let url = selectedClaude else { return }
        record("selectedExecutable", ["path": url.path, "readable": fm.isReadableFile(atPath: url.path),
                                       "exists": fm.fileExists(atPath: url.path), "executable": fm.isExecutableFile(atPath: url.path)])
        run(url.path, ["agents", "--json"], key: "claudeAgents", redactOutput: true, claudeHome: true)
    }
    func run(_ executable: String, _ args: [String], key: String, redactOutput: Bool = false, claudeHome: Bool = false) {
        record(key, ["running": true])
        // No shell startup files: the probe must show what the sandbox permits,
        // rather than depending on an unsandboxed shell or helper.
        var environment = ProcessInfo.processInfo.environment
        if claudeHome { environment["HOME"] = accountHome }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
            process.environment = environment
            // Use files to avoid a process listing filling stdout/stderr pipes.
            let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: tmp) }
                let outURL = tmp.appendingPathComponent("out"), errURL = tmp.appendingPathComponent("err")
                fm.createFile(atPath: outURL.path, contents: nil); fm.createFile(atPath: errURL.path, contents: nil)
                let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
                defer { try? out.close(); try? err.close() }
                process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
                let done = DispatchSemaphore(value: 0); process.terminationHandler = { _ in done.signal() }
                try process.run()
                let timedOut = done.wait(timeout: .now() + 15) == .timedOut
                if timedOut {
                    process.terminate()
                    if done.wait(timeout: .now() + 1) == .timedOut {
                        kill(process.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 1)
                    }
                }
                let data = (try? Data(contentsOf: outURL)) ?? Data()
                let error = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
                var result: [String: Any] = ["success": !timedOut && process.terminationStatus == 0,
                                             "exitCode": timedOut ? -1 : process.terminationStatus, "timedOut": timedOut,
                                             "stdoutBytes": data.count, "stderr": String(error.prefix(4000))]
                if key == "claudeAgents" {
                    if let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        result["validSessionList"] = list.allSatisfy { $0["sessionId"] is String }
                        result["sessionCount"] = list.count
                    } else { result["validSessionList"] = false }
                }
                // Never put transcript contents, session titles, or process command lines into the report.
                if !redactOutput { result["stdout"] = String(decoding: data, as: UTF8.self) }
                DispatchQueue.main.async { self.record(key, result) }
            } catch { DispatchQueue.main.async { self.record(key, ["success": false, "error": error.localizedDescription]) } }
        }
    }
    func appleScript(_ source: String, key: String) {
        var error: NSDictionary?
        let value = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            record(key, ["success": false, "error": error.description])
        } else { record(key, ["success": true, "result": value?.stringValue ?? ""] ) }
    }
    @objc func testTerminal() {
        // Read and reselect an existing tab; do not execute a command in it.
        appleScript("""
        tell application "Terminal"
            set windowCount to count of windows
            if windowCount > 0 then
                set t to selected tab of front window
                set selected of t to true
                return "Terminal windows: " & windowCount & "; tab access works"
            end if
            return "No Terminal windows; automation permission works"
        end tell
        """, key: "terminalTabs")
    }
    @objc func testLaunch() {
        // The only command the probe launches. No session, shell profile change,
        // or external helper is installed.
        appleScript("""
        tell application "Terminal"
            do script "printf 'CCS App Store feasibility test\\\\n'"
            activate
        end tell
        return "Opened a Terminal window"
        """, key: "terminalNewWindow")
    }
    func registerHotkey() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<ProbeDelegate>.fromOpaque(context).takeUnretainedValue()
            delegate.record("globalShortcutPressed", true)
            delegate.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { record("globalShortcutRegistration", Int(status)); return }
        // Ctrl-Option-Shift-Space avoids colliding with the installed Hammerspoon shortcut.
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey | shiftKey),
                                        EventHotKeyID(signature: 0x43435350, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        record("globalShortcutRegistration", ["success": result == noErr, "status": Int(result), "shortcut": "Ctrl-Option-Shift-Space"])
    }
    @objc func copyReport() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output.string, forType: .string)
    }
    @objc func revealReport() { NSWorkspace.shared.activateFileViewerSelecting([reportURL]) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let delegate = ProbeDelegate()
if CommandLine.arguments.contains("--headless") {
    // Automated file/process integration tests use the same signed sandboxed
    // executable and entitlements. This mode never sends Terminal Apple events.
    delegate.basicChecks()
    delegate.restoreSelections()
    if let i = CommandLine.arguments.firstIndex(of: "--claude"), i + 1 < CommandLine.arguments.count {
        delegate.selectedClaude = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        delegate.testLive()
    }
    let deadline = Date().addingTimeInterval(22)
    while Date() < deadline {
        let pending = delegate.report.values.contains { ($0 as? [String: Any])?["running"] as? Bool == true }
        if !pending { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    if let data = try? JSONSerialization.data(withJSONObject: delegate.report, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
} else {
    let application = NSApplication.shared
    application.delegate = delegate
    application.run()
}
