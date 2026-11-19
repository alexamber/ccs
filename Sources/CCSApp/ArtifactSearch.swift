import Foundation
import CCSCore

struct ArtifactSearchSnapshot {
    let files: [SessionArtifact]
    let searched: Int
    let total: Int
    let incompleteFolders: Int
    let limited: Bool
    let searching: Bool
}

/// Main-thread search state; discovery runs through the existing metadata-only
/// loader. Typing re-filters discovered files without restarting folder scans.
final class ArtifactSearch {
    typealias Loader = (String, @escaping (ArtifactSnapshot) -> Void) -> Void
    private let load: Loader
    private let fileLimit: Int
    private var generation = 0, offset = 0, incomplete = 0
    private var folders = [String](), discovered = [String: SessionArtifact]()
    private var terms = [String]()
    private var active = false, loading = false, limited = false
    var onUpdate: ((ArtifactSearchSnapshot) -> Void)?

    init(fileLimit: Int = 10_000, load: @escaping Loader = ArtifactService.shared.load) {
        self.fileLimit = fileLimit; self.load = load
    }
    func search(_ query: String, folders values: [String]) {
        let nextTerms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !nextTerms.isEmpty else { cancel(); return }
        var seen = Set<String>()
        let nextFolders = values.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { seen.insert($0).inserted }
        let changed = !active || Set(nextFolders) != Set(folders)
        if changed {
            cancel(); folders = nextFolders; discovered = [:]; offset = 0; incomplete = 0; limited = false
            active = true
        }
        terms = nextTerms
        publish()
        if changed { next(generation) }
    }
    func cancel() { generation += 1; active = false; loading = false }

    private func next(_ revision: Int) {
        guard active, generation == revision, !loading, offset < folders.count, !limited else { return }
        loading = true
        load(folders[offset]) { [weak self] snapshot in
            guard let self, self.active, revision == self.generation else { return }
            self.loading = false; self.offset += 1
            if snapshot.issue != nil { self.incomplete += 1 }
            for file in snapshot.files {
                if self.discovered[file.url.path] == nil, self.discovered.count >= self.fileLimit {
                    self.limited = true; break
                }
                self.discovered[file.url.path] = file
            }
            self.publish()
            // Yield even for an immediate cache/fake response; never recurse
            // through hundreds of folders or monopolize keyboard handling.
            DispatchQueue.main.async { [weak self] in self?.next(revision) }
        }
    }
    private func publish() {
        let matches = discovered.values.filter { file in terms.allSatisfy { file.url.path.localizedStandardContains($0) } }
            .sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
            }
        onUpdate?(ArtifactSearchSnapshot(files: Array(matches.prefix(200)), searched: offset, total: folders.count,
            incompleteFolders: incomplete, limited: limited || matches.count > 200,
            searching: offset < folders.count && !limited))
    }
}
