import AppKit
import SwiftUI
import CCSCore

struct BrowserSessionMatch: Identifiable {
    let session: Session
    let target: TerminalSwitchTarget?
    let serving: Bool
    let reference: ReportReference?
    let possible: Bool
    var id: String { session.key }
    var detail: String {
        var parts = [String]()
        if serving { parts.append("Serving this page") }
        if let reference { parts.append(possible ? "Possible match · " + reference.action.label : reference.action.label) }
        parts.append(session.provider.title)
        return parts.joined(separator: " · ")
    }

    static func results(page: BrowserReportPage, source: BrowserReportSource, history: HistorySnapshot,
                        search: ReportSearch) -> [Self] {
        let name = page.fileName
        return history.sessions.compactMap { session -> Self? in
            let target = history.terminalTargets?[session.key]
            guard target != nil || session.isSaved && !session.isLive else { return nil }
            let serving = target != nil && source.servingKey == session.key
            let reference = search.reference(for: session, path: source.file, name: name)
            guard serving || reference != nil else { return nil }
            return Self(session: session, target: target, serving: serving, reference: reference, possible: source.file == nil)
        }.sorted {
            if $0.serving != $1.serving { return $0.serving }
            let a = $0.reference?.action.rawValue ?? Int.max, b = $1.reference?.action.rawValue ?? Int.max
            if a != b { return a < b }
            if $0.session.mtime != $1.session.mtime { return $0.session.mtime > $1.session.mtime }
            return $0.id < $1.id
        }
    }
}

private final class BrowserReportModel: ObservableObject {
    @Published var inCard = false
    @Published var title = "Chrome tab"
    @Published var sourceSymbol = "doc"
    @Published var warning: String?
    @Published var matches = [BrowserSessionMatch]()
}

private struct BrowserReportList: View {
    @ObservedObject var model: BrowserReportModel
    @State private var hovered: String?
    let select: (BrowserSessionMatch) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: model.sourceSymbol).accessibilityHidden(true)
                Text(model.title).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.trailing, model.inCard ? UnicornMenu.headerClearance : 0)
            .frame(minHeight: model.inCard ? UnicornMenu.headerIconSize : nil)
            .help(model.title)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    let open = model.matches.filter { $0.target != nil }
                    let closed = model.matches.filter { $0.target == nil }
                    group("Open in Terminal", open)
                    if !open.isEmpty && !closed.isEmpty { Divider().padding(.vertical, 3) }
                    group("Closed sessions", closed)
                }
            }
            if let warning = model.warning { Text(warning).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .padding(9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func group(_ name: String, _ matches: [BrowserSessionMatch]) -> some View {
        if !matches.isEmpty {
            Text(name).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.bottom, 1)
            ForEach(matches) { match in
                Button {
                    select(match)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.session.terminalTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Text(match.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium))
                            .foregroundStyle(hovered == match.id ? Color.accentColor : Color.secondary).accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2).padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(hovered == match.id ? 0.12 : 0.035)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hovered = match.id } else if hovered == match.id { hovered = nil }
                }
                .help([match.session.terminalTitle, match.reference?.path ?? match.session.cwd].joined(separator: "\n"))
            }
        }
    }
}

enum BrowserLookupIndicator: Equatable {
    case hidden, thinking, noMatch, unavailable(String)
}

