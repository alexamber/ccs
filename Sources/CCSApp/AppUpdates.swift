import AppKit
import Sparkle

final class AppUpdates: NSObject, SPUStandardUserDriverDelegate, NSMenuItemValidation {
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self
    )
    private var checkItems = [NSMenuItem]()

    init?(bundle: Bundle = .main) {
        guard bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        super.init()
    }

    func addItems(to menu: NSMenu) {
        let check = menu.addItem(withTitle: "Check for Updates…",
                                 action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        check.target = controller
        checkItems.append(check)
        let automatic = menu.addItem(withTitle: "Automatically Check for Updates",
                                     action: #selector(toggleAutomaticChecks), keyEquivalent: "")
        automatic.target = self
    }

    @objc private func toggleAutomaticChecks() {
        controller.updater.automaticallyChecksForUpdates.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.state = controller.updater.automaticallyChecksForUpdates ? .on : .off
        return true
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                    state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        for item in checkItems { item.title = "Update to CCS \(update.displayVersionString)…" }
    }

    func standardUserDriverWillFinishUpdateSession() {
        for item in checkItems { item.title = "Check for Updates…" }
    }
}
