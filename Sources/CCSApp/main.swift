import AppKit
import CCSCore

let app = NSApplication.shared
if NSRunningApplication.runningApplications(withBundleIdentifier: Product.bundleIdentifier).contains(where: {
    $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
}) {
    DistributedNotificationCenter.default().postNotificationName(Product.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
