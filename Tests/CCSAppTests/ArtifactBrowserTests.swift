import AppKit
import CCSCore
import XCTest
@testable import CCSApp

final class ArtifactBrowserTests: XCTestCase {
    private func settle() {
        let done = expectation(description: "UI queue settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }
    private func file(_ folder: String) -> SessionArtifact {
        SessionArtifact(url: URL(fileURLWithPath: folder + "/report.html"), relativePath: "report.html", modifiedAt: Date())
    }
    private func key(_ code: UInt16, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    func testFolderActionUsesCurrentFolderAndNeverOpensOnSelection() {
        _ = NSApplication.shared
        var opened = [URL](), dismissed = 0
        let button = FolderButton(opener: { opened.append($0); return true })
        let browser = ArtifactBrowser(folderButton: button, loader: { _, done in done(ArtifactSnapshot()) })
        browser.onOpened = { dismissed += 1 }
        browser.show(folder: "/tmp/first")
        browser.show(folder: "/tmp/Łódź team's workspace")
        XCTAssertTrue(opened.isEmpty)
        button.openFolder()
        XCTAssertEqual(opened.map(\.path), ["/tmp/Łódź team's workspace"])
        XCTAssertEqual(dismissed, 1)
        browser.show(folder: nil)
        XCTAssertFalse(button.isEnabled)
        button.openFolder(); XCTAssertEqual(opened.count, 1)
        browser.cancel()
    }

    func testUnavailableFolderDoesNotDismissTheBrowser() {
        _ = NSApplication.shared
        var dismissed = false
        let button = FolderButton(opener: { _ in false })
        let browser = ArtifactBrowser(folderButton: button, loader: { _, done in done(ArtifactSnapshot()) })
        browser.onOpened = { dismissed = true }
        browser.show(folder: "/missing")
        button.openFolder()
        XCTAssertFalse(dismissed)
        XCTAssertTrue(button.toolTip?.contains("Couldn’t open") == true)
        browser.cancel()
    }

    func testRapidSelectionCoalescesRequestsAndDiscardsStaleFiles() {
        _ = NSApplication.shared
        var requests = [(String, (ArtifactSnapshot) -> Void)]()
        let browser = ArtifactBrowser(loader: { requests.append(($0, $1)) })
        browser.show(folder: "/a"); browser.show(folder: "/b")
        settle()
        XCTAssertEqual(requests.map(\.0), ["/b"])
        browser.show(folder: "/c"); settle()
        requests[0].1(ArtifactSnapshot(files: [file("/b")]))
        XCTAssertTrue(browser.files.isEmpty)
        requests[1].1(ArtifactSnapshot(files: [file("/c")]))
        XCTAssertEqual(browser.files.map(\.url.path), ["/c/report.html"])
        browser.show(folder: "/d"); settle(); browser.cancel()
        requests[2].1(ArtifactSnapshot(files: [file("/d")]))
        XCTAssertTrue(browser.files.isEmpty, "Hidden views discard in-flight results")
    }

    func testPickerFollowsSelectionAndRoutesFileKeyboardActions() throws {
        _ = NSApplication.shared
        var opened = [String]()
        let browser = ArtifactBrowser(loader: { folder, done in done(ArtifactSnapshot(files: [self.file(folder)])) },
                                      opener: { opened.append($0.url.path); return true })
        let sessions = [Session(id: "a", cwd: "/a", mtime: Date().timeIntervalSince1970, title: "First project"),
                        Session(id: "b", cwd: "/b", mtime: Date().timeIntervalSince1970, title: "Second project")]
        let popup = Popup(engine: Engine(environment: { [:] }), settings: Settings(),
                          loadHistory: { $0(.success(HistorySnapshot(sessions: sessions, issues: [:], installedProviders: [.claude]))) }, artifactBrowser: browser)
        popup.show(); defer { popup.hide(restoreFocus: false) }
        settle()
        XCTAssertEqual(browser.folder, popup.selected?.cwd)
        if let directory = ProcessInfo.processInfo.environment["CCS_UI_ARTIFACT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let view = try XCTUnwrap(popup.panel.contentView)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                popup.panel.appearance = NSAppearance(named: appearance)
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("picker-files-\(name).png"))
            }
        }
        let previous = popup.selected?.id
        popup.move(1); settle()
        XCTAssertNotEqual(popup.selected?.id, previous)
        XCTAssertEqual(browser.files.first?.url.deletingLastPathComponent().path, popup.selected?.cwd)
        XCTAssertTrue(popup.handle(key(124, window: popup.panel)))
        let fileTable = popup.panel.firstResponder
        XCTAssertTrue(fileTable is NSTableView)
        fileTable?.keyDown(with: key(123, window: popup.panel))
        XCTAssertFalse(popup.panel.firstResponder === fileTable, "Left returns to the session list")
        XCTAssertTrue(popup.handle(key(124, window: popup.panel)))
        XCTAssertFalse(popup.handle(key(36, window: popup.panel)), "The picker must not activate a session while its files have focus")
        popup.panel.firstResponder?.keyDown(with: key(36, window: popup.panel))
        XCTAssertEqual(opened, [browser.files[0].url.path])
        XCTAssertFalse(popup.panel.isVisible)
    }

    func testFailedOpenKeepsBrowserAndAllFilesAvailable() {
        _ = NSApplication.shared
        var opened = false
        let browser = ArtifactBrowser(visibleRowLimit: 3, loader: { _, done in
            done(ArtifactSnapshot(files: (1...5).map { self.file("/project/\($0)") }))
        }, opener: { _ in false })
        browser.onOpened = { opened = true }
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = browser
        browser.show(folder: "/project"); settle()
        XCTAssertEqual(browser.files.count, 5)
        XCTAssertTrue(browser.focusFiles())
        browser.openSelected()
        XCTAssertFalse(opened)
        XCTAssertEqual(browser.files.count, 5)
    }
    func testGlobalPickerSearchIncludesOldFoldersRespectsProvidersAndOpensFiles() throws {
        _ = NSApplication.shared
        var loaded = [String](), opened = [String]()
        let browser = ArtifactBrowser(loader: { folder, done in
            loaded.append(folder); done(ArtifactSnapshot(files: [self.file(folder)]))
        }, opener: { opened.append($0.url.path); return true })
        let sessions = [Session(id: "recent", cwd: "/recent", mtime: Date().timeIntervalSince1970, title: "Current topic"),
                        Session(id: "old", cwd: "/old", mtime: 1, title: "Previous topic"),
                        Session(id: "shared", cwd: "/old", mtime: 1, title: "Same workspace"),
                        Session(id: "codex", cwd: "/excluded", mtime: 1, title: "Other provider", provider: .codex)]
        var preferences = Settings(); preferences.enabledProviders = [.claude, .codex]; preferences.providerFilter = .claude
        let popup = Popup(engine: Engine(environment: { [:] }), settings: preferences,
            loadHistory: { $0(.success(HistorySnapshot(sessions: sessions, issues: [:], installedProviders: [.claude, .codex]))) }, artifactBrowser: browser)
        popup.show(); defer { popup.hide(restoreFocus: false) }; settle()
        func fields(_ view: NSView) -> [NSSearchField] { (view as? NSSearchField).map { [$0] } ?? view.subviews.flatMap(fields) }
        let search = try XCTUnwrap(fields(popup.panel.contentView!).first)
        loaded = []; search.stringValue = "report.html"
        popup.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search)); settle()
        XCTAssertTrue(browser.isGlobalSearch); XCTAssertNil(popup.selected)
        XCTAssertEqual(Set(browser.files.map(\.url.path)), ["/recent/report.html", "/old/report.html"])
        XCTAssertEqual(loaded.filter { $0 == "/old" }.count, 1); XCTAssertFalse(loaded.contains("/excluded"))
        XCTAssertTrue(popup.handle(key(125, window: popup.panel)))
        XCTAssertTrue(popup.panel.firstResponder is NSTableView, "Down must reach file-only results")
        let find = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: popup.panel.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        XCTAssertTrue(popup.handle(find))
        XCTAssertTrue(popup.panel.firstResponder === search.currentEditor(), "Command-F returns from files to the main search")
        if let directory = ProcessInfo.processInfo.environment["CCS_UI_ARTIFACT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let view = popup.panel.contentView!; popup.panel.appearance = NSAppearance(named: appearance)
                settle()
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("global-artifact-search-" + name + ".png"))
            }
        }
        search.stringValue = ""; popup.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search)); settle()
        XCTAssertFalse(browser.isGlobalSearch); XCTAssertEqual(browser.folder, "/recent")
        search.stringValue = "old report"; popup.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search)); settle()
        XCTAssertEqual(browser.files.map(\.url.path), ["/old/report.html"])
        XCTAssertTrue(popup.handle(key(36, window: popup.panel)))
        XCTAssertEqual(opened, ["/old/report.html"]); XCTAssertFalse(popup.panel.isVisible)
    }
    func testGlobalSearchDiscardsLateResultsAfterReturningToFolderOrClosing() {
        _ = NSApplication.shared
        var requests = [(String, (ArtifactSnapshot) -> Void)]()
        let browser = ArtifactBrowser(loader: { requests.append(($0, $1)) })
        browser.showSearch(query: "report", folders: ["/a", "/b"]); settle()
        browser.show(folder: "/current"); settle()
        requests[0].1(ArtifactSnapshot(files: [file("/a")])); settle()
        XCTAssertEqual(requests.count, 2, "Cancelled global discovery must not continue to the next folder")
        requests[1].1(ArtifactSnapshot(files: [file("/current")]))
        XCTAssertEqual(browser.files.map(\.url.path), ["/current/report.html"])
        browser.showSearch(query: "report", folders: ["/late"]); settle(); browser.cancel()
        requests[2].1(ArtifactSnapshot(files: [file("/late")]))
        XCTAssertTrue(browser.files.isEmpty)
    }
    func testProgressiveFileResultsStayUnderThePointerUntilTheQueryChanges() {
        _ = NSApplication.shared
        var requests = [(String, (ArtifactSnapshot) -> Void)](), opened: URL?
        let browser = ArtifactBrowser(loader: { requests.append(($0, $1)) }, opener: { opened = $0.url; return true })
        browser.showSearch(query: "report", folders: ["/a", "/b"]); settle()
        let first = SessionArtifact(url: URL(fileURLWithPath: "/a/report.html"), relativePath: "report.html", modifiedAt: Date(timeIntervalSince1970: 1))
        let later = SessionArtifact(url: URL(fileURLWithPath: "/b/report.html"), relativePath: "report.html", modifiedAt: Date(timeIntervalSince1970: 2))
        requests[0].1(ArtifactSnapshot(files: [first])); settle()
        browser.noteInteraction()
        requests[1].1(ArtifactSnapshot(files: [later]))
        XCTAssertEqual(browser.files.map(\.url), [first.url, later.url], "A late newer result must not displace a row under the pointer")
        browser.openSelected(); XCTAssertEqual(opened, first.url)
        browser.showSearch(query: "html", folders: ["/a", "/b"]); settle()
        XCTAssertEqual(browser.files.map(\.url), [later.url, first.url], "A new query restores normal recency order")
    }
}
