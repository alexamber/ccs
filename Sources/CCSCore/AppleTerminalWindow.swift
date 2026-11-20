import AppKit

/// One running Terminal instance and one window for the duration of a switch.
/// Address the tab by TTY on every event so dragging or reordering tabs cannot
/// make an old positional index select a different tab.
struct AppleTerminalWindow {
    private typealias Descriptor = NSAppleEventDescriptor
    private let processID: pid_t
    private let windowID: CGWindowID
    private let address: Descriptor
    private let window: Descriptor
    private let tabs: Descriptor

    init?(tab: TerminalTabSnapshot) {
        guard let id = tab.windowID, let pid = NSRunningApplication.runningApplications(
            withBundleIdentifier: AppleTerminalAdapter.id).first?.processIdentifier else { return nil }
        processID = pid
        windowID = CGWindowID(bitPattern: id)
        address = Descriptor(processIdentifier: pid)
        window = Self.object("cwin", in: .null(), by: "ID  ", value: Descriptor(int32: id))

        // Terminal.sdef: every tab of window id … whose tty is …
        let examined = Descriptor(descriptorType: Self.code("exmn"), data: Data())!
        let test = Descriptor.record()
        test.setDescriptor(Descriptor(enumCode: Self.code("=   ")), forKeyword: Self.code("relo"))
        test.setDescriptor(Self.property("ttty", of: examined), forKeyword: Self.code("obj1"))
        test.setDescriptor(Descriptor(string: tab.tty), forKeyword: Self.code("obj2"))
        tabs = Self.object("ttab", in: window, by: "test", value: test.coerce(toDescriptorType: Self.code("cmpd"))!)
    }

    /// An empty result or a vanished window invalidates the hint. Propagate
    /// permission and timeout errors, since retrying those cannot verify a tab.
    func title() throws -> String? {
        do {
            let value = try send("core", "getd", object: Self.property("titl", of: tabs))
            guard value?.numberOfItems == 1 else { return nil }
            return value?.atIndex(1)?.stringValue
        } catch let error as NSError where error.code == -1728 || error.code == -1719 {
            return nil
        }
    }

    func focus(tty: String, verifiedTitle: String, newTitle: String, activate: () throws -> Void,
               revalidate: (String) throws -> Bool) throws -> Bool {
        guard let current = try title(),
              CodexProvider.normalizedTerminalTitle(current) == CodexProvider.normalizedTerminalTitle(verifiedTitle) else { return false }

        let active = Self.property("pisf", of: .null())
        let first = Self.object("cwin", in: .null(), by: "indx", value: Descriptor(int32: 1))
        let frontTTY = Self.property("ttty", of: Self.property("tcnt", of: first))
        func confirmed() throws -> Bool {
            guard isWindowOnScreen(), try send("core", "getd", object: active)?.booleanValue == true else { return false }
            return try send("core", "getd", object: frontTTY)?.stringValue == tty
        }

        if isWindowOnScreen(), try send("core", "getd", object: active)?.booleanValue == true {
            try selectAndRaise()
            if try confirmed() {
                if !newTitle.isEmpty, current != newTitle {
                    _ = try? send("core", "setd", object: Self.property("titl", of: tabs), data: Descriptor(string: newTitle))
                }
                return true
            }
        }

        try activate()
        let started = ProcessInfo.processInfo.systemUptime
        var retried = false
        repeat {
            if try confirmed() { return true }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            // Activation may restore Terminal's previous window. Once Terminal
            // has focus, give the requested window one freshly verified raise.
            if !retried, elapsed >= 0.2, try send("core", "getd", object: active)?.booleanValue == true {
                guard let liveTitle = try title(), try revalidate(liveTitle) else {
                    throw CCSError.message("That Terminal session changed while switching. Select it again.")
                }
                try selectAndRaise()
                retried = true
            }
            Thread.sleep(forTimeInterval: 0.025)
        } while ProcessInfo.processInfo.systemUptime - started < 2
        throw CCSError.message("Terminal could not show that tab on this desktop. Check its Space or minimized window.")
    }

    private func selectAndRaise() throws {
        try send("core", "setd", object: Self.property("tbsl", of: tabs), data: Descriptor(boolean: true))
        try send("core", "setd", object: Self.property("pisf", of: window), data: Descriptor(boolean: true))
    }

    private func isWindowOnScreen() -> Bool {
        // A window on another Space can already report frontmost in Terminal
        // while the WindowServer is still displaying the previous window.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], .zero) as? [[String: Any]]
        return windows?.contains {
            $0[kCGWindowNumber as String] as? CGWindowID == windowID && $0[kCGWindowOwnerPID as String] as? pid_t == processID
        } == true
    }

    @discardableResult
    private func send(_ suite: String, _ command: String, object: Descriptor? = nil, data: Descriptor? = nil) throws -> Descriptor? {
        let event = Descriptor(eventClass: Self.code(suite), eventID: Self.code(command),
                               targetDescriptor: address, returnID: -1, transactionID: 0)
        if let object { event.setParam(object, forKeyword: Self.code("----")) }
        if let data { event.setParam(data, forKeyword: Self.code("data")) }
        let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 3)
        if let status = reply.paramDescriptor(forKeyword: Self.code("errn"))?.int32Value, status != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return reply.paramDescriptor(forKeyword: Self.code("----"))
    }

    private static func property(_ name: String, of parent: Descriptor) -> Descriptor {
        object("prop", in: parent, by: "prop", value: Descriptor(typeCode: code(name)))
    }

    private static func object(_ type: String, in parent: Descriptor, by form: String, value: Descriptor) -> Descriptor {
        let spec = Descriptor.record()
        spec.setDescriptor(Descriptor(typeCode: code(type)), forKeyword: code("want"))
        spec.setDescriptor(parent, forKeyword: code("from"))
        spec.setDescriptor(Descriptor(enumCode: code(form)), forKeyword: code("form"))
        spec.setDescriptor(value, forKeyword: code("seld"))
        return spec.coerce(toDescriptorType: code("obj "))!
    }

    private static func code(_ name: String) -> UInt32 { name.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
}
