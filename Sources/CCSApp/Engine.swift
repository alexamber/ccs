import AppKit
import CCSCore
import Foundation

struct HistorySnapshot {
    let sessions: [Session]
    let issues: [Provider: String]
    let installedProviders: [Provider]
    var terminalKeys: Set<String>? = nil
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
    private let switching = Lane("switching", qos: .userInitiated)
    private let activity = Lane("activity", qos: .utility)
    private var activitySessions = [Session]()
    // Main-thread snapshots; provider connections remain confined to their lane.
    private var originGeneration = 0
    private var originRequest: DispatchWorkItem?
    private var switchGeneration = 0
    private var switchRequest: DispatchWorkItem?
    private var switchSessions = [Session]()
    private var switchSocketPath: String?
    private var metadataUpdated = Date.distantPast
    private var historyCompletions = [(Result<HistorySnapshot, Error>) -> Void]()
    private let makeService: ([String: String]) -> SessionService
    private let bootstrap = DispatchQueue(label: "io.github.alexamber.ccs.environment")
    private var environment = [String: String]()
    init(environment: @escaping () -> [String: String] = ProcessRunner.loginEnvironment,
         makeService: @escaping ([String: String]) -> SessionService = {
             SessionService(runner: ProcessRunner(environment: $0).command, codex: CodexProvider(environment: $0))
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
                                   terminalKeys: context.map { Set($0.targets.compactMap { $0.session?.key }) })
        }) { result in
            let callbacks = self.historyCompletions; self.historyCompletions = []
            callbacks.forEach { $0(result) }
        }
    }

    func loadTerminalActivity(enabledProviders: [Provider], completion: @escaping (Result<TerminalActivitySnapshot, Error>) -> Void) {
        let known = switchSessions + activitySessions.filter { session in !switchSessions.contains { $0.key == session.key } }
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
                currentKey: snapshot.context.currentKey, keysByTTY: snapshot.context.keysByTTY), unavailableProviders: snapshot.unavailableProviders)))
        }
    }
    func rememberActivity(_ session: Session) {
        activitySessions.removeAll { $0.key == session.key }; activitySessions.append(session)
    }

    func loadSwitchOrigin(completion: @escaping (Result<String?, Error>) -> Void) {
        originGeneration += 1
        let generation = originGeneration
        originRequest?.cancel()
        originRequest = perform(on: switchOrigin, { service, _ in try service.selectedTerminalTTY() }) { result in
            guard generation == self.originGeneration else { return }
            self.originRequest = nil; completion(result)
        }
    }

    func loadSwitchContext(enabledProviders: [Provider], completion: @escaping (Result<TerminalSwitchContext, Error>) -> Void) {
        switchGeneration += 1
        let generation = switchGeneration
        let stale = Date().timeIntervalSince(metadataUpdated) > 10
        switchRequest?.cancel()
        switchRequest = readSwitchContext(enabledProviders: enabledProviders) { result in
            guard generation == self.switchGeneration else { return }
            self.switchRequest = nil
            if stale, let context = try? result.get(), context.targets.isEmpty {
                // On a cold start Claude's identities may not have arrived yet.
                // Retry once after metadata rather than reporting a false empty list.
                self.loadHistory { _ in
                    guard generation == self.switchGeneration else { return }
                    self.switchRequest = self.readSwitchContext(enabledProviders: enabledProviders) { result in
                        guard generation == self.switchGeneration else { return }
                        self.switchRequest = nil; completion(result)
                    }
                }
            } else { completion(result) }
        }
        // Refresh labels for the next gesture without putting history I/O ahead
        // of keyboard input or changing the list under the current selection.
        if stale, historyCompletions.isEmpty { loadHistory { _ in } }
    }

    private func readSwitchContext(enabledProviders: [Provider], completion: @escaping (Result<TerminalSwitchContext, Error>) -> Void) -> DispatchWorkItem {
        let sessions = switchSessions.filter { enabledProviders.contains($0.provider) }
        let socketPath = switchSocketPath
        return perform(on: switching, { service, _ in
            try service.terminalSwitchContext(sessions: sessions,
                includeUnconfirmedCodex: enabledProviders.contains(.codex), codexSocketPath: socketPath)
        }, completion: completion)
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
            let socketPath = lane.service?.codex.sharedSocketPath
            DispatchQueue.main.async {
                if let metadata {
                    self.switchSessions = metadata.sessions; self.switchSocketPath = socketPath
                    self.metadataUpdated = metadata.updatedAt
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
