import XCTest
@testable import CCSCore

final class BrowserReportTests: XCTestCase {
    func testOnlyLocalReportsAndLoopbackRoutesAreAccepted() throws {
        let page = try XCTUnwrap(BrowserReportPage("file:///tmp/Quarter%201.html?download=1#summary"))
        XCTAssertEqual(page.path, "/tmp/Quarter 1.html")
        XCTAssertEqual(page.fileName, "Quarter 1.html")
        XCTAssertEqual(BrowserReportPage("https://[::1]/")?.port, 443)
        XCTAssertNil(BrowserReportPage("http://localhost:8000/")?.fileName)
        for url in ["file://elsewhere/tmp/a.pdf", "https://localhost.example/a.html", "file:///tmp/a.js",
                    "https://localhost@example.com/a.pdf", "http://localhost:65536/", "chrome://settings"] {
            XCTAssertNil(BrowserReportPage(url), url)
        }
    }

    func testAmbiguousAndUnrelatedListenersDoNotClaimPage() throws {
        let fields = "p10\ntIPv4\nn127.0.0.1:9000\np20\ntIPv6\nn[::1]:9000\np30\ntIPv4\nn10.0.0.1:9000\n"
        let local = try XCTUnwrap(BrowserReportPage("http://localhost:9000/"))
        XCTAssertNil(SessionService.loopbackListener(fields, page: local))
        XCTAssertEqual(SessionService.loopbackListener(fields, page: try XCTUnwrap(BrowserReportPage("http://127.0.0.1:9000/"))), 10)
        XCTAssertNil(SessionService.loopbackListener("p10\ntIPv4\nn*:9900", page: local))
    }

    func testServingOwnerAtRootAndStaticMappingAreIndependent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("index.html")
        try Data().write(to: index)
        var args = ["/some/Python.app/Contents/MacOS/Python", "-u", "-m", "http.server", "8080", "--directory", root.path]
        let service = SessionService(runner: { command, flags, _, _ in
            if command == "/bin/ps" { return CommandResult(out: "10 1\n20 10\n30 20\n") }
            if flags.contains("cwd") { return CommandResult(out: "p30\nfcwd\nn/tmp\n") }
            return CommandResult(out: "p30\ntIPv4\nn*:8080\n")
        }, arguments: { _ in args })
        let tab = TerminalTabSnapshot(terminalID: "Terminal", paneID: "1", tty: "/dev/ttys000", bounds: .zero, title: "")
        var session = Session(id: "owner", cwd: "/tmp")
        session.live = try JSONDecoder().decode(LiveSession.self, from: Data(#"{"pid":10,"sessionId":"owner"}"#.utf8))
        let target = TerminalSwitchTarget(session: session, tab: tab)
        let page = try XCTUnwrap(BrowserReportPage("http://localhost:8080/?token=private"))
        var source = service.browserReportSource(page, targets: [target])
        XCTAssertEqual(source.servingKey, session.key)
        XCTAssertEqual(source.file, index.standardizedFileURL.path)
        args = ["node", "server.js"]
        source = service.browserReportSource(page, targets: [target])
        XCTAssertNil(source.file)
        XCTAssertEqual(source.servingKey, session.key)
        XCTAssertNil(service.browserReportSource(page, targets: []).servingKey)
    }
}
