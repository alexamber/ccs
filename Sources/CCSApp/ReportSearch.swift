import Foundation
import CCSCore

/// Main-thread state. A query filters paths immediately while the independent
/// history lane reads one session at a time. No transcript text is cached.
final class ReportSearch {
    typealias Loader = (Session, Operation, @escaping (Result<[ReportReference], Error>) -> Void) -> Void
    private let load: Loader
    private var entries = [String: (stamp: Double, files: [ReportReference])]()
    private var scope = [String: Double]()
    private var queue = [Session](), offset = 0
    private var ticket: Operation?
    private var scheduled: DispatchWorkItem?
    private var publication: DispatchWorkItem?
    private(set) var failed = 0
    var onUpdate: (() -> Void)?
    var searching: Bool { ticket != nil }

    init(load: @escaping Loader) { self.load = load }

    func search(_ sessions: [Session], delay: TimeInterval = 0.25) {
        let stamps = Dictionary(sessions.map { ($0.key, $0.mtime) }, uniquingKeysWith: max)
        guard stamps != scope else { return }
        // Let an in-flight pass finish when live activity changes a timestamp.
        // Its completion will enqueue changed sessions without starving older ones.
        if searching, stamps.keys == scope.keys { return }
        stop()
        scope = stamps
        queue = sessions.filter { entries[$0.key]?.stamp != $0.mtime }
        guard !queue.isEmpty else { return }
        let operation = Operation()
        ticket = operation
        let work = DispatchWorkItem { [weak self] in self?.next(operation) }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func matches(_ query: String, for session: Session) -> [ReportReference] {
        guard let entry = entries[session.key], entry.stamp == session.mtime else { return [] }
        return entry.files.filter { $0.matches(query) }
    }

    func reference(for session: Session, path: String?, name: String?) -> ReportReference? {
        guard let entry = entries[session.key], entry.stamp == session.mtime else { return nil }
        if let path { return entry.files.first { $0.path == path } }
        guard let name else { return nil }
        let suffix = "/" + name
        return entry.files.first { $0.path.hasSuffix(suffix) }
    }

    func stop() {
        ticket?.cancel(); ticket = nil
        scheduled?.cancel(); scheduled = nil
        publication?.cancel(); publication = nil
        scope.removeAll(); queue.removeAll(); offset = 0; failed = 0
    }

    private func next(_ operation: Operation) {
        guard operation === ticket else { return }
        guard offset < queue.count else {
            ticket = nil; publication?.cancel(); publication = nil; onUpdate?(); return
        }
        let session = queue[offset]; offset += 1
        load(session, operation) { [weak self] result in
            guard let self, operation === self.ticket else { return }
            switch result {
            case .success(let files): self.entries[session.key] = (session.mtime, files)
            case .failure: self.failed += 1
            }
            if self.publication == nil {
                let work = DispatchWorkItem { [weak self] in self?.publication = nil; self?.onUpdate?() }
                self.publication = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: work)
            }
            DispatchQueue.main.async { self.next(operation) }
        }
    }
}
