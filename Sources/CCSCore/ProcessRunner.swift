import Foundation
import Darwin

public struct CommandResult {
    public var code: Int32
    public var out: String
    public var err: String
    public init(code: Int32 = 0, out: String = "", err: String = "") {
        self.code = code; self.out = out; self.err = err
    }
}

public typealias CommandRunner = (_ executable: String, _ arguments: [String], _ input: String?, _ timeout: Double) throws -> CommandResult

public final class ProcessRunner {
    public let environment: [String: String]
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) { self.environment = environment }

    public func run(_ executable: String, _ arguments: [String] = [], input: String? = nil,
                    timeout: Double = 15) throws -> CommandResult {
        let process = Process(), stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.environment = environment
        process.standardOutput = stdout; process.standardError = stderr; process.standardInput = stdin
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        // Drain both pipes concurrently: transcripts and large process listings can fill a pipe.
        let group = DispatchGroup()
        var out = Data(), err = Data()
        group.enter(); DispatchQueue.global().async { out = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { err = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            throw CCSError.message("\(URL(fileURLWithPath: executable).lastPathComponent) timed out. Try again.")
        }
        guard group.wait(timeout: .now() + 2) == .success else {
            throw CCSError.message("The command left its output open. Try again.")
        }
        return CommandResult(code: process.terminationStatus,
                             out: String(decoding: out, as: UTF8.self), err: String(decoding: err, as: UTF8.self))
    }

    public var command: CommandRunner { { try self.run($0, $1, input: $2, timeout: $3) } }

    public static func loginEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let probe = "printf '\\036CCS\\000%s\\000%s\\000%s\\000' \"$PATH\" \"$CCS_NEW_DIR\" \"$CODEX_HOME\""
        if let result = try? ProcessRunner(environment: env).run(shell, ["-l", "-i", "-c", probe], timeout: 10),
           let marker = result.out.range(of: "\u{1e}CCS\0") {
            let parts = result.out[marker.upperBound...].split(separator: "\0", omittingEmptySubsequences: false)
            if parts.count >= 3 {
                env["PATH"] = String(parts[0]); env["CCS_NEW_DIR"] = String(parts[1])
                env["CODEX_HOME"] = parts[2].isEmpty ? nil : String(parts[2])
            }
        }
        return env
    }
}

public func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
