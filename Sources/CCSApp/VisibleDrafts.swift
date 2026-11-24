import Foundation
import CCSCore

/// Owned by the visible picker. The automation helper returns identifiers only.
final class VisibleDrafts {
    typealias Loader = ([TerminalSwitchTarget], @escaping (Set<String>) -> Void) -> Void
    private var revision = 0
    private var loading = false
    private let load: Loader
    private struct TabIdentity: Equatable {
        let tty: String
        let title: String
    }
    private var scope = [String: TabIdentity]()
    private var lastCheck = Date.distantPast
    private(set) var keys = Set<String>()
    var onUpdate: (() -> Void)?

    init(load: @escaping Loader = VisibleDrafts.read) { self.load = load }

    func clear() {
        revision += 1; scope.removeAll(); keys.removeAll(); loading = false; lastCheck = .distantPast
    }
    func check(_ targets: [TerminalSwitchTarget]) {
        let known = targets.filter { $0.session != nil && $0.tab.terminalID == "com.apple.Terminal" }
        let next = Dictionary(known.map { ($0.key, TabIdentity(tty: $0.tab.tty, title: $0.tab.title)) },
                              uniquingKeysWith: { a, _ in a })
        if scope != next {
            keys = keys.filter { next[$0] != nil && next[$0] == scope[$0] }
            revision += 1; scope = next; loading = false; lastCheck = .distantPast
        }
        guard !known.isEmpty, !loading, Date().timeIntervalSince(lastCheck) >= 3 else { return }
        loading = true; lastCheck = Date()
        let request = revision
        load(known) { [weak self] result in
            guard let self, self.revision == request else { return }
            self.loading = false
            guard result != self.keys else { return }
            self.keys = result; self.onUpdate?()
        }
    }
    private static func read(_ targets: [TerminalSwitchTarget], completion: @escaping (Set<String>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let input = targets.compactMap { target -> [String: String]? in
                guard let session = target.session else { return nil }
                return ["key": target.key, "tty": target.tab.tty, "title": target.tab.title, "provider": session.provider.rawValue]
            }
            var keys = Set<String>()
            if let url = Bundle.main.url(forResource: "VisibleDraft", withExtension: "js") ?? Bundle.module.url(forResource: "VisibleDraft", withExtension: "js"),
               let data = try? JSONEncoder().encode(input),
               let result = try? ProcessRunner().run("/usr/bin/osascript", ["-l", "JavaScript", url.path, String(decoding: data, as: UTF8.self)], timeout: 4),
               result.code == 0, let found = try? JSONDecoder().decode([String].self, from: Data(result.out.utf8)) { keys = Set(found) }
            DispatchQueue.main.async { completion(keys) }
        }
    }
}
