import Foundation
import CCSCore

/// Main-thread presentation state. Time advances only while a notice is visible
/// and unhovered. Reading a Terminal session acknowledges it independently of UI entry point.
final class SessionNotificationQueue {
    private let now: () -> Date
    private var pending = [SessionUpdate]()
    private var unread = [String: [SessionUpdate]]()
    private(set) var current: SessionUpdate?
    private var remaining: TimeInterval = 5
    private var lastTick: Date?
    private var viewedKey: String?, viewedSince: Date?, acknowledgedView = false
    var hovered = false
    var hasUnattendedCompletion: (String) -> Bool = { _ in false }
    var canPresent: () -> Bool = { true }
    var onShow: ((SessionUpdate) -> Void)?, onHide: (() -> Void)?, onChange: (() -> Void)?, onViewed: ((String) -> Void)?
    var unreadCount: Int { unread.count }
    var queuedCount: Int { pending.count }
    var needsTick: Bool {
        if current != nil || !pending.isEmpty { return true }
        guard let viewedKey, !acknowledgedView else { return false }
        return unread[viewedKey] != nil || hasUnattendedCompletion(viewedKey)
    }
    func completionArrived(for key: String) {
        if viewedKey == key { viewedSince = now(); acknowledgedView = false }
    }
    init(now: @escaping () -> Date = Date.init) { self.now = now }
    func enqueue(_ updates: [SessionUpdate]) {
        for update in updates {
            pending.append(update)
            unread[update.key] = (unread[update.key] ?? []).filter { $0.kind != update.kind } + [update]
            if viewedKey == update.key { viewedSince = now(); acknowledgedView = false }
        }
        onChange?(); tick()
    }
    func observe(_ key: String?) {
        guard key != viewedKey else { return }
        viewedKey = key; viewedSince = key == nil ? nil : now(); acknowledgedView = false
        onChange?()
    }
    func acknowledge(_ key: String) {
        pending.removeAll { $0.key == key }; unread.removeValue(forKey: key)
        if current?.key == key { current = nil; hovered = false; onHide?() }
        onViewed?(key); onChange?()
    }
    func reconcile(_ snapshot: TerminalActivitySnapshot, attention: Bool, completion: Bool) {
        let states = Dictionary(snapshot.context.targets.compactMap { target in target.session.map { (target.key, $0.status) } }, uniquingKeysWith: { a, _ in a })
        func keep(_ update: SessionUpdate) -> Bool {
            if update.kind == .finished { return completion }
            guard attention else { return false }
            guard let status = states[update.key], SessionActivity(status: status) != .unknown else { return true }
            return SessionActivity(status: status) == .attention &&
                SessionActivity.attentionReason(status) == SessionActivity.attentionReason(update.target.session?.status)
        }
        pending = pending.filter(keep)
        unread = unread.mapValues { $0.filter(keep) }.filter { !$0.value.isEmpty }
        if let current, !keep(current) { self.current = nil; hovered = false; onHide?() }
        onChange?()
    }
    func reset() {
        pending = []; unread = [:]; current = nil; lastTick = nil; hovered = false
        observe(nil); onHide?(); onChange?()
    }
    func tick() {
        let stamp = now(), elapsed = lastTick.map { max(0, stamp.timeIntervalSince($0)) } ?? 0
        lastTick = stamp
        if let key = viewedKey, let since = viewedSince, !acknowledgedView, stamp.timeIntervalSince(since) >= 1 {
            acknowledgedView = true; acknowledge(key)
        }
        guard canPresent() else {
            if current != nil { hovered = false; onHide?() }
            return
        }
        if let current {
            onShow?(current)
            if !hovered { remaining -= elapsed }
            if remaining > 0 { return }
            self.current = nil; hovered = false; onHide?()
        }
        guard !pending.isEmpty else { onChange?(); return }
        let index = pending.firstIndex { $0.kind == .attention } ?? pending.startIndex
        current = pending.remove(at: index); remaining = 5
        onShow?(current!)
    }
}
