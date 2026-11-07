import CCSCore
import AppKit
import Foundation

final class Engine {
    private let queue = DispatchQueue(label: "io.github.alexamber.ccs.engine", qos: .userInitiated)
    private var service: SessionService!
    private var environment = [String: String]()
    init() {
        queue.async {
            self.environment = ProcessRunner.loginEnvironment()
            self.service = SessionService(runner: ProcessRunner(environment: self.environment).command)
        }
    }
    func perform<T>(_ work: @escaping (SessionService, [String: String]) throws -> T,
                    completion: @escaping (Result<T, Error>) -> Void) {
        queue.async {
            let result = Result { try work(self.service, self.environment) }
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