final class BrowserReportPopover: NSObject {
    static let chromeID = "com.google.Chrome"
    typealias ReadPage = (@escaping (Result<BrowserReportPage?, Error>) -> Void) -> Void
    typealias LoadHistory = (@escaping (Result<HistorySnapshot, Error>) -> Void) -> Void
    typealias Resolve = (BrowserReportPage, [TerminalSwitchTarget], @escaping (Result<BrowserReportSource, Error>) -> Void) -> Void
    let popover = UnicornMenu()
    private let model = BrowserReportModel()
    private let readPage: ReadPage, loadHistory: LoadHistory, resolve: Resolve
    private let search: ReportSearch
    private var generation = 0
    private var started: TimeInterval = 0
    private var verifyingTab = false
    private weak var anchor: NSView?
    private var outsideClick: Any?, activation: NSObjectProtocol?
    private var history: HistorySnapshot?
    private var recentHistory: (snapshot: HistorySnapshot, time: TimeInterval)?
    private var page: BrowserReportPage?
    private var source = BrowserReportSource()
    var onClose: (() -> Void)?
    var onIndicator: ((BrowserLookupIndicator) -> Void)?
    var onSelect: ((BrowserSessionMatch, [Session]) -> Void)?
    var isActive: Bool { anchor != nil }
    var isShown: Bool { popover.isShown }

    convenience init(engine: Engine) {
        self.init(readPage: Self.readChromeTab, loadHistory: engine.loadHistory, resolve: { page, targets, done in
            engine.perform({ service, _ in service.browserReportSource(page, targets: targets) }, completion: done)
        }, search: ReportSearch(load: engine.loadReportReferences))
    }
    init(readPage: @escaping ReadPage, loadHistory: @escaping LoadHistory, resolve: @escaping Resolve, search: ReportSearch) {
        self.readPage = readPage; self.loadHistory = loadHistory; self.resolve = resolve; self.search = search
        super.init()
        popover.onClose = { [weak self] in if self?.isActive == true { self?.finish(.hidden) } }
        let controller = NSHostingController(rootView: BrowserReportList(model: model) { [weak self] match in
            guard let self, let sessions = self.history?.sessions else { return }
            self.close(); self.onSelect?(match, sessions)
        })
        controller.sizingOptions = []
        popover.contentViewController = controller
        search.onUpdate = { [weak self] in
            guard let self else { return }
            self.update(scanning: self.search.searching)
        }
    }

