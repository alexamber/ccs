import AppKit
import XCTest
import CCSCore
@testable import CCSApp

final class BrowserSessionMatchTests: XCTestCase {
    func testLookupStaysOnUnicornForEmptyResultsAndDiscardsCancelledReads() throws {
        _ = NSApplication.shared
        var read: ((Result<BrowserReportPage?, Error>) -> Void)?
        var historyLoads = 0, states = [BrowserLookupIndicator]()
        let empty = HistorySnapshot(sessions: [], issues: [:], installedProviders: [], terminalTargets: [:])
        let popover = BrowserReportPopover(readPage: { read = $0 }, loadHistory: { done in
            historyLoads += 1; done(.success(empty))
        }, resolve: { _, _, _ in XCTFail("File URLs do not need a listener lookup") },
        search: ReportSearch { _, _, _ in XCTFail("Empty inventory") })
        let anchor = NSView()
        popover.onIndicator = { states.append($0) }
        popover.show(anchor: anchor)
        XCTAssertEqual(states, [.thinking]); XCTAssertFalse(popover.isShown)
        let obsolete = try XCTUnwrap(read)
        popover.close()
        popover.show(anchor: anchor)
        obsolete(.success(BrowserReportPage("file:///tmp/old.html")))
        XCTAssertEqual(historyLoads, 0)
        read?(.success(BrowserReportPage("file:///tmp/new.html")))
        XCTAssertFalse(popover.isShown); XCTAssertFalse(popover.isActive)
        XCTAssertEqual(states, [.thinking, .hidden, .thinking, .noMatch])
        popover.show(anchor: anchor)
        read?(.success(BrowserReportPage("file:///tmp/another.html")))
        XCTAssertEqual(historyLoads, 1, "Reopening still checks the current URL but reuses fresh inventory")
        popover.reset()
        popover.show(anchor: anchor)
        read?(.success(BrowserReportPage("file:///tmp/another.html")))
        XCTAssertEqual(historyLoads, 2, "Changing providers invalidates the inventory")
        popover.show(anchor: anchor)
        read?(.failure(CCSError.message("Chrome permission required")))
        XCTAssertEqual(states.last, .unavailable("Chrome permission required")); XCTAssertFalse(popover.isShown)
    }

    func testNoMatchBadgeClearsAndItsTimerCannotClearANewLookup() throws {
        _ = NSApplication.shared
        let unicorn = TerminalSessionPopup()
        unicorn.configureFloating(enabled: true, allSpaces: true)
        defer { unicorn.hide() }
        let surface = try XCTUnwrap(unicorn.panel.contentView)
        let button = try XCTUnwrap(surface.subviews.compactMap { $0 as? NSButton }.first { $0.image != nil && !$0.isHidden })
        unicorn.setBrowserLookupIndicator(.noMatch)
        XCTAssertEqual(button.toolTip, "No matching sessions")
        unicorn.setBrowserLookupIndicator(.thinking)
        let visible = surface.subviews.compactMap { $0 as? NSImageView }.filter { !$0.isHidden }
        XCTAssertTrue(visible.contains { $0.image != nil })
        if let path = ProcessInfo.processInfo.environment["CCS_UI_ARTIFACT_DIR"] {
            let dir = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (state, name) in [(BrowserLookupIndicator.thinking, "thinking"), (.noMatch, "no-match")] {
                unicorn.setBrowserLookupIndicator(state)
                surface.layoutSubtreeIfNeeded()
                let image = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
                surface.cacheDisplay(in: surface.bounds, to: image)
                try image.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
            }
            unicorn.setBrowserLookupIndicator(.thinking)
        }
        let settled = expectation(description: "brief no-match timeout")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        XCTAssertEqual(button.toolTip, "Finding sessions for this page…")
        unicorn.setBrowserLookupIndicator(.noMatch)
        let cleared = expectation(description: "badge clears")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { cleared.fulfill() }
        wait(for: [cleared], timeout: 3)
        XCTAssertNotEqual(button.toolTip, "No matching sessions")
    }

