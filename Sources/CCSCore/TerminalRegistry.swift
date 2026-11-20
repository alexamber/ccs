import AppKit

public struct TerminalTabs {
    public let tabs: [TerminalTabSnapshot]
    public let selectedTTY: String?

    public init(tabs: [TerminalTabSnapshot], selectedTTY: String?) {
        self.tabs = tabs
        self.selectedTTY = selectedTTY
    }
}

/// Discovery reads must never start or activate the app. A stopped app returns an
/// empty inventory. Throw on an incomplete read so it cannot authorize a duplicate launch.
/// Each snapshot identifies its owner by bundle ID, its pane by native ID, and
/// its local process by TTY. Bounds use global coordinates with a top-left origin.
public protocol TerminalAdapter {
    var bundleID: String { get }
    var name: String { get }
    func tabs() throws -> TerminalTabs
    func selectedTTY() throws -> String?
    /// Return nil if the application no longer has keyboard focus.
    func frontTab() -> TerminalTabSnapshot?
    func focus(paneID: String, title: String) throws
    func launch(command: String, title: String) throws
}

public struct TerminalRegistry {
    private let adapters: [any TerminalAdapter]
    private let isInstalled: (String) -> Bool

    public init(adapters: [any TerminalAdapter], isInstalled: @escaping (String) -> Bool) {
        self.adapters = adapters
        self.isInstalled = isInstalled
    }

    public static func system(runner: @escaping CommandRunner = ProcessRunner().command) -> Self {
        TerminalRegistry(adapters: [AppleTerminalAdapter(runner: runner)]) { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
        }
    }

    public var installed: [any TerminalAdapter] { adapters.filter { isInstalled($0.bundleID) } }

    /// The frontmost application is already running. This lookup avoids polling Launch Services.
    public func supported(bundleID: String?) -> (any TerminalAdapter)? {
        adapters.first { $0.bundleID == bundleID }
    }

    func adapter(for id: String) throws -> any TerminalAdapter {
        guard let adapter = supported(bundleID: id), isInstalled(id) else {
            throw CCSError.message("The selected terminal is unavailable. Choose an installed terminal in Settings.")
        }
        return adapter
    }

    func launch(command: String, title: String, preferred: String?) throws {
        if let preferred {
            try adapter(for: preferred).launch(command: command, title: title)
        } else if let first = installed.first {
            try first.launch(command: command, title: title)
        } else {
            throw CCSError.message("No supported terminal is installed.")
        }
    }

    func focus(_ tab: TerminalTabSnapshot, title: String) throws {
        try adapter(for: tab.terminalID).focus(paneID: tab.paneID, title: title)
    }

    func focusViewer(ttys: [String], title: String) throws -> Bool {
        let tabs = try installed.flatMap { try $0.tabs().tabs }
        for tty in ttys {
            if let tab = tabs.first(where: { $0.tty == tty }) {
                try focus(tab, title: title)
                return true
            }
        }
        return false
    }
}
