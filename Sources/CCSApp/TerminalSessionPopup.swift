import AppKit
import CCSCore

/// All state lives on the main thread. Polls and metadata work are asynchronous;
/// each permits only one in-flight request, even during rapid tab switching.
final class TerminalSessionMonitor {
    enum Dismissal { case inactive, disabled, tabChanged, spaceChanged }
    typealias ReadTab = (@escaping (TerminalTabSnapshot?) -> Void) -> Void
    typealias LoadSession = (TerminalTabSnapshot, @escaping (Session?) -> Void) -> Void
    private let frontmost: () -> Bool
    private let now: () -> Date
    private let readTab: ReadTab
    private let loadSession: LoadSession
    private let show: (Session, TerminalTabSnapshot, Bool) -> Void
    private let hide: (Dismissal) -> Void
    private var observer: NSObjectProtocol?, spaceObserver: NSObjectProtocol?, timer: Timer?
    private var enabled = false, reading = false, resolving = false, needsResolve = false
    private var current: TerminalTabSnapshot?, lastObserved: TerminalTabSnapshot?
    private var lastSessionKey: String?, announce = true, quietSpaceReturn = false
    private var revision = 0
    private var retryAfter: Date?

    init(frontmost: @escaping () -> Bool = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal" },
         now: @escaping () -> Date = Date.init,
         readTab: @escaping ReadTab, loadSession: @escaping LoadSession,
         show: @escaping (Session, TerminalTabSnapshot, Bool) -> Void, hide: @escaping (Dismissal) -> Void) {
        self.frontmost = frontmost; self.now = now; self.readTab = readTab; self.loadSession = loadSession
        self.show = show; self.hide = hide
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in self?.updateActivity() }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in self?.spaceChanged() }
    }
    deinit {
        timer?.invalidate()
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
    }
    func spaceChanged() {
        quietSpaceReturn = true
        stop(.spaceChanged)
        updateActivity()
    }
    func configure(enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        stop(.disabled)
        updateActivity()
    }
    func updateActivity() {
        guard enabled, frontmost() else { stop(enabled ? .inactive : .disabled); return }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.05
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        tick()
    }
    private func stop(_ reason: Dismissal) {
        timer?.invalidate(); timer = nil
        revision += 1; current = nil; needsResolve = false; retryAfter = nil
        if reason == .disabled { lastObserved = nil; lastSessionKey = nil; announce = true; quietSpaceReturn = false }
        hide(reason)
    }
    func tick() {
        guard enabled, frontmost() else { stop(enabled ? .inactive : .disabled); return }
        guard !reading else { return }
        reading = true
        let request = revision
        readTab { [weak self] snapshot in
            guard let self else { return }
            self.reading = false
            guard self.enabled, self.frontmost(), request == self.revision else { return }
            let returning = self.current == nil
            let changed = self.lastObserved?.tty != snapshot?.tty || self.lastObserved?.matchingTitle != snapshot?.matchingTitle
            self.current = snapshot; self.lastObserved = snapshot
            guard changed || returning || self.retryAfter.map({ self.now() >= $0 }) == true else { return }
            if changed {
                if !returning { self.quietSpaceReturn = false }
                self.revision += 1; self.announce = true; self.hide(.tabChanged)
            }
            self.retryAfter = nil
            self.needsResolve = snapshot != nil
            self.resolve()
        }
    }
    private func resolve() {
        guard needsResolve, !resolving, let current else { return }
        needsResolve = false; resolving = true
        let request = revision
        loadSession(current) { [weak self] session in
            guard let self else { return }
            self.resolving = false
            if self.enabled, self.frontmost(), request == self.revision, let snapshot = self.current {
                if let session {
                    let announce = !self.quietSpaceReturn && (self.announce || self.lastSessionKey != session.key)
                    self.lastSessionKey = session.key; self.announce = false; self.quietSpaceReturn = false
                    self.show(session, snapshot, announce)
                }
                else { self.retryAfter = self.now().addingTimeInterval(5) }
            }
            self.resolve()
        }
    }
}

