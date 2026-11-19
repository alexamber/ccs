import AppKit
import CCSCore

final class ArtifactService {
    static let shared = ArtifactService()
    private let queue = DispatchQueue(label: "io.github.alexamber.ccs.artifacts", qos: .userInitiated)
    private var index: ArtifactIndex?
    private var cache = [String: (Date, ArtifactSnapshot)]()

    func load(folder: String, completion: @escaping (ArtifactSnapshot) -> Void) {
        queue.async {
            if self.index == nil { self.index = ArtifactIndex() }
            let key = URL(fileURLWithPath: folder).standardizedFileURL.path
            let snapshot: ArtifactSnapshot
            if let cached = self.cache[key], Date().timeIntervalSince(cached.0) < 5 { snapshot = cached.1 }
            else {
                snapshot = self.index!.scan(folder: folder)
                if self.cache.count >= 32, let oldest = self.cache.min(by: { $0.value.0 < $1.value.0 })?.key { self.cache.removeValue(forKey: oldest) }
                self.cache[key] = (Date(), snapshot)
            }
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    func open(_ file: SessionArtifact) -> Bool {
        guard let values = try? file.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              NSWorkspace.shared.open(file.url) else { return false }
        queue.async { self.index?.recordOpen(file); self.cache.removeAll() }
        return true
    }
}

private final class ArtifactTable: NSTableView {
    var onOpen: (() -> Void)?, onBack: (() -> Void)?, onInteract: (() -> Void)?
    private var pointerArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); pointerArea = area
    }
    override func mouseEntered(with event: NSEvent) { onInteract?() }
    override func mouseDown(with event: NSEvent) { onInteract?(); super.mouseDown(with: event) }
    override func scrollWheel(with event: NSEvent) { onInteract?(); super.scrollWheel(with: event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) {
        onInteract?()
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if event.keyCode == 36 || event.keyCode == 76 { onOpen?(); return }
            if event.keyCode == 123 { onBack?(); return }
        }
        super.keyDown(with: event)
    }
}

private final class ArtifactLabel: NSTextField {
    override var allowsVibrancy: Bool { false }
}