    private static func readChromeTab(_ done: @escaping (Result<BrowserReportPage?, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> BrowserReportPage? in
                let script = """
                    const chrome = Application("com.google.Chrome");
                    chrome.running() && chrome.windows.length ? chrome.windows[0].activeTab.url() : ""
                    """
                let result = try ProcessRunner().run("/usr/bin/osascript", ["-l", "JavaScript", "-"], input: script, timeout: 30)
                guard result.code == 0 else {
                    throw CCSError.message(result.err.contains("-1743") ? "Allow CCS to read Google Chrome in System Settings → Privacy & Security → Automation." : "Couldn’t read the selected Chrome tab.")
                }
                return BrowserReportPage(result.out.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    func show(anchor: NSView, recent: TerminalActivitySnapshot? = nil) {
        close()
        generation += 1
        let revision = generation
        model.inCard = anchor.window?.delegate is TerminalSessionPopup
        self.anchor = anchor; started = ProcessInfo.processInfo.systemUptime
        onIndicator?(.thinking)
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier != Self.chromeID { self?.close() }
        }
        readPage { [weak self] result in
            guard let self, self.generation == revision else { return }
            do {
                guard let page = try result.get() else { self.finish(.noMatch); return }
                self.page = page; self.model.title = page.title
                self.model.sourceSymbol = page.fileName == nil ? "globe" : "doc"
                if page.port == nil {
                    self.source = BrowserReportSource(file: page.path)
                    self.loadAll(revision)
                    return
                }
                let targets = recent?.context.targets ?? []
                self.resolve(page, targets) { [weak self] result in
                    guard let self, self.generation == revision else { return }
                    do {
                        self.source = try result.get()
                        if self.source.servingKey != nil {
                            let known = targets.filter { $0.session != nil }
                            self.history = HistorySnapshot(sessions: known.compactMap(\.session), issues: [:], installedProviders: [],
                                terminalTargets: Dictionary(known.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }))
                            let needsReferences = self.source.file != nil || page.fileName != nil
                            self.update(scanning: needsReferences)
                            if !needsReferences { return }
                        }
                        self.loadAll(revision)
                    } catch { self.finish(.unavailable(error.localizedDescription)) }
                }
            } catch { self.finish(.unavailable(error.localizedDescription)) }
        }
    }

    private func loadAll(_ revision: Int) {
        if let recentHistory, ProcessInfo.processInfo.systemUptime - recentHistory.time < 5 {
            useHistory(recentHistory.snapshot)
            return
        }
        loadHistory { [weak self] result in
            guard let self, self.generation == revision else { return }
            do {
                let history = try result.get()
                if history.terminalInventoryComplete && history.terminalTargets != nil && history.issues.isEmpty {
                    self.recentHistory = (history, ProcessInfo.processInfo.systemUptime)
                }
                self.useHistory(history)
            } catch {
                if self.isShown { self.model.warning = "Some sessions could not be checked."; self.onIndicator?(.hidden) }
                else { self.finish(.unavailable(error.localizedDescription)) }
            }
        }
    }

    func reset() { recentHistory = nil; close() }

    private func useHistory(_ history: HistorySnapshot) {
        guard let page else { return }
        self.history = history
        if page.port != nil { source = source.matching(history.terminalTargets.map { Array($0.values) } ?? []) }
        if source.file != nil || page.fileName != nil {
            // Prioritize sessions in the report's project without excluding other folders or older work.
            var project = [Session](), open = [Session](), saved = [Session]()
            for session in history.sessions {
                let hasTab = history.terminalTargets?[session.key] != nil
                guard hasTab || session.isSaved && !session.isLive else { continue }
                if !session.cwd.isEmpty, source.file?.hasPrefix(session.cwd + "/") == true { project.append(session) }
                else if hasTab { open.append(session) }
                else { saved.append(session) }
            }
            search.search(project + open + saved, delay: 0)
        }
        update(scanning: search.searching)
    }

    private func update(scanning: Bool) {
        guard let history, let page, isActive else { return }
        let rows = BrowserSessionMatch.results(page: page, source: source, history: history, search: search)
        let partial = search.failed > 0 || !history.issues.isEmpty || !history.terminalInventoryComplete
        guard !rows.isEmpty else {
            if !scanning { finish(partial ? .unavailable("Some sessions could not be checked.") : .noMatch) }
            return
        }
        model.matches = rows
        model.warning = !scanning && partial ? "Some sessions could not be checked." : nil
        let groups = Set(rows.map { $0.target != nil }).count
        popover.contentSize = NSSize(width: 310, height: min(348, (model.inCard ? UnicornMenu.headerIconSize - 14 : 0) + CGFloat(45 + groups * 18 + rows.count * 33 +
            (groups == 2 ? 7 : 0) + (model.warning == nil ? 0 : 16))))
        if !isShown && ProcessInfo.processInfo.systemUptime - started > 1 {
            // A cold lookup can outlast a keyboard tab switch in Chrome.
            guard !verifyingTab else { return }
            verifyingTab = true
            let revision = generation
            readPage { [weak self] current in
                guard let self, self.generation == revision else { return }
                self.verifyingTab = false
                guard (try? current.get()) == page else { self.finish(.hidden); return }
                self.presentResults()
            }
        } else {
            if !isShown { presentResults() }
        }
    }

    private func presentResults() {
        guard let anchor, anchor.window?.isVisible == true else { finish(.hidden); return }
        stopWatchingForDismissal(); onIndicator?(.hidden)
        popover.showFromUnicorn(anchor)
    }

    private func stopWatchingForDismissal() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick); self.outsideClick = nil }
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation); self.activation = nil }
    }

    func close() { if isActive { finish(.hidden) } }
    private func finish(_ indicator: BrowserLookupIndicator) {
        generation += 1; anchor = nil; verifyingTab = false
        stopWatchingForDismissal(); search.stop(); history = nil; page = nil; source = BrowserReportSource()
        if isShown { popover.close() }
        model.matches = []; model.warning = nil
        onClose?(); onIndicator?(indicator)
    }
}
