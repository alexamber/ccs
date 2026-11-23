import AppKit

/// Unicorn clicks put the content in the launcher's expanding panel. The
/// keyboard switcher's menu-bar anchor still uses a native popover.
final class UnicornMenu: NSObject, NSPopoverDelegate {
    // Only the header makes room for the unicorn in an expanded card.
    static let headerIconSize: CGFloat = 24
    static let headerClearance = headerIconSize + 12

    private let fallback = NSPopover()
    private weak var host: TerminalSessionPopup?
    var onClose: (() -> Void)?
    var contentViewController: NSViewController?
    var contentSize: NSSize = .zero {
        didSet {
            guard oldValue != contentSize else { return }
            if let host { host.resizeMenu(self) }
            else if fallback.isShown { fallback.contentSize = contentSize }
        }
    }
    var isShown: Bool { host != nil || fallback.isShown }

    override init() {
        super.init()
        fallback.behavior = .transient; fallback.animates = false; fallback.delegate = self
    }

    func showFromUnicorn(_ anchor: NSView) {
        if let launcher = anchor.window?.delegate as? TerminalSessionPopup, contentViewController != nil {
            host = launcher
            launcher.presentMenu(self)
        } else {
            fallback.contentViewController = contentViewController
            fallback.contentSize = contentSize
            NSApp.activate(ignoringOtherApps: true)
            fallback.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    func close() {
        if let host {
            self.host = nil
            host.dismissMenu(self)
            onClose?()
        } else if fallback.isShown { fallback.performClose(nil) }
    }
    func popoverDidClose(_ notification: Notification) { fallback.contentViewController = nil; onClose?() }
}
