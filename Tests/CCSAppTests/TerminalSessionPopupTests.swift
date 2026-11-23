import AppKit
import CCSCore
import XCTest
@testable import CCSApp

final class TerminalSessionPopupTests: XCTestCase {
    func testMonitorRetriesUnmatchedTabAndRecognizesTopicChangeWithoutSpinnerRefreshes() {
        _ = NSApplication.shared
        var clock = Date(), topic = "Topic", requests = 0, shown = 0, available = false
        let monitor = TerminalSessionMonitor(frontmost: { true }, now: { clock }, readTab: { done in
            done(TerminalTabSnapshot(output: "/dev/ttys001\n0\n0\n900\n600\n" + topic))
        }, loadSession: { _, done in
            requests += 1
            done(available ? Session(id: "a", cwd: "/tmp", title: topic) : nil)
        }, show: { _, _ in shown += 1 }, hide: { _ in })
        monitor.configure(enabled: true)
        defer { monitor.configure(enabled: false) }
        XCTAssertEqual(requests, 1)
        clock.addTimeInterval(4); monitor.tick(); XCTAssertEqual(requests, 1)
        available = true; clock.addTimeInterval(1); monitor.tick()
        XCTAssertEqual(requests, 2); XCTAssertEqual(shown, 1)
        topic = "⠼ Topic"; monitor.tick()
        topic = "⠋ Topic"; monitor.tick()
        topic = "[ ! ] Action Required | Topic"; monitor.tick()
        topic = "[ . ] Action Required | Topic"; monitor.tick()
        topic = "● [ ! ] Action Required | Topic"; monitor.tick()
        topic = "Topic"; monitor.tick()
        XCTAssertEqual(requests, 2, "Activity animation must not trigger metadata loads")
        topic = "Another topic"; monitor.tick()
        XCTAssertEqual(requests, 3); XCTAssertEqual(shown, 2)
    }

    private func tab(_ number: Int) -> TerminalTabSnapshot {
        TerminalTabSnapshot(output: "/dev/ttys00\(number)\n0\n0\n900\n600")!
    }

    func testMonitorOnlyPollsWhenEnabledAndTerminalIsFrontmost() {
        _ = NSApplication.shared
        var front = false, reads = 0, shown = 0
        var response: ((TerminalTabSnapshot?) -> Void)?
        let monitor = TerminalSessionMonitor(frontmost: { front }, readTab: { reads += 1; response = $0 },
                                             loadSession: { _, done in done(nil) }, show: { _, _ in shown += 1 }, hide: { _ in })
        monitor.tick(); XCTAssertEqual(reads, 0)
        monitor.configure(enabled: true); XCTAssertEqual(reads, 0)
        front = true; monitor.updateActivity(); XCTAssertEqual(reads, 1)
        monitor.tick(); XCTAssertEqual(reads, 1, "Do not overlap AppleScript reads")
        front = false; monitor.updateActivity()
        response?(tab(1)); XCTAssertEqual(shown, 0)
        monitor.tick(); XCTAssertEqual(reads, 1)
        front = true; monitor.updateActivity(); XCTAssertEqual(reads, 2)
        monitor.configure(enabled: false)
        response?(tab(1)); monitor.tick(); XCTAssertEqual(reads, 2)
    }