final class TerminalSessionPopup: NSObject, NSWindowDelegate {
    /// Fade only the material, keeping the text sharp over Terminal content.
    private final class Surface: NSView {
        private let material = NSVisualEffectView()
        private var displayObserver: NSObjectProtocol?
        private var hoverArea: NSTrackingArea?
        var onHover: ((Bool) -> Void)?
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true; layer?.cornerRadius = 12; layer?.cornerCurve = .continuous
            material.material = .popover; material.state = .active; material.blendingMode = .behindWindow
            material.wantsLayer = true; material.layer?.cornerRadius = 12
            material.layer?.cornerCurve = .continuous; material.layer?.masksToBounds = true
            material.translatesAutoresizingMaskIntoConstraints = false; addSubview(material)
            NSLayoutConstraint.activate([
                material.leadingAnchor.constraint(equalTo: leadingAnchor), material.trailingAnchor.constraint(equalTo: trailingAnchor),
                material.topAnchor.constraint(equalTo: topAnchor), material.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            displayObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.updateAppearance() }
            updateAppearance()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { if let displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayObserver) } }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(area); hoverArea = area
        }
        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
        func setCornerRadius(_ radius: CGFloat) {
            layer?.cornerRadius = radius; material.layer?.cornerRadius = radius
        }
        private func updateAppearance() {
            material.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.9
        }
    }
    private final class Label: NSTextField {
        override var allowsVibrancy: Bool { false }
    }
    private final class Panel: NSPanel {
        var acceptsKeyboard = false
        var onCancel: (() -> Void)?
        override var canBecomeKey: Bool { acceptsKeyboard }
        override var canBecomeMain: Bool { false }
        override func cancelOperation(_ sender: Any?) { onCancel?() }
    }
    private final class Morph: NSAnimation {
        let update: (CGFloat) -> Void
        init(update: @escaping (CGFloat) -> Void) {
            self.update = update
            super.init(duration: 0.18, animationCurve: .easeInOut)
            animationBlockingMode = .nonblocking; frameRate = 60
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var currentProgress: NSAnimation.Progress {
            didSet { update(CGFloat(currentValue)) }
        }
    }
    private var morph: Morph?, morphRevision = 0
    private var cornerRadius: CGFloat = 19
    private var needsFileFocus = false
    enum Phase { case title, collapsed, expanded }
    private(set) var phase: Phase = .collapsed
    let panel: NSPanel
    let artifactBrowser: ArtifactBrowser
    private let surface = Surface(frame: .zero)
    private let title = Label(wrappingLabelWithString: "")
    private let path = Label(labelWithString: "")
    private let detail = Label(labelWithString: "")
    private let intro = NSButton(title: "", target: nil, action: nil)
    private let bubble = NSButton(title: "", target: nil, action: nil)
    private let mark = NSButton(image: BrandIcon.image(size: 36), target: nil, action: nil)
    private let stack = NSStackView()
    private var expandedConstraints = [NSLayoutConstraint]()
    private var bubbleConstraints = [NSLayoutConstraint](), introConstraints = [NSLayoutConstraint]()
    private var surfaceWidth: NSLayoutConstraint!, surfaceHeight: NSLayoutConstraint!
    private var markTop: NSLayoutConstraint!
    private var session: Session?, tab: TerminalTabSnapshot?
    private var hovering = false, hoverPreview = false
    private var hoverDelay: DispatchWorkItem?
    private var dismissal: DispatchWorkItem?, artifactTimer: Timer?
    private var presentation = 0
    private var previousApplication: NSRunningApplication?
    var onBrowseFiles: ((Session) -> Void)?

    init(artifactBrowser: ArtifactBrowser? = nil) {
        self.artifactBrowser = artifactBrowser ?? ArtifactBrowser(showLocation: false, backHint: "Collapse", visibleRowLimit: 5)
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 56),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self; panel.isReleasedWhenClosed = false; panel.isFloatingPanel = true
        (panel as? Panel)?.onCancel = { [weak self] in self?.collapse() }
        panel.hidesOnDeactivate = false; panel.level = .floating
        // Keep this contextual panel on its own Space; it must not follow a
        // swipe to another desktop like the explicitly invoked picker does.
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.contentView = surface
        surface.onHover = { [weak self] in self?.setHovering($0) }
        for button in [intro, bubble] {
            button.isBordered = false; button.font = .systemFont(ofSize: 13, weight: .semibold)
            button.target = self; button.action = #selector(expand)
            button.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(button)
            let constraints = [
                button.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
                button.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: button === intro ? -60 : -10),
                button.topAnchor.constraint(equalTo: surface.topAnchor, constant: 8),
                button.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -8),
            ]
            if button === intro { introConstraints = constraints } else { bubbleConstraints = constraints }
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        intro.cell?.wraps = true; intro.cell?.usesSingleLineMode = false; intro.cell?.lineBreakMode = .byWordWrapping
        bubble.setAccessibilityLabel("CCS session files. Click to expand.")
        title.font = .systemFont(ofSize: 13, weight: .semibold); title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail; title.preferredMaxLayoutWidth = 280
        title.cell?.wraps = true; title.cell?.usesSingleLineMode = false
        path.font = .systemFont(ofSize: 11); path.textColor = .secondaryLabelColor; path.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide CCS bubble")!, target: self, action: #selector(closeCard))
        close.isBordered = false; close.contentTintColor = .secondaryLabelColor
        close.toolTip = "Hide bubble"
        let heading = NSView()
        for view in [title, close] { view.translatesAutoresizingMaskIntoConstraints = false; heading.addSubview(view) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: heading.leadingAnchor), title.topAnchor.constraint(equalTo: heading.topAnchor),
            title.bottomAnchor.constraint(equalTo: heading.bottomAnchor),
            title.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
            close.trailingAnchor.constraint(equalTo: heading.trailingAnchor, constant: -44),
            heading.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            close.topAnchor.constraint(equalTo: heading.topAnchor), close.widthAnchor.constraint(equalToConstant: 20), close.heightAnchor.constraint(equalToConstant: 20),
        ])
        let metadata = NSView()
        for view in [path, detail] { view.translatesAutoresizingMaskIntoConstraints = false; metadata.addSubview(view) }
        NSLayoutConstraint.activate([
            path.leadingAnchor.constraint(equalTo: metadata.leadingAnchor), path.topAnchor.constraint(equalTo: metadata.topAnchor),
            path.bottomAnchor.constraint(equalTo: metadata.bottomAnchor), path.trailingAnchor.constraint(equalTo: detail.leadingAnchor, constant: -12),
            detail.trailingAnchor.constraint(equalTo: metadata.trailingAnchor), detail.firstBaselineAnchor.constraint(equalTo: path.firstBaselineAnchor),
        ])
        detail.setContentHuggingPriority(.required, for: .horizontal)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        let divider = NSBox(); divider.boxType = .separator
        let picker = NSButton(title: "Open session picker…", target: self, action: #selector(browseFiles))
        picker.isBordered = false; picker.font = .systemFont(ofSize: 11); picker.alignment = .right
        for view in [heading, metadata, divider, self.artifactBrowser, picker] { stack.addArrangedSubview(view) }
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(stack)
        expandedConstraints = [
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -16),
        ]
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 348).isActive = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.artifactBrowser.onOpened = { [weak self] in self?.collapse(restoreFocus: false) }
        self.artifactBrowser.onBack = { [weak self] in self?.collapse() }
        self.artifactBrowser.onLoaded = { [weak self] _ in
            guard let self, self.phase == .expanded, self.panel.isVisible else { return }
            self.setPhase(.expanded)
        }
        mark.isBordered = false; mark.imageScaling = .scaleProportionallyUpOrDown
        mark.target = self; mark.action = #selector(toggleExpansion)
        mark.setAccessibilityLabel("CCS session files. Hover for name; click for files.")
        mark.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(mark)
        markTop = mark.topAnchor.constraint(equalTo: surface.topAnchor, constant: 10)
        NSLayoutConstraint.activate([
            mark.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -10),
            markTop,
            mark.widthAnchor.constraint(equalToConstant: 36), mark.heightAnchor.constraint(equalToConstant: 36),
        ])
        surfaceWidth = surface.widthAnchor.constraint(equalToConstant: 56)
        surfaceHeight = surface.heightAnchor.constraint(equalToConstant: 56)
        NSLayoutConstraint.activate([surfaceWidth, surfaceHeight])
        setPhase(.collapsed, animate: false)
    }
    func show(_ session: Session, tab: TerminalTabSnapshot, announce: Bool = true) {
        self.session = session; self.tab = tab
        title.stringValue = session.terminalTitle; intro.title = session.terminalTitle
        path.stringValue = session.cwd.isEmpty ? "Folder unavailable" : shortPath(session.cwd)
        detail.stringValue = [session.provider.title, session.status].filter { !$0.isEmpty }.joined(separator: " · ")
        intro.toolTip = session.terminalTitle + "\n" + path.stringValue + "\nClick for files"
        mark.setAccessibilityLabel(session.terminalTitle + ". Hover for name; click for files.")
        stopLoading()
        setPhase(announce ? .title : .collapsed, animate: announce && panel.isVisible)
        // A quiet restore must not move the panel onto an unrelated Space.
        if announce || panel.isOnActiveSpace { panel.orderFrontRegardless() }
        hovering = false
        if announce {
            hovering = NSMouseInRect(NSEvent.mouseLocation, panel.frame, false)
            hoverPreview = hovering
            scheduleCollapse()
        }
    }
    @objc private func toggleExpansion() { if phase == .expanded { collapse() } else { expand() } }
    @objc func expand() {
        guard let session else { return }
        dismissal?.cancel(); hoverDelay?.cancel(); hoverPreview = false; presentation += 1
        previousApplication = NSWorkspace.shared.frontmostApplication
        needsFileFocus = true
        artifactBrowser.show(folder: session.cwd, refresh: true)
        setPhase(.expanded)
        panel.makeKeyAndOrderFront(nil)
        artifactTimer?.invalidate()
        artifactTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.phase == .expanded, self.panel.isVisible else { return }
            self.artifactBrowser.show(folder: self.session?.cwd, refresh: true)
        }
    }
    func collapse(restoreFocus: Bool = true) {
        let wasKey = panel.isKeyWindow
        stopLoading(); setPhase(.collapsed)
        panel.resignKey()
        if wasKey, restoreFocus,
           previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication?.activate(options: [])
        }
        previousApplication = nil
    }
    @objc private func closeCard() { hide() }
    @objc private func browseFiles() { if let session { hide(); onBrowseFiles?(session) } }
    func windowDidResignKey(_ notification: Notification) {
        if phase == .expanded { collapse(restoreFocus: false) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { collapse(); return false }
    private func setPhase(_ value: Phase, animate: Bool = true) {
        morph?.stop(); morph = nil; morphRevision += 1
        let revision = morphRevision
        phase = value
        (panel as? Panel)?.acceptsKeyboard = value == .expanded
        NSLayoutConstraint.deactivate(expandedConstraints + introConstraints + bubbleConstraints)
        stack.isHidden = true; intro.isHidden = true; bubble.isHidden = true
        stack.layoutSubtreeIfNeeded()
        let size: NSSize = value == .expanded ? NSSize(width: 380, height: max(220, stack.fittingSize.height + 32)) : value == .title ? NSSize(width: 320, height: 56) : NSSize(width: 56, height: 56)
        let startFrame = panel.frame, startRadius = cornerRadius, startMarkTop = markTop.constant
        let endRadius: CGFloat = value == .expanded ? 16 : size.height / 2
        let endMarkTop: CGFloat = value == .expanded ? 8 : 10
        var frame = panel.frame
        frame.origin.x += frame.width - size.width; frame.origin.y += frame.height - size.height; frame.size = size
        if let tab, let primary = NSScreen.screens.first {
            let terminal = NSRect(x: tab.bounds.minX, y: primary.frame.maxY - tab.bounds.maxY, width: tab.bounds.width, height: tab.bounds.height)
            let screen = NSScreen.screens.max { a, b in
                let x = a.frame.intersection(terminal), y = b.frame.intersection(terminal)
                return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
            } ?? primary
            let visible = screen.visibleFrame
            frame.origin.x = min(max(terminal.maxX - size.width - 16, visible.minX + 12), visible.maxX - size.width - 12)
            frame.origin.y = min(max(terminal.maxY - size.height - 70, visible.minY + 12), visible.maxY - size.height - 12)
        }
        let update: (CGFloat) -> Void = { [weak self] progress in
            guard let self, revision == self.morphRevision else { return }
            func blend(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
            let next = NSRect(x: blend(startFrame.minX, frame.minX), y: blend(startFrame.minY, frame.minY),
                              width: blend(startFrame.width, frame.width), height: blend(startFrame.height, frame.height))
            self.surfaceWidth.constant = next.width; self.surfaceHeight.constant = next.height
            self.markTop.constant = blend(startMarkTop, endMarkTop)
            self.cornerRadius = blend(startRadius, endRadius); self.surface.setCornerRadius(self.cornerRadius)
            self.panel.setFrame(next, display: true, animate: false)
            if progress >= 1 {
                self.stack.isHidden = value != .expanded; self.intro.isHidden = value != .title; self.bubble.isHidden = value != .collapsed
                NSLayoutConstraint.activate(value == .expanded ? self.expandedConstraints : value == .title ? self.introConstraints : self.bubbleConstraints)
                self.surface.layoutSubtreeIfNeeded()
                if value == .expanded, self.needsFileFocus {
                    self.needsFileFocus = false; self.artifactBrowser.focusSearch()
                }
            }
        }
        if animate, panel.isVisible, frame != startFrame, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            morph = Morph(update: update); morph?.start()
        } else { update(1) }
    }
    private func scheduleCollapse() {
        dismissal?.cancel(); presentation += 1
        guard phase == .title, !hovering else { return }
        let request = presentation
        let work = DispatchWorkItem { [weak self] in
            guard let self, request == self.presentation else { return }
            self.collapse(restoreFocus: false)
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
    func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value; hoverDelay?.cancel()
        guard phase != .expanded, panel.isVisible else { return }
        if value {
            dismissal?.cancel(); presentation += 1
            hoverPreview = true
            guard phase == .collapsed else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hovering, self.phase == .collapsed, self.panel.isVisible else { return }
                self.setPhase(.title)
            }
            hoverDelay = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else if hoverPreview {
            hoverPreview = false
            if phase == .title { collapse(restoreFocus: false) }
        } else { scheduleCollapse() }
    }
    func contextEnded(_ reason: TerminalSessionMonitor.Dismissal) {
        switch reason {
        case .disabled, .tabChanged: hide()
        case .spaceChanged:
            // Collapse in place without replaying the title or changing Spaces.
            stopLoading(); hovering = false
            setPhase(.collapsed, animate: false); panel.resignKey()
        case .inactive:
            // Keep the last identified folder within reach across applications.
            // Opening CCS's picker hides the bubble so the two panels do not overlap.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
               phase != .expanded { hide() }
        }
    }
    private func stopLoading() {
        dismissal?.cancel(); hoverDelay?.cancel(); hoverPreview = false; presentation += 1
        artifactTimer?.invalidate(); artifactTimer = nil; artifactBrowser.cancel()
    }
    func hide() {
        stopLoading(); hovering = false
        morph?.stop(); morph = nil; morphRevision += 1; needsFileFocus = false
        panel.orderOut(nil); previousApplication = nil
    }
}