/// The same list is used in the picker and floating session card.
final class ArtifactBrowser: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    typealias Loader = (String, @escaping (ArtifactSnapshot) -> Void) -> Void
    private let loader: Loader
    private let opener: (SessionArtifact) -> Bool
    private let table = ArtifactTable(), scroll = NSScrollView()
    private let heading = ArtifactLabel(labelWithString: "Files in this folder")
    let folderButton: FolderButton
    private let location = ArtifactLabel(labelWithString: "")
    private let status = ArtifactLabel(wrappingLabelWithString: "Select a session to see its files.")
    private let filter = NSSearchField()
    private let searchHint = ArtifactLabel(labelWithString: "Filenames and paths · all session dates")
    private let searcher: ArtifactSearch
    private var searchQuery: String?, searchFolders = Set<String>()
    private(set) var isGlobalSearch = false
    private var interacted = false
    private let visibleRowLimit: Int?
    private var request = 0, pending: DispatchWorkItem?
    private var allFiles = [SessionArtifact]()
    private var listHeight: NSLayoutConstraint?
    private(set) var files = [SessionArtifact]()
    private(set) var folder: String?
    var onBack: (() -> Void)?, onOpened: (() -> Void)?, onLoaded: ((Int) -> Void)?

    init(showLocation: Bool = true, visibleRowLimit: Int? = nil, folderButton: FolderButton = FolderButton(), loader: @escaping Loader = ArtifactService.shared.load,
         opener: @escaping (SessionArtifact) -> Bool = ArtifactService.shared.open) {
        self.loader = loader; self.opener = opener; self.folderButton = folderButton
        searcher = ArtifactSearch(load: loader)
        self.visibleRowLimit = visibleRowLimit
        super.init(frame: .zero)
        folderButton.onOpened = { [weak self] in self?.onOpened?() }
        heading.font = .systemFont(ofSize: 12, weight: .semibold); heading.textColor = .labelColor
        location.font = .systemFont(ofSize: 10); location.textColor = .labelColor.withAlphaComponent(0.8); location.lineBreakMode = .byTruncatingMiddle
        filter.placeholderString = "Filter files"; filter.controlSize = .small; filter.delegate = self
        filter.setAccessibilityLabel("Filter files in this folder")
        searchHint.font = .systemFont(ofSize: 10); searchHint.textColor = .labelColor.withAlphaComponent(0.8)
        searchHint.isHidden = true
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("artifact")))
        table.headerView = nil; table.backgroundColor = .clear; table.style = .plain
        table.rowHeight = visibleRowLimit == nil ? 48 : 42; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(clicked)
        table.setAccessibilityLabel("Files in the selected session’s folder")
        table.onOpen = { [weak self] in self?.openSelected() }
        table.onBack = { [weak self] in self?.onBack?() }
        table.onInteract = { [weak self] in self?.noteInteraction() }
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        status.font = .systemFont(ofSize: 11); status.textColor = .labelColor.withAlphaComponent(0.8)
        status.maximumNumberOfLines = 2
        let header = NSView()
        do {
            let headingRow = NSStackView(views: showLocation ? [heading, location, folderButton] : [heading])
            headingRow.spacing = 8; headingRow.alignment = .centerY
            heading.setContentHuggingPriority(.required, for: .horizontal)
            heading.setContentCompressionResistancePriority(.required, for: .horizontal)
            location.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            location.setContentHuggingPriority(.defaultLow, for: .horizontal)
            for view in [headingRow, filter, searchHint] {
                view.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(view)
                view.leadingAnchor.constraint(equalTo: header.leadingAnchor).isActive = true
                view.trailingAnchor.constraint(equalTo: header.trailingAnchor).isActive = true
            }
            NSLayoutConstraint.activate([header.heightAnchor.constraint(equalToConstant: 44),
                headingRow.topAnchor.constraint(equalTo: header.topAnchor),
                filter.bottomAnchor.constraint(equalTo: header.bottomAnchor),
                searchHint.centerYAnchor.constraint(equalTo: filter.centerYAnchor)])
        }
        let views: [NSView] = [header, scroll, status]
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        if visibleRowLimit != nil { listHeight = scroll.heightAnchor.constraint(equalToConstant: 44); listHeight?.isActive = true }
        else { scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true }
    }
    private func receiveSearch(_ result: ArtifactSearchSnapshot) {
        allFiles = result.files; applyFilter()
        location.stringValue = "\(files.count) \(files.count == 1 ? "file" : "files")"
        var text = result.searching ? "Searching folders \(result.searched)/\(result.total)…" : result.files.isEmpty ? "No files match." : "\(result.searched) session folders searched."
        if result.incompleteFolders > 0 { text += " Some folders were skipped or limited." }
        if result.limited { text += " Showing limited results." }
        status.stringValue = text; status.toolTip = text; status.isHidden = false
        onLoaded?(files.count)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { pending?.cancel() }

    func show(folder: String?, refresh: Bool = false) {
        guard refresh || isGlobalSearch || self.folder != folder else { return }
        let changed = isGlobalSearch || self.folder != folder
        searcher.cancel(); searchQuery = nil; isGlobalSearch = false
        heading.stringValue = "Files in this folder"; filter.isHidden = false; searchHint.isHidden = true
        folderButton.isHidden = false
        table.setAccessibilityLabel("Files in the selected session’s folder")
        self.folder = folder; folderButton.setFolder(folder); request += 1; pending?.cancel()
        let revision = request
        if changed {
            allFiles = []; files = []; filter.stringValue = ""; table.reloadData()
            listHeight?.constant = 44
            location.stringValue = folder.map { shortPath($0) } ?? ""; location.toolTip = folder
            status.isHidden = false
        }
        guard let folder, !folder.isEmpty else { status.stringValue = "Select a session to see its files."; return }
        if files.isEmpty { status.stringValue = "Looking for reports and documents…" }
        let work = DispatchWorkItem { [weak self] in
            guard let self, revision == self.request else { return }
            self.loader(folder) { [weak self] snapshot in
                guard let self, revision == self.request else { return }
                self.allFiles = snapshot.files; self.applyFilter()
                self.status.stringValue = snapshot.issue ?? (self.files.isEmpty ? "No reports or documents found nearby." : "")
                self.status.isHidden = self.status.stringValue.isEmpty
                self.onLoaded?(self.files.count)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    func showSearch(query: String, folders: [String]) {
        guard searchQuery != query || searchFolders != Set(folders) else { return }
        request += 1; pending?.cancel(); searcher.onUpdate = nil
        searchQuery = query; searchFolders = Set(folders); isGlobalSearch = true
        interacted = false
        folder = nil; folderButton.setFolder(nil); folderButton.isHidden = true
        heading.stringValue = "Files across sessions"; location.toolTip = "Searches folders from all dates for the selected providers."
        filter.stringValue = ""; filter.isHidden = true; searchHint.isHidden = false
        table.setAccessibilityLabel("Matching files across session folders")
        status.isHidden = false; status.stringValue = "Searching session folders…"
        // Debounce typing before scheduling any new directory reads.
        let revision = request
        let work = DispatchWorkItem { [weak self] in
            guard let self, revision == self.request else { return }
            self.searcher.onUpdate = { [weak self] result in
                guard let self, revision == self.request, self.isGlobalSearch else { return }
                self.receiveSearch(result)
            }
            self.searcher.search(query, folders: folders)
        }
        allFiles = []; applyFilter(); location.stringValue = ""
        pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
    func cancel() { request += 1; pending?.cancel(); pending = nil; searcher.cancel(); searchQuery = nil }
    func invalidateSearch() { if isGlobalSearch { cancel() } }
    private func applyFilter() {
        let query = filter.stringValue
        let keep = files.indices.contains(table.selectedRow) ? files[table.selectedRow].url : nil
        let matches = allFiles.filter { query.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(query) }
        if isGlobalSearch, interacted {
            // Results arrive progressively. Keep existing rows under the pointer;
            // newly discovered matches append until the next query or refresh.
            let existing = Set(files.map(\.url))
            files = Array((files + matches.filter { !existing.contains($0.url) }).prefix(200))
        } else { files = matches }
        listHeight?.constant = CGFloat(max(1, min(allFiles.count, visibleRowLimit ?? 5)) * 44)
        table.reloadData()
        if !files.isEmpty {
            table.selectRowIndexes(IndexSet(integer: keep.flatMap { url in files.firstIndex { $0.url == url } } ?? 0), byExtendingSelection: false)
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        applyFilter(); status.stringValue = files.isEmpty ? "No files match." : ""
        status.isHidden = status.stringValue.isEmpty
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) { return focusFiles() }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { openSelected(); return true }
        return false
    }
    func focusFiles() -> Bool {
        guard !files.isEmpty else { return false }
        noteInteraction()
        if table.selectedRow < 0 { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        return window?.makeFirstResponder(table) ?? false
    }
    func noteInteraction() { interacted = true }
    func focusSearch() { window?.makeFirstResponder(filter) }
    @objc private func clicked() { if table.clickedRow >= 0 { openSelected() } }
    func openSelected() {
        let row = table.selectedRow
        guard files.indices.contains(row) else { return }
        if opener(files[row]) { onOpened?() }
        else { status.isHidden = false; status.stringValue = "Couldn’t open this file. It may have moved." }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { files.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PickerRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let file = files[row]
        let name = ArtifactLabel(labelWithString: file.name); name.font = .systemFont(ofSize: 12, weight: .medium); name.lineBreakMode = .byTruncatingMiddle
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: file.kind)!)
        icon.contentTintColor = .secondaryLabelColor
        let parent = isGlobalSearch ? shortPath(file.url.deletingLastPathComponent().path) : (file.relativePath as NSString).deletingLastPathComponent
        let context = parent.isEmpty ? file.kind : parent + " · " + file.kind
        let hint = ArtifactLabel(labelWithString: context + " · " + (file.openCount > 0 ? "Opened before" : "Updated " + ageString(file.modifiedAt.timeIntervalSince1970)))
        hint.font = .systemFont(ofSize: 10); hint.textColor = .labelColor.withAlphaComponent(0.8); hint.lineBreakMode = .byTruncatingMiddle
        let text = NSStackView(views: [name, hint]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        name.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true; hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cell = NSTableCellView(); cell.toolTip = file.url.path
        for view in [icon, text] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14), icon.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityLabel(file.name + ", " + file.relativePath)
        return cell
    }
}
