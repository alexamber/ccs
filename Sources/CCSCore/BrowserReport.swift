import Foundation

/// Only local files and loopback HTTP pages participate in report lookups.
public struct BrowserReportPage: Equatable {
    public let host: String?
    public let port: Int?
    public let path: String
    public var fileName: String? {
        guard !path.hasSuffix("/"), ArtifactIndex.types.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        return (path as NSString).lastPathComponent
    }
    public var title: String { fileName ?? "\(host ?? ""):\(port ?? 0)\(path)" }

    public init?(_ address: String) {
        guard let url = URLComponents(string: address), let scheme = url.scheme?.lowercased(),
              url.user == nil, url.password == nil else { return nil }
        let host = url.host?.lowercased()
        let path = url.path
        guard !path.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }
        switch scheme {
        case "file":
            guard host == nil || host == "" || host == "localhost", path.hasPrefix("/"),
                  ArtifactIndex.types.contains((path as NSString).pathExtension.lowercased()) else { return nil }
            self.host = nil; port = nil; self.path = (path as NSString).standardizingPath
        case "http", "https":
            guard let host, ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host) else { return nil }
            let port = url.port ?? (scheme == "https" ? 443 : 80)
            guard (1...65535).contains(port) else { return nil }
            self.host = host; self.port = port; self.path = path.isEmpty ? "/" : path
        default: return nil
        }
    }
}

public struct BrowserReportSource {
    public var file: String?
    public var servingKey: String?
    fileprivate var ancestry = [Int32]()
    public init(file: String? = nil, servingKey: String? = nil) {
        self.file = file; self.servingKey = servingKey
    }

    public func matching(_ targets: [TerminalSwitchTarget]) -> Self {
        var result = self
        result.servingKey = nil
        for child in ancestry {
            let owners = targets.filter { target in
                guard let session = target.session else { return false }
                return session.provider == .claude ? session.live?.pid == Int(child) : target.processID == child
            }
            if !owners.isEmpty {
                if owners.count == 1 { result.servingKey = owners[0].key }
                break
            }
        }
        return result
    }
}

extension SessionService {
    public func browserReportSource(_ page: BrowserReportPage, targets: [TerminalSwitchTarget]) -> BrowserReportSource {
        guard let port = page.port else { return BrowserReportSource(file: page.path) }
        let listeners = try? runner("/usr/sbin/lsof", ["-nP", "-a", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fptn"], nil, 3)
        guard let listeners, listeners.code == 0,
              let pid = Self.loopbackListener(listeners.out, page: page) else { return BrowserReportSource() }

        var source = BrowserReportSource()
        if let listing = try? runner("/bin/ps", ["-axo", "pid=,ppid="], nil, 3), listing.code == 0 {
            var parents = [Int32: Int32]()
            for line in listing.out.split(separator: "\n") {
                let pair = line.split(whereSeparator: \.isWhitespace)
                if pair.count == 2, let child = Int32(pair[0]), let parent = Int32(pair[1]) { parents[child] = parent }
            }
            var current: Int32? = pid, visited = Set<Int32>()
            while let child = current, child > 1, visited.insert(child).inserted {
                source.ancestry.append(child)
                current = parents[child]
            }
        }

        // A port identifies a listener. Only a known static server invocation also
        // identifies a document root. Arbitrary application routes stay tentative.
        if let argv = processArguments(pid), let directory = Self.pythonHTTPDirectory(argv),
           let cwd = try? runner("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], nil, 3),
           cwd.code == 0, let line = cwd.out.split(separator: "\n").first(where: { $0.hasPrefix("n/") }),
           !page.path.split(separator: "/").contains("..") {
            let base = URL(fileURLWithPath: String(line.dropFirst()), isDirectory: true)
            let root = URL(fileURLWithPath: directory, isDirectory: true, relativeTo: base).standardizedFileURL
            var file = root.appendingPathComponent(String(page.path.drop(while: { $0 == "/" })))
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue {
                for name in ["index.html", "index.htm"] where FileManager.default.fileExists(atPath: file.appendingPathComponent(name).path) {
                    file.appendPathComponent(name); break
                }
            }
            if ArtifactIndex.types.contains(file.pathExtension.lowercased()),
               (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                source.file = file.standardizedFileURL.path
            }
        }
        return source.matching(targets)
    }

    static func loopbackListener(_ fields: String, page: BrowserReportPage) -> Int32? {
        var pids = Set<Int32>(), pid: Int32?, family = ""
        for field in fields.split(separator: "\n") {
            let value = String(field.dropFirst())
            switch field.first {
            case "p": pid = Int32(value); family = ""
            case "t": family = value
            case "n":
                guard let pid, let port = page.port, value.hasSuffix(":\(port)") else { continue }
                let address = String(value.dropLast(String(port).count + 1))
                let ipv4 = page.host == "127.0.0.1", ipv6 = page.host == "[::1]" || page.host == "::1"
                if address == "*" && !(ipv4 && family == "IPv6" || ipv6 && family == "IPv4") ||
                    address == "127.0.0.1" && !ipv6 || address == "[::1]" && !ipv4 { pids.insert(pid) }
            default: break
            }
        }
        return pids.count == 1 ? pids.first : nil
    }

    private static func pythonHTTPDirectory(_ argv: [String]) -> String? {
        guard let executable = argv.first,
              (executable as NSString).lastPathComponent.lowercased().range(of: #"^python(w)?([23](\.[0-9]+)?)?$"#, options: .regularExpression) != nil else { return nil }
        var args = argv.dropFirst()
        while let flag = args.first, ["-u", "-B", "-E", "-I", "-O", "-OO", "-s", "-S"].contains(flag) {
            args.removeFirst()
        }
        guard args.popFirst() == "-m", args.popFirst() == "http.server" else { return nil }
        var directory = "."
        while let arg = args.popFirst() {
            if Int(arg) != nil { continue }
            if ["--bind", "-b", "--directory", "-d"].contains(arg), let value = args.popFirst() {
                if arg == "--directory" || arg == "-d" { directory = value }
            } else if arg.hasPrefix("--directory=") { directory = String(arg.dropFirst("--directory=".count)) }
            else if !arg.hasPrefix("--bind=") { return nil }
        }
        return directory
    }
}
