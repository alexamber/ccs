import Foundation

/// Apple Terminal identifies a tab by its local TTY.
struct AppleTerminalAdapter: TerminalAdapter {
    static let id = "com.apple.Terminal"
    let bundleID = id
    let name = "Terminal"
    let runner: CommandRunner

    func frontTab() -> TerminalTabSnapshot? {
        guard let result = try? runner("/usr/bin/osascript", ["-"], Self.frontTabScript, 2), result.code == 0 else { return nil }
        return TerminalTabSnapshot(output: result.out)
    }

    func selectedTTY() throws -> String? {
        let result = try runner("/usr/bin/osascript", ["-"], Self.selectedTTYScript, 2)
        guard result.code == 0 else { throw CCSError.message("Couldn’t read the current Terminal tab.") }
        let tty = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tty.isEmpty else { return nil }
        guard tty.hasPrefix("/dev/tty"), !tty.contains(where: \.isWhitespace) else {
            throw CCSError.message("Terminal returned an invalid tab identifier.")
        }
        return tty
    }

    func tabs() throws -> TerminalTabs {
        let result = try runner("/usr/bin/osascript", ["-l", "JavaScript", "-"], Self.switchTabsScript, 3)
        guard result.code == 0 else { throw CCSError.message("Couldn’t read Terminal tabs. Check CCS’s Terminal Automation permission.") }
        struct Inventory: Decodable {
            struct Tab: Decodable {
                struct Bounds: Decodable { let x, y, width, height: Double }
                let tty: String
                let title: String?
                let bounds: Bounds?
                let windowID: Int32?
            }
            let selectedTTY: String?
            let tabs: [Tab]
            let complete: Bool
        }
        guard let inventory = try? JSONDecoder().decode(Inventory.self, from: Data(result.out.utf8)) else {
            throw CCSError.message("Terminal returned an incomplete tab list. Refresh and try again.")
        }
        let tabs = inventory.tabs.compactMap { tab -> TerminalTabSnapshot? in
            guard tab.tty.hasPrefix("/dev/tty"), !tab.tty.contains(where: \.isWhitespace) else { return nil }
            let bounds = tab.bounds.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } ?? .zero
            return TerminalTabSnapshot(terminalID: bundleID, paneID: tab.tty, tty: tab.tty, bounds: bounds,
                                       title: cleanText(tab.title), windowID: tab.windowID)
        }
        return TerminalTabs(tabs: tabs, selectedTTY: inventory.selectedTTY,
                            isComplete: inventory.complete && tabs.count == inventory.tabs.count)
    }

    func focus(paneID: String, title: String) throws {
        let result = try runner("/usr/bin/osascript", ["-", title, paneID], Self.focusScript, 5)
        guard result.code == 0, result.out.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
            throw CCSError.message("Couldn’t focus that Terminal tab. Refresh and try again.")
        }
    }

    func focusIfVerified(_ target: TerminalTabSnapshot, verify: (TerminalTabSnapshot) throws -> String?) throws -> Bool {
        if let window = AppleTerminalWindow(tab: target), let currentTitle = try window.title() {
            return try focus(window, tab: target, currentTitle: currentTitle, verify: verify)
        }
        // Tabs can move between windows. Rediscover by TTY and revalidate.
        guard let tab = try currentPane(for: target) else { return false }
        if let window = AppleTerminalWindow(tab: tab) {
            return try focus(window, tab: tab, currentTitle: tab.title, verify: verify)
        }
        guard let title = try verify(tab) else { return false }
        try focus(paneID: tab.paneID, title: title)
        return true
    }

    private func focus(_ window: AppleTerminalWindow, tab: TerminalTabSnapshot, currentTitle: String,
                       verify: (TerminalTabSnapshot) throws -> String?) throws -> Bool {
        func verifiedTitle(_ title: String) throws -> String? {
            try verify(TerminalTabSnapshot(terminalID: bundleID, paneID: tab.paneID, tty: tab.tty,
                                          bounds: tab.bounds, title: title, windowID: tab.windowID))
        }
        guard let newTitle = try verifiedTitle(currentTitle) else { return false }
        return try window.focus(tty: tab.tty, verifiedTitle: currentTitle, newTitle: newTitle, activate: {
            try focus(paneID: tab.paneID, title: newTitle)
        }, revalidate: { title in try verifiedTitle(title) != nil })
    }

    func launch(command: String, title: String) throws {
        let result = try runner("/usr/bin/osascript", ["-", title, command], Self.launchScript, 15)
        guard result.code == 0 else {
            throw CCSError.message(result.err.trimmingCharacters(in: .whitespacesAndNewlines).nonempty ?? "Could not open Terminal.app. Check CCS’s Terminal Automation permission.")
        }
    }

    // Never launch or activate Terminal. An app switch between the native
    // frontmost check and this Apple event must not produce a popup.
    static let frontTabScript = """
    if application "Terminal" is not running then return ""
    tell application "Terminal"
      if not frontmost then return ""
      if (count of windows) is 0 then return ""
      set w to front window
      set device to tty of selected tab of w
      set edges to bounds of w
      return device & linefeed & (item 1 of edges as text) & linefeed & (item 2 of edges as text) & linefeed & (item 3 of edges as text) & linefeed & (item 4 of edges as text) & linefeed & (custom title of selected tab of w)
    end tell
    """
    public static let selectedTTYScript = """
    if application "Terminal" is not running then return ""
    tell application "Terminal"
      if (count of windows) is 0 then return ""
      return tty of selected tab of front window
    end tell
    """

    public static let switchTabsScript = """
    function run() {
      const terminal = Application("com.apple.Terminal");
      const inventory = {selectedTTY: null, tabs: [], complete: true};
      if (!terminal.running()) return JSON.stringify(inventory);
      const windows = terminal.windows();
      // Selection and window geometry are hints. Neither determines whether a tab exists.
      function optional(read) { try { return read(); } catch (_) { return null; } }
      if (windows.length) inventory.selectedTTY = optional(() => windows[0].selectedTab.tty());
      for (const window of windows) {
        const id = optional(() => window.id());
        const rectangle = optional(() => window.bounds());
        const bounds = rectangle && [rectangle.x, rectangle.y, rectangle.width, rectangle.height].every(Number.isFinite)
          ? rectangle : null;
        const tabs = optional(() => window.tabs());
        if (!tabs) { inventory.complete = false; continue; }
        for (const tab of tabs) {
          const tty = optional(() => tab.tty());
          if (typeof tty !== "string" || !tty) { inventory.complete = false; continue; }
          const title = optional(() => tab.customTitle());
          inventory.tabs.push({tty, bounds, windowID: Number.isInteger(id) ? id | 0 : null,
                               title: typeof title === "string" ? title : null});
        }
      }
      return JSON.stringify(inventory);
    }
    """
    // Keep cosmetic errors inside this handler: a successful focus or launch
    // must never become a failed action (or trigger a duplicate launch).
    static let titleScript = """
    on nameTab(targetTab, newTitle)
      try
        if newTitle is "" then return
        tell application "Terminal"
          considering case, diacriticals
            if custom title of targetTab is not newTitle then set custom title of targetTab to newTitle
          end considering
        end tell
      end try
    end nameTab
    """
    public static let launchScript = """
    on run argv
      tell application "Terminal"
        set openedTab to do script (item 2 of argv)
        my nameTab(openedTab, item 1 of argv)
        activate
      end tell
    end run
    """ + "\n" + titleScript
    public static let focusScript = """
    on run argv
      tell application "Terminal"
        repeat with candidate in items 2 thru -1 of argv
          set wanted to contents of candidate
          repeat with w in windows
            try
              set wtabs to tabs of w
            on error
              set wtabs to {}
            end try
            repeat with t in wtabs
              if tty of t is wanted then
                if miniaturized of w then set miniaturized of w to false
                set selected of t to true
                set index of w to 1
                my nameTab(t, item 1 of argv)
                activate
                return "ok"
              end if
            end repeat
          end repeat
        end repeat
      end tell
      return "missing"
    end run
    """ + "\n" + titleScript
}

extension TerminalTabSnapshot {
    public init?(output: String, windowID: Int32? = nil) {
        self.windowID = windowID
        let lines = output.split(maxSplits: 5, whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 5, lines[0].hasPrefix("/dev/tty") else { return nil }
        let edges = lines[1...4].compactMap(Double.init)
        guard edges.count == 4, edges.allSatisfy(\.isFinite),
              edges[2] > edges[0], edges[3] > edges[1] else { return nil }
        terminalID = AppleTerminalAdapter.id
        paneID = lines[0]
        tty = lines[0]
        title = lines.count == 6 ? cleanText(lines[5]) : ""
        bounds = CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
    }

    public static func read(runner: @escaping CommandRunner = ProcessRunner().command) -> TerminalTabSnapshot? {
        AppleTerminalAdapter(runner: runner).frontTab()
    }

    public static let script = AppleTerminalAdapter.frontTabScript
}
