import AppKit
import CCSCore
import XCTest
@testable import CCSApp

final class ArtifactBrowserTests: XCTestCase {
    private func settle() {
        let done = expectation(description: "UI queue settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }
    private func file(_ folder: String) -> SessionArtifact {
        SessionArtifact(url: URL(fileURLWithPath: folder + "/report.html"), relativePath: "report.html", modifiedAt: Date())
    }
    private func key(_ code: UInt16, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
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
}
