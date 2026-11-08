import AppKit

/// Owns dismissal for the picker and status menu without consuming outside clicks.
final class TransientUIDismissal {
    private weak var popup: Popup?
    private weak var menu: NSMenu?
    private var menuIsOpen = false
    private var globalMonitor: Any?, localMonitor: Any?, activationObserver: NSObjectProtocol?

    init(popup: Popup, menu: NSMenu) {
        self.popup = popup; self.menu = menu
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in self?.dismiss() }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self else { return event }
            // AppKit's menu windows handle their own tracking and item selection.
            if let window = event.window, window.level < .popUpMenu {
                if self.menuIsOpen { self.menu?.cancelTracking() }
                if let popup = self.popup, !popup.owns(window) { popup.hide(restoreFocus: false) }
            }
            return event
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier != ProcessInfo.processInfo.processIdentifier { self?.dismiss() }
        }
    }
    func menuWillOpen() { popup?.hide(restoreFocus: false); menuIsOpen = true }
    func menuDidClose() { menuIsOpen = false }
    private func dismiss() {
        if menuIsOpen { menu?.cancelTracking() }
        popup?.hide(restoreFocus: false)
    }
    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }; activationObserver = nil
    }
}
