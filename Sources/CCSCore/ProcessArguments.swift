import Foundation
import Darwin

/// ps prints argv separated by spaces without escaping. Read the kernel's
/// NUL-delimited arguments instead, so paths and names retain their boundaries.
public enum ProcessArguments {
    public static func read(_ pid: Int32) -> [String]? {
        var limit = 0
        var size = MemoryLayout<Int>.size
        var argmax: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmax, 2, &limit, &size, nil, 0) == 0, limit > 0, limit <= 16 * 1024 * 1024 else { return nil }
        var data = [UInt8](repeating: 0, count: limit)
        size = data.count
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let status = data.withUnsafeMutableBytes { sysctl(&query, 3, $0.baseAddress, &size, nil, 0) }
        guard status == 0, size > 4 else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 100_000 else { return nil }
        var offset = 4
        // Executable path precedes argv[0], with alignment padding between them.
        while offset < size, data[offset] != 0 { offset += 1 }
        while offset < size, data[offset] == 0 { offset += 1 }
        var result = [String]()
        for _ in 0..<argc {
            let start = offset
            while offset < size, data[offset] != 0 { offset += 1 }
            guard offset < size, let word = String(bytes: data[start..<offset], encoding: .utf8) else { return nil }
            result.append(word); offset += 1
        }
        return result
    }
}