    func testShowsCompactFileMatchesOnlyAfterReferenceIsFound() throws {
        _ = NSApplication.shared
        let unicorn = TerminalSessionPopup()
        unicorn.configureFloating(enabled: true, allSpaces: true)
        defer { unicorn.hide() }
        let open = Session(id: "open", cwd: "/project", title: "Review hiring report", provider: .codex)
        let closed = Session(id: "saved", cwd: "/project", title: "Write hiring report")
        let tab = TerminalTabSnapshot(terminalID: "Terminal", paneID: "1", tty: "/dev/ttys001", bounds: .zero, title: "")
        let history = HistorySnapshot(sessions: [open, closed], issues: [:], installedProviders: [],
            terminalTargets: [open.key: TerminalSwitchTarget(session: open, tab: tab)])
        let shown = expectation(description: "matching references open the popover")
        let popover = BrowserReportPopover(readPage: { $0(.success(BrowserReportPage("file:///project/hiring.html"))) },
            loadHistory: { $0(.success(history)) }, resolve: { _, _, _ in XCTFail("Local file") },
            search: ReportSearch { session, _, done in
                done(.success([ReportReference(path: "/project/hiring.html", action: session.id == "saved" ? .created : .read)]))
            })
        defer { popover.close() }
        popover.onIndicator = { if $0 == .hidden { shown.fulfill() } }
        popover.show(anchor: unicorn.prepareSessionMenu())
        XCTAssertFalse(popover.isShown)
        XCTAssertEqual(unicorn.phase, .collapsed)
        wait(for: [shown], timeout: 3)
        popover.onIndicator = nil
        XCTAssertTrue(popover.isShown)
        XCTAssertEqual(unicorn.phase, .expanded)
        XCTAssertTrue(popover.popover.contentViewController?.view.window === unicorn.panel)
        XCTAssertLessThan(popover.popover.contentSize.height, 170)
        if let dir = ProcessInfo.processInfo.environment["CCS_UI_ARTIFACT_DIR"] {
            let expanded = expectation(description: "card has reached full size")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { expanded.fulfill() }
            wait(for: [expanded], timeout: 1)
            let view = try XCTUnwrap(unicorn.panel.contentView)
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("report-matches.png"))
        }
    }

    func testServingSessionAtRootOpensWithoutLoadingHistory() throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 200, y: 150, width: 50, height: 50), styleMask: .borderless, backing: .buffered, defer: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        let tab = TerminalTabSnapshot(terminalID: "Terminal", paneID: "1", tty: "/dev/ttys001", bounds: .zero, title: "")
        let session = Session(id: "live", cwd: "/tmp", title: "Review report")
        let target = TerminalSwitchTarget(session: session, tab: tab)
        var states = [BrowserLookupIndicator]()
        let popover = BrowserReportPopover(readPage: { $0(.success(BrowserReportPage("http://localhost:8080/"))) },
            loadHistory: { _ in XCTFail("Port-only match must not wait for history") },
            resolve: { _, targets, done in
                XCTAssertEqual(targets.map(\.key), [session.key])
                done(.success(BrowserReportSource(servingKey: session.key)))
            }, search: ReportSearch { _, _, _ in XCTFail("Port-only match should not scan transcripts") })
        popover.onIndicator = { states.append($0) }
        let recent = TerminalActivitySnapshot(context: TerminalSwitchContext(targets: [target], currentKey: nil))
        popover.show(anchor: try XCTUnwrap(panel.contentView), recent: recent)
        XCTAssertTrue(popover.isShown)
        XCTAssertEqual(states, [.thinking, .hidden])
        popover.close()
        XCTAssertFalse(popover.isActive)
    }

    func testPortOwnerFirstAndOnlyFileEvidenceCanSuggestSavedSessions() throws {
        let referenced = ["w": "/a/report.html", "r": "/a/report.html", "other": "/b/report.html",
                          "similar": "/a/report.html.pdf"]
        let sessions = ["server", "w", "r", "other", "similar"].map { Session(id: $0, cwd: "/tmp") }
        let search = ReportSearch { session, _, done in
            let files = referenced[session.id].map { [ReportReference(path: $0, action: session.id == "w" ? .created : .read)] } ?? []
            done(.success(files))
        }
        let loaded = expectation(description: "report references indexed")
        search.onUpdate = { if !search.searching { loaded.fulfill() } }
        search.search(sessions); wait(for: [loaded], timeout: 3)
        search.onUpdate = nil
        let tab = TerminalTabSnapshot(terminalID: "Terminal", paneID: "1", tty: "/dev/ttys001", bounds: .zero, title: "")
        let target = TerminalSwitchTarget(session: sessions[0], tab: tab)
        let history = HistorySnapshot(sessions: sessions, issues: [:], installedProviders: [.claude],
                                      terminalTargets: [target.key: target])
        func matches(_ address: String, file: String? = nil) throws -> [BrowserSessionMatch] {
            BrowserSessionMatch.results(page: try XCTUnwrap(BrowserReportPage(address)),
                source: BrowserReportSource(file: file, servingKey: target.key), history: history, search: search)
        }
        let exact = try matches("http://localhost:8000/report.html", file: "/a/report.html")
        XCTAssertEqual(exact.map(\.session.id), ["server", "w", "r"])
        XCTAssertNotNil(exact[0].target); XCTAssertNil(exact[1].target)
        XCTAssertTrue(exact[0].detail.hasPrefix("Serving this page"))
        XCTAssertEqual(try matches("http://localhost:8000/").map(\.id), [target.key])
        let possible = try matches("http://localhost:8000/report.html").filter { $0.reference != nil }
        XCTAssertEqual(Set(possible.map(\.session.id)), ["other", "w", "r"])
        XCTAssertTrue(possible.allSatisfy { $0.detail.hasPrefix("Possible match") })
    }
}
