import AppKit

public struct TerminalTabs {
    public let tabs: [TerminalTabSnapshot]
    public let selectedTTY: String?
    public let isComplete: Bool

    public init(tabs: [TerminalTabSnapshot], selectedTTY: String?, isComplete: Bool = true) {
        self.tabs = tabs
        self.selectedTTY = selectedTTY
        self.isComplete = isComplete
    }
}

/// Discovery reads must never start or activate the app. A stopped app returns an
/// empty inventory. Mark partial inventories so a missing tab cannot authorize a duplicate launch.
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
    /// Refresh the target before invoking verify. A nil title declines focus.
    /// Return false for a stale target, and throw for transport or focus failures.
    func focusIfVerified(_ target: TerminalTabSnapshot, verify: (TerminalTabSnapshot) throws -> String?) throws -> Bool
}

extension TerminalAdapter {
    public func focusIfVerified(_ target: TerminalTabSnapshot, verify: (TerminalTabSnapshot) throws -> String?) throws -> Bool {
        guard let tab = try currentPane(for: target), let title = try verify(tab) else { return false }
        try focus(paneID: tab.paneID, title: title)
        return true
    }

    func currentPane(for target: TerminalTabSnapshot) throws -> TerminalTabSnapshot? {
        try tabs().tabs.first { $0.paneID == target.paneID && $0.tty == target.tty }
    }
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
        let inventories = try installed.map { try $0.tabs() }
        let tabs = inventories.flatMap(\.tabs)
        for tty in ttys {
            if let tab = tabs.first(where: { $0.tty == tty }) {
                try focus(tab, title: title)
                return true
            }
        }
        guard inventories.allSatisfy(\.isComplete) else {
            throw CCSError.message("Some Terminal tabs could not be checked. Refresh before opening another viewer.")
        }
        return false
    }
}
