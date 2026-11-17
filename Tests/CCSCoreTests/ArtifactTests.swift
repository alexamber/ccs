import Foundation
import XCTest
@testable import CCSCore

final class ArtifactTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccs-artifacts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    @discardableResult private func file(_ path: String, in root: URL, date: Date = Date()) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("example".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }
    func testDiscoveryFindsDocumentsAndSkipsSourceCachesHiddenFilesAndSymlinks() throws {
        let root = try temporary(), outside = try temporary()
        for name in ["report.html", "docs/architecture.md", "research/notes/analysis.pdf", "outputs/data.csv", "plan.docx"] { try file(name, in: root) }
        for name in ["README.md", "AGENTS.md", "script.sh", ".private/report.html", "node_modules/report.html", "Sources/template.html", "build/preview.html", "research/notes/deeper/report.html", "Demo.app/report.html"] { try file(name, in: root) }
        let external = try file("external.pdf", in: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.pdf"), withDestinationURL: external)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-folder"), withDestinationURL: outside)
        let index = ArtifactIndex(usageURL: outside.appendingPathComponent("usage.json"))
        let snapshot = index.scan(folder: root.path)
        XCTAssertNil(snapshot.issue)
        XCTAssertEqual(Set(snapshot.files.map(\.relativePath)), Set(["report.html", "docs/architecture.md", "research/notes/analysis.pdf", "outputs/data.csv", "plan.docx"]))
    }
    func testUsagePersistsAndUpdatedFileKeepsOneEntry() throws {
        let root = try temporary(), state = try temporary().appendingPathComponent("usage.json"), now = Date()
        let first = try file("reports/a.html", in: root, date: now)
        let second = try file("reports/b.html", in: root, date: now)
        let index = ArtifactIndex(usageURL: state)
        let opened = try XCTUnwrap(index.scan(folder: root.path, now: now).files.first { $0.url.lastPathComponent == second.lastPathComponent })
        index.recordOpen(opened, now: now)
        let reloaded = ArtifactIndex(usageURL: state)
        let ranked = reloaded.scan(folder: root.path, now: now).files
        XCTAssertEqual(ranked.first?.name, "b.html"); XCTAssertEqual(ranked.first?.openCount, 1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: state.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data("updated contents".utf8).write(to: first)
        XCTAssertEqual(reloaded.scan(folder: root.path).files.count, 2)
        XCTAssertEqual(reloaded.scan(folder: root.path).files.filter { $0.name == "a.html" }.count, 1)
    }
    func testFreshOutputsOutrankOldFilesAndScanIsBounded() throws {
        let root = try temporary(), now = Date()
        try file("old-report.html", in: root, date: now.addingTimeInterval(-40 * 86400))
        try file("new-report.html", in: root, date: now)
        let index = ArtifactIndex(usageURL: root.appendingPathComponent("unused.json"))
        XCTAssertEqual(index.scan(folder: root.path, now: now).files.first?.name, "new-report.html")
        let limited = index.scan(folder: root.path, entryLimit: 1)
        XCTAssertLessThanOrEqual(limited.files.count, 1); XCTAssertNotNil(limited.issue)
    }
    func testInvalidFolderAndCorruptUsageDoNotBreakDiscovery() throws {
        let root = try temporary(), state = root.appendingPathComponent("usage.json")
        try Data("broken json".utf8).write(to: state)
        let index = ArtifactIndex(usageURL: state)
        for path in ["", "relative", "/", root.appendingPathComponent("missing").path] {
            let snapshot = index.scan(folder: path)
            XCTAssertTrue(snapshot.files.isEmpty); XCTAssertNotNil(snapshot.issue)
        }
        try file("Résumé — architecture.pdf", in: root)
        XCTAssertEqual(index.scan(folder: root.path).files.first?.name, "Résumé — architecture.pdf")
    }
    func testHomeProtectedAndExternalRootsAreSkippedBeforeDiscovery() throws {
        let home = try temporary()
        let index = ArtifactIndex(usageURL: home.appendingPathComponent("usage.json"), home: home.path)
        for name in ["Documents/report.html", "Desktop/report.html", "Downloads/report.html", "Library/report.html", "Pictures/report.html"] { try file(name, in: home) }
        for root in [home.path, home.deletingLastPathComponent().path, home.appendingPathComponent("Documents").path,
                     home.appendingPathComponent("Desktop/project").path, home.appendingPathComponent("Downloads").path,
                     home.appendingPathComponent("Library").path, "/Volumes/example", "/Network/example"] {
            let result = index.scan(folder: root)
            XCTAssertTrue(result.files.isEmpty); XCTAssertNotNil(result.issue)
        }
        let project = home.appendingPathComponent("work")
        try file("reports/summary.html", in: project)
        try file("Documents/private.html", in: project)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("private-link"), withDestinationURL: home.appendingPathComponent("Documents"))
        XCTAssertEqual(index.scan(folder: project.path).files.map(\.relativePath), ["reports/summary.html"])
        XCTAssertTrue(index.scan(folder: project.appendingPathComponent("private-link").path).files.isEmpty)
    }
}
