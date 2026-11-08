import Foundation
import Darwin
import CryptoKit

protocol CodexConnection: AnyObject {
    var isShared: Bool { get }
    func request(_ method: String, _ params: [String: Any]) throws -> [String: Any]
    func close()
}

private let codexTransportError = CCSError.message("Could not read the local Codex server. Update Codex or retry.")

/// Bounded, synchronous I/O; callers use the engine's background queue.
final class CodexByteStream {
    let input: Int32, output: Int32
    private var buffered = Data()
    private var cleanup: (() -> Void)?
    init(input: Int32, output: Int32, cleanup: @escaping () -> Void) {
        self.input = input; self.output = output; self.cleanup = cleanup
        _ = fcntl(input, F_SETFL, fcntl(input, F_GETFL) | O_NONBLOCK)
        _ = fcntl(output, F_SETFL, fcntl(output, F_GETFL) | O_NONBLOCK)
        _ = fcntl(output, F_SETNOSIGPIPE, 1)
    }
    func close() { let action = cleanup; cleanup = nil; action?() }
    deinit { close() }
    private func wait(_ fd: Int32, _ events: Int16, until deadline: Date) throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw codexTransportError }
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, 10_000)))
        if result < 0 && errno == EINTR { return try wait(fd, events, until: deadline) }
        guard result > 0, descriptor.revents & Int16(POLLNVAL | POLLERR) == 0 else { throw codexTransportError }
    }
    func write(_ data: Data, until deadline: Date) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                try wait(output, Int16(POLLOUT), until: deadline)
                let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
                guard count > 0 else { throw codexTransportError }; offset += count
            }
        }
    }
    func read(_ count: Int, until deadline: Date) throws -> Data {
        guard count >= 0, count <= 16 * 1024 * 1024 else { throw codexTransportError }
        while buffered.count < count {
            try wait(input, Int16(POLLIN), until: deadline)
            var bytes = [UInt8](repeating: 0, count: 65536)
            let received = Darwin.read(input, &bytes, bytes.count)
            if received < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard received > 0 else { throw codexTransportError }
            buffered.append(contentsOf: bytes.prefix(received))
            guard buffered.count <= 17 * 1024 * 1024 else { throw codexTransportError }
        }
        let result = Data(buffered.prefix(count)); buffered.removeFirst(count); return result
    }
    func line(until deadline: Date) throws -> Data {
        var line = Data()
        while line.count < 16 * 1024 * 1024 {
            if let end = buffered.firstIndex(of: 10) {
                let count = buffered.distance(from: buffered.startIndex, to: end)
                line.append(buffered.prefix(count)); buffered.removeFirst(count + 1)
                guard line.count <= 16 * 1024 * 1024 else { throw codexTransportError }
                return line
            }
            line.append(buffered); buffered.removeAll(keepingCapacity: true)
            let byte = try read(1, until: deadline)
            if byte.first == 10 { return line }
            line.append(byte)
        }
        throw codexTransportError
    }
}

