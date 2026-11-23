import AppKit
import CCSCore
import Foundation

struct HistorySnapshot {
    let sessions: [Session]
    let issues: [Provider: String]
    let installedProviders: [Provider]
    var terminalTargets: [String: TerminalSwitchTarget]? = nil
    var terminalInventoryComplete = true
}

final class Engine {
    // Each lane owns its service and RPC connection. A history refresh cannot
    // queue ahead of opening a session, and concurrent RPC reads never interleave.
    private final class Lane {
        let queue: DispatchQueue
        var service: SessionService?
        init(_ name: String, qos: DispatchQoS) { queue = DispatchQueue(label: "io.github.alexamber.ccs." + name, qos: qos) }
    }
    private let foreground = Lane("actions", qos: .userInitiated)
    private let background = Lane("history", qos: .utility)
    private let switchOrigin = Lane("switch-origin", qos: .userInitiated)
    private let reports = Lane("report-history", qos: .utility)
    private let activity = Lane("activity", qos: .utility)
    private var activitySessions = [Session]()
    // Main-thread snapshots; provider connections remain confined to their lane.
    private var originGeneration = 0
    private var originRequest: DispatchWorkItem?
    private var historySessions = [Session]()
    private var historyCompletions = [(Result<HistorySnapshot, Error>) -> Void]()
    private let makeService: ([String: String]) -> SessionService
    private let bootstrap = DispatchQueue(label: "io.github.alexamber.ccs.environment")
    private var environment = [String: String]()
    init(environment: @escaping () -> [String: String] = ProcessRunner.loginEnvironment,
         makeService: @escaping ([String: String]) -> SessionService = {
             SessionService(runner: ProcessRunner(environment: $0).command, codex: CodexProvider(environment: $0), environment: $0)
         }) {
        self.makeService = makeService
        bootstrap.async { self.environment = environment() }
    }

    func loadHistory(completion: @escaping (Result<HistorySnapshot, Error>) -> Void) {
        historyCompletions.append(completion)
        guard historyCompletions.count == 1 else { return }
        perform(background: true, { service, env in
            let enabled = Settings.load().resolvingProviders(environment: env).enabledProviders
            let sessions = try service.collect(days: 0, provider: .all, enabledProviders: enabled)
            let context = try? service.terminalSwitchContext(sessions: sessions, includeUnconfirmedCodex: false)
            return HistorySnapshot(sessions: sessions, issues: service.issues,
                                   installedProviders: enabled.filter { $0.isInstalled(environment: env) },
                                   terminalTargets: context.map { Dictionary(uniqueKeysWithValues: $0.targets.map { ($0.key, $0) }) },
                                   terminalInventoryComplete: context?.isComplete == true)
        }) { result in
            let callbacks = self.historyCompletions; self.historyCompletions = []
            callbacks.forEach { $0(result) }
        }
    }

    func loadTerminalActivity(enabledProviders: [Provider], completion: @escaping (Result<TerminalActivitySnapshot, Error>) -> Void) {
        let known = historySessions + activitySessions.filter { session in !historySessions.contains { $0.key == session.key } }
        perform(on: activity, { service, _ in
            try service.terminalActivity(known: known, enabledProviders: enabledProviders)
        }) { result in
            guard case .success(let snapshot) = result else { completion(result); return }
            let previous = Dictionary(self.activitySessions.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let targets = snapshot.context.targets.map { target -> TerminalSwitchTarget in
                guard var session = target.session, session.provider == .claude, let old = previous[session.key] else { return target }
                // Claude's live list has a start time, not a last-activity time.
                // Preserve history recency and advance it on observed state changes.
                session.mtime = max(session.mtime, old.mtime)
                if session.status != old.status, SessionActivity(status: session.status) != .unknown,
                   SessionActivity(status: old.status) != .unknown { session.mtime = Date().timeIntervalSince1970 }
                return TerminalSwitchTarget(session: session, tab: target.tab, processID: target.processID)
            }
            self.activitySessions = targets.compactMap(\.session)
            completion(.success(TerminalActivitySnapshot(context: TerminalSwitchContext(targets: targets,
                currentKey: snapshot.context.currentKey, keysByTTY: snapshot.context.keysByTTY,
                isComplete: snapshot.context.isComplete), unavailableProviders: snapshot.unavailableProviders)))
        }
    }
    func loadReportReferences(_ session: Session, operation: Operation, completion: @escaping (Result<[ReportReference], Error>) -> Void) {
        perform(on: reports, { service, _ in
            if operation.isCancelled { throw CancellationError() }
            return try service.reportReferences(for: session, cancelled: { operation.isCancelled })
        }, completion: completion)
    }

    func rememberActivity(_ session: Session) {
        activitySessions.removeAll { $0.key == session.key }; activitySessions.append(session)
    }

    func loadSwitchOrigin(terminalID: String, completion: @escaping (Result<String?, Error>) -> Void) {
        originGeneration += 1
        let generation = originGeneration
        originRequest?.cancel()
        originRequest = perform(on: switchOrigin, { service, _ in try service.selectedTerminalTTY(in: terminalID) }) { result in
            guard generation == self.originGeneration else { return }
            self.originRequest = nil; completion(result)
        }
    }

    func perform<T>(background: Bool = false, _ work: @escaping (SessionService, [String: String]) throws -> T,
                    completion: @escaping (Result<T, Error>) -> Void) {
        perform(on: background ? self.background : foreground, work, completion: completion)
    }

    @discardableResult
    private func perform<T>(on lane: Lane, _ work: @escaping (SessionService, [String: String]) throws -> T,
                            completion: @escaping (Result<T, Error>) -> Void) -> DispatchWorkItem {
        let request = DispatchWorkItem {
            let environment = self.bootstrap.sync { self.environment }
            if lane.service == nil {
                lane.service = self.makeService(environment)
            }
            let result = Result { try work(lane.service!, environment) }
            let metadata = lane === self.background ? lane.service?.cachedTerminalMetadata : nil
            DispatchQueue.main.async {
                if let metadata {
                    self.historySessions = metadata.sessions
                }
                completion(result)
            }
        }
        lane.queue.async(execute: request)
        return request
    }
}

func showError(_ error: Error, window: NSWindow? = nil) {
    let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "CCS couldn’t complete that action"
    alert.informativeText = error.localizedDescription; alert.addButton(withTitle: "OK")
    if let window, window.isVisible { alert.beginSheetModal(for: window) }
    else { NSApp.activate(ignoringOtherApps: true); alert.runModal() }
}