    func testTabChangesLoadOnceAndDiscardOutdatedMetadata() {
        _ = NSApplication.shared
        var selected: TerminalTabSnapshot? = tab(1)
        var requests = [(String, (Session?) -> Void)](), shown = [String](), hides = 0
        let monitor = TerminalSessionMonitor(frontmost: { true }, readTab: { $0(selected) },
                                             loadSession: { requests.append(($0.tty, $1)) },
                                             show: { _, tab in shown.append(tab.tty) }, hide: { _ in hides += 1 })
        monitor.configure(enabled: true)
        defer { monitor.configure(enabled: false) }
        XCTAssertEqual(requests.count, 1)
        monitor.tick(); monitor.tick(); XCTAssertEqual(requests.count, 1)
        selected = tab(2); monitor.tick()
        selected = tab(3); monitor.tick()
        XCTAssertEqual(requests.count, 1, "Coalesce metadata requests while one is in flight")
        let session = Session(id: "abc", cwd: "/tmp/work", title: "A session")
        requests[0].1(session)
        XCTAssertTrue(shown.isEmpty, "An old tab must not flash a late popup")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].0, "/dev/ttys003")
        requests[1].1(session)
        XCTAssertEqual(shown, ["/dev/ttys003"])
        monitor.tick(); XCTAssertEqual(requests.count, 2)
        let before = hides
        selected = nil; monitor.tick()
        XCTAssertGreaterThan(hides, before)
        selected = tab(2); monitor.tick()
        requests[2].1(nil)
        XCTAssertEqual(shown.count, 1, "Unknown tabs have no popup")
        selected = tab(1); monitor.tick()
        monitor.configure(enabled: false)
        requests[3].1(session)
        XCTAssertEqual(shown.count, 1, "Turning off the feature invalidates pending metadata")
    }

    func testLeavingTerminalInvalidatesPendingSession() {
        _ = NSApplication.shared
        var front = true, shown = false
        var completion: ((Session?) -> Void)?
        let snapshot = tab(1)
        let monitor = TerminalSessionMonitor(frontmost: { front }, readTab: { $0(snapshot) },
                                             loadSession: { _, done in completion = done }, show: { _, _ in shown = true }, hide: { _ in })
        monitor.configure(enabled: true)
        defer { monitor.configure(enabled: false) }
        front = false; monitor.updateActivity()
        completion?(Session(id: "abc", cwd: "/tmp"))
        XCTAssertFalse(shown)
    }

    func testContextRestoresQuietlyAfterAppSpaceAndReadChanges() {
        _ = NSApplication.shared
        var front = true, selected: TerminalTabSnapshot? = tab(1), resolved = 0
        let popup = TerminalSessionPopup()
        popup.configureFloating(enabled: true, allSpaces: true)
        let monitor = TerminalSessionMonitor(frontmost: { front }, readTab: { $0(selected) },
            loadSession: { _, done in done(Session(id: "a", cwd: "/tmp", title: "Topic")) },
            show: { session, tab in resolved += 1; popup.show(session, tab: tab) },
            hide: { popup.contextEnded($0) })
        monitor.configure(enabled: true)
        defer { monitor.configure(enabled: false); popup.hide() }
        XCTAssertEqual(resolved, 1); XCTAssertEqual(popup.phase, .collapsed)
        front = false; monitor.updateActivity()
        front = true; monitor.updateActivity()
        monitor.spaceChanged()
        XCTAssertEqual(resolved, 3); XCTAssertEqual(popup.phase, .collapsed)
        monitor.configure(enabled: true)
        XCTAssertEqual(resolved, 3, "Unrelated settings must not reload context")
        selected = tab(3); monitor.spaceChanged()
        selected = tab(2); monitor.tick()
        XCTAssertEqual(resolved, 5); XCTAssertEqual(popup.phase, .collapsed)
        selected = nil; monitor.tick()
        selected = tab(2); monitor.tick()
        XCTAssertEqual(resolved, 6); XCTAssertEqual(popup.phase, .collapsed)
        selected = TerminalTabSnapshot(output: "/dev/ttys002\n0\n0\n900\n600\nNew topic")!
        monitor.tick(); XCTAssertEqual(resolved, 7)
        selected = TerminalTabSnapshot(output: "/dev/ttys002\n0\n0\n900\n600\n⠼ New topic")!
        monitor.tick(); XCTAssertEqual(resolved, 7)
        XCTAssertEqual(popup.phase, .collapsed, "Only hovering may reveal the name")
    }

    func testHoverPeeksAtNameWithoutFilesOrFocusAndLeavingCollapses() {
        _ = NSApplication.shared
        var scans = 0
        let popup = TerminalSessionPopup(artifactBrowser: ArtifactBrowser(showLocation: false, visibleRowLimit: 5, loader: { _, done in
            scans += 1; done(ArtifactSnapshot())
        }))
        defer { popup.hide() }
        popup.show(Session(id: "a", cwd: "/tmp", title: "Topic"), tab: tab(1))
        popup.collapse(restoreFocus: false); settle()
        popup.setHovering(false)
        popup.setHovering(true); popup.setHovering(false); settle()
        XCTAssertEqual(popup.phase, .collapsed, "A passing pointer must not flash the name")
        popup.setHovering(true); settle()
        XCTAssertEqual(popup.phase, .title)
        XCTAssertFalse(popup.panel.canBecomeKey)
        XCTAssertFalse(popup.panel.isKeyWindow)
        XCTAssertEqual(scans, 0, "Hover must not enumerate files")
        popup.setHovering(false)
        XCTAssertEqual(popup.phase, .collapsed, "Mouse exit starts collapse immediately")
        settle()
        popup.expand(); popup.setHovering(true); popup.setHovering(false)
        XCTAssertEqual(popup.phase, .expanded, "Click-opened files remain available after mouse exit")
        popup.contextEnded(.spaceChanged)
        XCTAssertEqual(popup.phase, .collapsed)
        XCTAssertFalse(popup.panel.canBecomeKey)
        popup.show(Session(id: "a", cwd: "/tmp", title: "Topic"), tab: tab(1))
        XCTAssertEqual(popup.phase, .collapsed, "A quiet restore must not replay the title")
    }

    func testPopupCannotStealFocusButAcceptsArtifactClicks() throws {
        _ = NSApplication.shared
        let browser = ArtifactBrowser(showLocation: false, visibleRowLimit: 5, loader: { folder, done in
            done(ArtifactSnapshot(files: ["Authentication report.html", "Architecture notes.md", "Test results.pdf"].map {
                SessionArtifact(url: URL(fileURLWithPath: folder).appendingPathComponent($0), relativePath: $0, modifiedAt: Date())
            }))
        })
        let popup = TerminalSessionPopup(artifactBrowser: browser)
        XCTAssertFalse(popup.panel.canBecomeKey)
        XCTAssertFalse(popup.panel.canBecomeMain)
        XCTAssertFalse(popup.panel.ignoresMouseEvents)
        XCTAssertFalse(popup.panel.hidesOnDeactivate)
        XCTAssertTrue(popup.panel.styleMask.contains(.nonactivatingPanel))
        var session = Session(id: "abc", cwd: "/Users/example/projects/customer-portal/services/authentication", title: "Fix authentication redirects after signing in with a different account", turns: 12)
        session.live = try JSONDecoder().decode(LiveSession.self, from: Data("{\"sessionId\":\"abc\"}".utf8))
        session.status = "idle"
        popup.show(session, tab: tab(1))
        defer { popup.hide() }
        let anchor = NSPoint(x: popup.panel.frame.maxX, y: popup.panel.frame.maxY)
        popup.setHovering(true); settle()
        try capture(popup, name: "title-bubble")
        XCTAssertEqual(popup.phase, .title)
        XCTAssertTrue(browser.files.isEmpty, "The title bubble does not scan files")
        XCTAssertFalse(popup.panel.isKeyWindow)
        popup.collapse(restoreFocus: false)
        settle()
        XCTAssertEqual(popup.phase, .collapsed)
        XCTAssertEqual(popup.panel.frame.width, 56)
        XCTAssertEqual(popup.panel.frame.maxX, anchor.x, accuracy: 1)
        XCTAssertEqual(popup.panel.frame.maxY, anchor.y, accuracy: 1)
        try capture(popup, name: "collapsed-bubble")
        popup.expand()
        XCTAssertEqual(popup.phase, .expanded)
        XCTAssertTrue(popup.panel.canBecomeKey)
        XCTAssertTrue(popup.filePopover.isShown)
        let loaded = expectation(description: "file list loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { loaded.fulfill() }
        wait(for: [loaded], timeout: 2)
        XCTAssertEqual(browser.files.count, 3)
        XCTAssertFalse(popup.panel.isMainWindow)
        XCTAssertTrue(popup.panel.isVisible)
        XCTAssertLessThan(popup.filePopover.contentSize.height, 400, "The panel should fit three files without a large blank area")
        XCTAssertEqual(popup.panel.frame.width, popup.filePopover.contentSize.width, accuracy: 1)
        let filesFrame = browser.convert(browser.bounds, to: popup.panel.contentView)
        XCTAssertEqual(filesFrame.minX, popup.panel.frame.width - filesFrame.maxX, accuracy: 1)
        try capture(popup, name: "terminal-popup")
        popup.contextEnded(.disabled)
        XCTAssertFalse(popup.panel.isVisible)
        XCTAssertTrue(browser.files.count == 3)
    }

    func testClickDuringTitleAnimationImmediatelyOpensFiles() throws {
        _ = NSApplication.shared
        let popup = TerminalSessionPopup(artifactBrowser: ArtifactBrowser(showLocation: false, visibleRowLimit: 5, loader: { _, done in done(ArtifactSnapshot()) }))
        defer { popup.hide() }
        popup.show(Session(id: "a", cwd: "/tmp", title: "Topic"), tab: tab(1))
        popup.collapse(restoreFocus: false); settle()
        popup.show(Session(id: "b", cwd: "/tmp/other", title: "Other topic"), tab: tab(2))
        popup.setHovering(true)
        let hover = expectation(description: "hover starts title animation")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { hover.fulfill() }
        wait(for: [hover], timeout: 1)
        let mark = try XCTUnwrap(popup.panel.contentView?.subviews.compactMap { $0 as? NSButton }.first { $0.image != nil })
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: mark.convert(NSPoint(x: 18, y: 18), to: nil), modifierFlags: [], timestamp: 0,
                                                   windowNumber: popup.panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertTrue(mark.acceptsFirstMouse(for: event))
        mark.performClick(nil)
        XCTAssertEqual(popup.phase, .expanded)
        XCTAssertTrue(popup.artifactBrowser.window === popup.panel, "Files appear inside the launcher")
        XCTAssertTrue(popup.filePopover.isShown)
        settle(); XCTAssertEqual(popup.phase, .expanded, "The old animation must not collapse the file menu later")
    }

    func testBubbleFolderActionOpensItsSessionDirectory() {
        _ = NSApplication.shared
        var opened: URL?
        let button = FolderButton(opener: { opened = $0; return true })
        let popup = TerminalSessionPopup(artifactBrowser: ArtifactBrowser(showLocation: false, visibleRowLimit: 5, loader: { _, done in done(ArtifactSnapshot()) }), folderButton: button)
        defer { popup.hide() }
        popup.show(Session(id: "a", cwd: "/tmp/workspace", title: "Topic"), tab: tab(1))
        popup.expand(); button.openFolder()
        XCTAssertEqual(opened?.path, "/tmp/workspace")
        XCTAssertEqual(popup.phase, .collapsed)
    }

    func testSwitchingFromFilesToSessionsKeepsTheSameAnchor() {
        _ = NSApplication.shared
        let popup = TerminalSessionPopup(artifactBrowser: ArtifactBrowser(loader: { _, done in done(ArtifactSnapshot()) }))
        popup.configureFloating(enabled: true, allSpaces: true)
        defer { popup.hide() }
        popup.show(Session(id: "a", cwd: "/tmp", title: "Small topic"), tab: tab(1))
        let compact = popup.panel.frame
        popup.expand()
        XCTAssertTrue(popup.filePopover.isShown)
        settle()
        XCTAssertGreaterThan(popup.panel.frame.width, compact.width)
        XCTAssertTrue(popup.artifactBrowser.window === popup.panel)
        let anchor = popup.prepareSessionMenu()
        XCTAssertFalse(popup.filePopover.isShown)
        XCTAssertEqual(anchor.window, popup.panel)
        XCTAssertEqual(popup.panel.frame, compact)
    }

    private func settle() {
        let done = expectation(description: "animation settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 1)
    }

    func testBrandIconsHaveTransparentBackgroundsAndRenderAtMenuSize() throws {
        _ = NSApplication.shared
        let preview = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 48))
        preview.wantsLayer = true; preview.layer?.backgroundColor = NSColor.white.cgColor
        preview.appearance = NSAppearance(named: .aqua)
        for (index, template) in [false, true].enumerated() {
            let icon = BrandIcon.image(template: template, size: template ? 18 : 24)
            XCTAssertEqual(icon.isTemplate, template)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(icon.tiffRepresentation)))
            XCTAssertTrue(bitmap.hasAlpha)
            XCTAssertGreaterThan(bitmap.pixelsWide, 100, "Load the bundled artwork, not the symbol fallback")
            XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0.01)
            let image = NSImageView(image: icon)
            image.frame = NSRect(x: 20 + index * 55, y: 12, width: template ? 18 : 24, height: 24)
            preview.addSubview(image)
        }
        if let directory = ProcessInfo.processInfo.environment["CCS_UI_ARTIFACT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
            preview.cacheDisplay(in: preview.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("brand-icons.png"))
        }
    }

    private func capture(_ popup: TerminalSessionPopup, name prefix: String) throws {
        if let directory = ProcessInfo.processInfo.environment["CCS_UI_ARTIFACT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let view = try XCTUnwrap(popup.panel.contentView)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                view.appearance = NSAppearance(named: appearance)
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(prefix)-\(name).png"))
            }
        }
    }
}
