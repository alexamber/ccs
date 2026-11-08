import AppKit
import CCSCore
import Foundation

struct HistorySnapshot {
    let sessions: [Session]
    let issues: [Provider: String]
    let installedProviders: [Provider]
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
    private let bootstrap = DispatchQueue(label: "io.github.alexamber.ccs.environment")
    private var environment = [String: String]()
    init(environment: @escaping () -> [String: String] = ProcessRunner.loginEnvironment) {
        bootstrap.async { self.environment = environment() }
    }

    func loadHistory(completion: @escaping (Result<HistorySnapshot, Error>) -> Void) {
        perform(background: true, { service, env in
            let enabled = Settings.load().resolvingProviders(environment: env).enabledProviders
            let sessions = try service.collect(days: 0, provider: .all, enabledProviders: enabled)
            return HistorySnapshot(sessions: sessions, issues: service.issues,
                                   installedProviders: enabled.filter { $0.isInstalled(environment: env) })
        }, completion: completion)
    }

    func perform<T>(background: Bool = false, _ work: @escaping (SessionService, [String: String]) throws -> T,
                    completion: @escaping (Result<T, Error>) -> Void) {
        let lane = background ? self.background : foreground
        lane.queue.async {
            let environment = self.bootstrap.sync { self.environment }
            if lane.service == nil {
                lane.service = SessionService(runner: ProcessRunner(environment: environment).command,
                                              codex: CodexProvider(environment: environment))
            }
            let result = Result { try work(lane.service!, environment) }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

func showError(_ error: Error, window: NSWindow? = nil) {
    let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "CCS couldn’t complete that action"
    alert.informativeText = error.localizedDescription; alert.addButton(withTitle: "OK")
    if let window, window.isVisible { alert.beginSheetModal(for: window) }
    else { NSApp.activate(ignoringOtherApps: true); alert.runModal() }
}
