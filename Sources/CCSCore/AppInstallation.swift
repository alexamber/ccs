import Foundation
import Darwin

public enum Product {
    public static let bundleIdentifier = "io.github.alexamber.ccs"
    public static let showNotification = Notification.Name(bundleIdentifier + ".show")
    public static let settingsNotification = Notification.Name(bundleIdentifier + ".settings")
    public static let website = URL(string: "https://github.com/alexamber/ccs")!
    public static var version: String {
        AppInstallation.embeddedBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
    // Set only to a real, owner-supplied public tip URL.
    public static var donationURL: URL? {
        guard let value = AppInstallation.embeddedBundle?.object(forInfoDictionaryKey: "CCSDonationURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

public enum AppInstallation {
    public static var executable: URL {
        // argv[0] can be just "ccs" when invoked through a shell PATH lookup.
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        _NSGetExecutablePath(&buffer, &size)
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    }
    public static var embeddedBundle: Bundle? {
        let url = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard url.pathExtension == "app", let bundle = Bundle(url: url), bundle.bundleIdentifier == Product.bundleIdentifier else { return nil }
        return bundle
    }
    public static var cli: URL {
        embeddedBundle?.bundleURL.appendingPathComponent("Contents/MacOS/ccs") ?? executable
    }
    public static func findApp() throws -> URL {
        let candidates = [embeddedBundle?.bundleURL, URL(fileURLWithPath: "/Applications/CCS.app"),
                          URL(fileURLWithPath: CCSPaths.home).appendingPathComponent("Applications/CCS.app")].compactMap { $0 }
        guard let app = candidates.first(where: {
            Bundle(url: $0)?.bundleIdentifier == Product.bundleIdentifier &&
            FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("Contents/MacOS/CCSApp").path)
        }) else { throw CCSError.message("CCS.app was not found. Install the app from a CCS release or with Homebrew.") }
        return app
    }
}