/// JSON-RPC uses JSONL for an owned metadata process, WebSocket frames for the
/// existing local daemon. No listening TCP port, model turn or thread resume.
final class CodexRPCConnection: CodexConnection {
    let isShared: Bool
    private let stream: CodexByteStream
    private var requestID = 0
    init(stream: CodexByteStream, shared: Bool) throws {
        self.stream = stream; isShared = shared
        do {
            if shared { try upgrade() }
            _ = try request("initialize", ["clientInfo": ["name": "ccs", "title": "CCS", "version": Product.version],
                                            "capabilities": ["experimentalApi": false]])
            try send(["method": "initialized"], until: Date().addingTimeInterval(5))
        } catch { stream.close(); throw error }
    }
    func close() { stream.close() }
    deinit { close() }
    func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        requestID += 1; let id = requestID, deadline = Date().addingTimeInterval(10)
        try send(["id": id, "method": method, "params": params], until: deadline)
        while Date() < deadline {
            let data = try isShared ? receiveFrame(until: deadline) : stream.line(until: deadline)
            guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw codexTransportError }
            // Server request IDs have a separate namespace and may equal ours.
            if let received = reply["id"], reply["method"] != nil {
                try send(["id": received, "error": ["code": -32601, "message": "CCS supports metadata queries only"]], until: deadline)
                continue
            }
            if let received = reply["id"] as? NSNumber, CFGetTypeID(received) != CFBooleanGetTypeID(), received.doubleValue == Double(id) {
                if let error = reply["error"] as? [String: Any] {
                    throw CCSError.message("Codex: " + cleanText(error["message"]))
                }
                guard let result = reply["result"] as? [String: Any] else { throw codexTransportError }
                return result
            }
        }
        throw codexTransportError
    }
    private func send(_ object: [String: Any], until deadline: Date) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        if isShared { try sendFrame(data, opcode: 1, until: deadline) }
        else { data.append(10); try stream.write(data, until: deadline) }
    }
    private func upgrade() throws {
        let deadline = Date().addingTimeInterval(3)
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try stream.write(Data(request.utf8), until: deadline)
        var header = Data()
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]), header.count < 16384 {
            header.append(try stream.read(1, until: deadline))
        }
        let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
        let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let accepted = lines.contains { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            return parts.count == 2 && parts[0].lowercased() == "sec-websocket-accept" && parts[1].trimmingCharacters(in: .whitespaces) == expected
        }
        guard header.suffix(4).elementsEqual([13, 10, 13, 10]),
              lines.first?.split(separator: " ").dropFirst().first == "101", accepted else { throw codexTransportError }
    }
    private func sendFrame(_ data: Data, opcode: UInt8, until deadline: Date) throws {
        guard data.count <= 16 * 1024 * 1024 else { throw codexTransportError }
        var frame = Data([0x80 | opcode])
        if data.count < 126 { frame.append(0x80 | UInt8(data.count)) }
        else if data.count <= 65535 {
            frame.append(0xFE); frame.append(UInt8((data.count >> 8) & 255)); frame.append(UInt8(data.count & 255))
        } else {
            frame.append(0xFF)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(data.count) >> shift) & 255)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }; frame.append(contentsOf: mask)
        frame.append(contentsOf: data.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try stream.write(frame, until: deadline)
    }
    private func receiveFrame(until deadline: Date) throws -> Data {
        var message = Data(), fragmented = false
        while true {
            let header = [UInt8](try stream.read(2, until: deadline))
            let final = header[0] & 0x80 != 0, opcode = header[0] & 15
            guard header[0] & 0x70 == 0, header[1] & 0x80 == 0 else { throw codexTransportError }
            var length = UInt64(header[1] & 127)
            if length == 126 || length == 127 {
                let bytes = try stream.read(length == 126 ? 2 : 8, until: deadline)
                length = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            }
            guard length <= 16 * 1024 * 1024 else { throw codexTransportError }
            let payload = try stream.read(Int(length), until: deadline)
            if opcode >= 8 {
                guard final, length <= 125 else { throw codexTransportError }
                if opcode == 9 { try sendFrame(payload, opcode: 10, until: deadline); continue }
                if opcode == 10 { continue }
                throw codexTransportError
            }
            guard (opcode == 1 && !fragmented) || (opcode == 0 && fragmented) else { throw codexTransportError }
            message.append(payload)
            guard message.count <= 16 * 1024 * 1024 else { throw codexTransportError }
            if final { return message }; fragmented = true
        }
    }
}

extension CodexRPCConnection {
    static func shared(socketPath: String) throws -> CodexRPCConnection {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.utf8CString
        guard socketPath.hasPrefix("/"), path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw codexTransportError }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw codexTransportError }
        var noSignal: Int32 = 1; _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result < 0 {
            guard errno == EINPROGRESS else { Darwin.close(fd); throw codexTransportError }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard poll(&descriptor, 1, 1000) > 0, getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                Darwin.close(fd); throw codexTransportError
            }
        }
        return try CodexRPCConnection(stream: CodexByteStream(input: fd, output: fd) { Darwin.close(fd) }, shared: true)
    }
    static func metadataProcess(environment: [String: String]) throws -> CodexRPCConnection {
        let process = Process(), input = Pipe(), output = Pipe(), finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["codex", "app-server", "--stdio"]
        var environment = environment
        if environment["CODEX_HOME"] == "" { environment["CODEX_HOME"] = nil }
        process.environment = environment; process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }; try process.run()
        let stream = CodexByteStream(input: output.fileHandleForReading.fileDescriptor, output: input.fileHandleForWriting.fileDescriptor) {
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
                if finished.wait(timeout: .now() + 0.3) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        return try CodexRPCConnection(stream: stream, shared: false)
    }
}
