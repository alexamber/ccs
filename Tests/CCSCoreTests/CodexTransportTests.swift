import Foundation
import Darwin
import CryptoKit
import XCTest
@testable import CCSCore

private final class WebSocketPeer {
    let fd: Int32
    init(_ fd: Int32) {
        self.fd = fd
        var timeout = timeval(tv_sec: 3, tv_usec: 0), noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }
    deinit { Darwin.close(fd) }
    func read(_ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            var bytes = [UInt8](repeating: 0, count: count - result.count)
            let size = Darwin.read(fd, &bytes, bytes.count)
            guard size > 0 else { throw CCSError.message("Test peer read failed") }
            result.append(contentsOf: bytes.prefix(size))
        }
        return result
    }
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let size = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                guard size > 0 else { throw CCSError.message("Test peer write failed") }; offset += size
            }
        }
    }
    func frame(_ payload: Data, opcode: UInt8 = 1, final: Bool = true) throws {
        var header = Data([(final ? 128 : 0) | opcode])
        if payload.count < 126 { header.append(UInt8(payload.count)) }
        else if payload.count <= 65535 { header.append(126); header.append(UInt8(payload.count >> 8)); header.append(UInt8(payload.count & 255)) }
        else { header.append(127); for shift in stride(from: 56, through: 0, by: -8) { header.append(UInt8((UInt64(payload.count) >> shift) & 255)) } }
        try write(header + payload)
    }
    func clientFrame() throws -> (UInt8, Data) {
        let header = [UInt8](try read(2)); var size = Int(header[1] & 127)
        guard header[1] & 128 != 0 else { throw CCSError.message("Client frame was not masked") }
        if size == 126 || size == 127 { size = try read(size == 126 ? 2 : 8).reduce(0) { ($0 << 8) | Int($1) } }
        guard size < 1_000_000 else { throw CCSError.message("Test frame too large") }
        let mask = [UInt8](try read(4)), payload = try read(size)
        return (header[0] & 15, Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }))
    }
    func json() throws -> [String: Any] {
        let (_, data) = try clientFrame()
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    func initialize() throws {
        var header = Data()
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]), header.count < 16384 { header.append(try read(1)) }
        let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
        let key = try XCTUnwrap(lines.first { $0.lowercased().hasPrefix("sec-websocket-key:") }?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces))
        let digest = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        try write(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(digest)\r\n\r\n".utf8))
        let request = try json(); XCTAssertEqual(request["method"] as? String, "initialize")
        try frame(JSONSerialization.data(withJSONObject: ["id": request["id"]!, "result": [:]]))
        XCTAssertEqual(try json()["method"] as? String, "initialized")
    }
}

final class CodexTransportTests: XCTestCase {
    private func connection(peerWork: @escaping (WebSocketPeer) throws -> Void) throws -> (CodexRPCConnection, XCTestExpectation) {
        var pair = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let clientFD = pair[0], peerFD = pair[1], done = expectation(description: "Local metadata peer finished")
        DispatchQueue.global().async {
            let peer = WebSocketPeer(peerFD)
            defer { done.fulfill() }
            do { try peer.initialize(); try peerWork(peer) }
            catch { XCTFail("Local metadata peer failed: \(error)") }
        }
        let stream = CodexByteStream(input: clientFD, output: clientFD) { Darwin.close(clientFD) }
        return (try CodexRPCConnection(stream: stream, shared: true), done)
    }
    func testSharedTransportMasksRequestsHandlesPingAndFragmentationAndDeclinesApprovals() throws {
        let text = String(repeating: "Hello 👋 ", count: 10_000)
        let (client, done) = try connection { peer in
            let query = try peer.json()
            XCTAssertEqual(query["method"] as? String, "thread/list")
            XCTAssertEqual((query["params"] as? [String: Any])?["padding"] as? String, String(repeating: "x", count: 70_000))
            try peer.frame(JSONSerialization.data(withJSONObject: ["id": query["id"]!, "method": "item/commandExecution/requestApproval", "params": [:]]))
            let declined = try peer.json()
            XCTAssertEqual(declined["id"] as? Int, query["id"] as? Int)
            XCTAssertEqual((declined["error"] as? [String: Any])?["code"] as? Int, -32601)
            try peer.frame(Data("ping".utf8), opcode: 9)
            let pong = try peer.clientFrame(); XCTAssertEqual(pong.0, 10); XCTAssertEqual(pong.1, Data("ping".utf8))
            let response = try JSONSerialization.data(withJSONObject: ["id": query["id"]!, "result": ["text": text]])
            try peer.frame(Data(response.prefix(103)), final: false)
            try peer.frame(Data(response.dropFirst(103)), opcode: 0)
        }
        defer { client.close() }
        XCTAssertTrue(client.isShared)
        let response = try client.request("thread/list", ["padding": String(repeating: "x", count: 70_000)])
        XCTAssertEqual(response["text"] as? String, text)
        wait(for: [done], timeout: 5)
    }
    func testOversizedServerFrameFailsBeforeAllocatingItsPayload() throws {
        let (client, done) = try connection { peer in
            _ = try peer.json()
            var header = Data([0x81, 127])
            for shift in stride(from: 56, through: 0, by: -8) { header.append(UInt8((UInt64(16 * 1024 * 1024 + 1) >> shift) & 255)) }
            try peer.write(header)
        }
        defer { client.close() }
        XCTAssertThrowsError(try client.request("thread/list", [:]))
        wait(for: [done], timeout: 5)
    }
}
