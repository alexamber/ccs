import XCTest
import CCSCore
@testable import CCSApp

final class ArtifactSearchTests: XCTestCase {
    private func file(_ path: String, time: Double = 0) -> SessionArtifact {
        SessionArtifact(url: URL(fileURLWithPath: path), relativePath: URL(fileURLWithPath: path).lastPathComponent,
                        modifiedAt: Date(timeIntervalSince1970: time))
    }
    private func advance() {
        let done = expectation(description: "next folder")
        DispatchQueue.main.async { done.fulfill() }; wait(for: [done], timeout: 1)
    }
    func testQueriesReuseDiscoveryAndSharedFoldersAndFilesAreDeduplicated() {
        var requests = [(String, (ArtifactSnapshot) -> Void)](), latest: ArtifactSearchSnapshot?
        let search = ArtifactSearch(load: { requests.append(($0, $1)) })
        search.onUpdate = { latest = $0 }
        search.search("REPORT", folders: ["/a", "/a/", "/b", ""])
        XCTAssertEqual(requests.map(\.0), ["/a"])
        let a = file("/a/report.html", time: 1), b = file("/b/Łódź analysis.pdf", time: 2)
        requests[0].1(ArtifactSnapshot(files: [a])); advance()
        XCTAssertEqual(latest?.files, [a]); XCTAssertEqual(latest?.total, 2)
        search.search("łódź PDF", folders: ["/a", "/b"])
        XCTAssertEqual(requests.count, 2, "Typing must reuse the scan already in flight")
        requests[1].1(ArtifactSnapshot(files: [a, b]))
        XCTAssertEqual(latest?.files, [b]); XCTAssertEqual(latest?.searching, false)
        search.search("a", folders: ["/b", "/a"])
        XCTAssertEqual(latest?.files, [b, a]); XCTAssertEqual(requests.count, 2)
    }
    func testCancelledAndChangedScopesRejectLateFolderResults() {
        var requests = [(String, (ArtifactSnapshot) -> Void)](), latest: ArtifactSearchSnapshot?
        let search = ArtifactSearch(load: { requests.append(($0, $1)) }); search.onUpdate = { latest = $0 }
        search.search("report", folders: ["/a", "/b"])
        search.search("report", folders: ["/new"])
        requests[0].1(ArtifactSnapshot(files: [file("/a/report.html")]))
        XCTAssertTrue(latest?.files.isEmpty == true)
        requests[1].1(ArtifactSnapshot(files: [file("/new/report.html")]))
        XCTAssertEqual(latest?.files.first?.url.path, "/new/report.html")
        search.search("report", folders: ["/late", "/never"]); search.cancel()
        let before = latest?.searched
        requests[2].1(ArtifactSnapshot(files: [file("/late/report.html")])); advance()
        XCTAssertEqual(latest?.searched, before); XCTAssertEqual(requests.count, 3)
    }
    func testPartialAndBoundedDiscoveryIsExplicit() {
        var requests = [(String, (ArtifactSnapshot) -> Void)](), latest: ArtifactSearchSnapshot?
        let search = ArtifactSearch(fileLimit: 2, load: { requests.append(($0, $1)) }); search.onUpdate = { latest = $0 }
        search.search("report", folders: ["/protected", "/large", "/never"])
        requests[0].1(ArtifactSnapshot(issue: "Protected folder")); advance()
        requests[1].1(ArtifactSnapshot(files: (1...3).map { file("/large/report\($0).html") })); advance()
        XCTAssertEqual(latest?.files.count, 2); XCTAssertEqual(latest?.incompleteFolders, 1)
        XCTAssertEqual(latest?.limited, true); XCTAssertEqual(latest?.searching, false)
        XCTAssertEqual(requests.count, 2)
    }
}
