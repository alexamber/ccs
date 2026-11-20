import AppKit
import CCSCore
import QuartzCore

/// All state lives on the main thread. Polls and metadata work are asynchronous;
/// each permits only one in-flight request, even during rapid tab switching.
final class TerminalSessionMonitor {
    enum Dismissal { case inactive, disabled, tabChanged, spaceChanged }
    typealias ReadTab = (@escaping (TerminalTabSnapshot?) -> Void) -> Void
    typealias LoadSession = (TerminalTabSnapshot, @escaping (Session?) -> Void) -> Void
    private let isCurrentTerminal: (String) -> Bool
    private let frontmost: () -> Bool
    private let now: () -> Date
    private let readTab: ReadTab
    private let loadSession: LoadSession
    private let show: (Session, TerminalTabSnapshot) -> Void
    private let hide: (Dismissal) -> Void
    private var observer: NSObjectProtocol?, spaceObserver: NSObjectProtocol?, timer: Timer?
    private var enabled = false, reading = false, resolving = false, needsResolve = false
    private var current: TerminalTabSnapshot?, lastObserved: TerminalTabSnapshot?
    private var lastSessionKey: String?
    private var revision = 0
    private var retryAfter: Date?
    var onFocus: ((String?) -> Void)?

    init(frontmost: @escaping () -> Bool, isCurrentTerminal: @escaping (String) -> Bool = { _ in true },
         now: @escaping () -> Date = Date.init,
         readTab: @escaping ReadTab, loadSession: @escaping LoadSession,
         show: @escaping (Session, TerminalTabSnapshot) -> Void, hide: @escaping (Dismissal) -> Void) {
        self.isCurrentTerminal = isCurrentTerminal; self.frontmost = frontmost; self.now = now; self.readTab = readTab; self.loadSession = loadSession
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
        guard enabled else { return }
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
        onFocus?(nil)
        timer?.invalidate(); timer = nil
        revision += 1; current = nil; needsResolve = false; retryAfter = nil
        if reason == .disabled { lastObserved = nil; lastSessionKey = nil }
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
            guard let snapshot, self.isCurrentTerminal(snapshot.terminalID) else {
                self.onFocus?(nil)
                // An Apple event can fail during activation/Space transitions.
                // Hide stale content, but do not turn recovery into a new topic.
                if self.current != nil {
                    self.revision += 1; self.current = nil; self.needsResolve = false; self.retryAfter = nil
                    self.hide(.tabChanged)
                }
                return
            }
            let returning = self.current == nil
            let changed = self.lastObserved?.terminalID != snapshot.terminalID ||
                self.lastObserved?.paneID != snapshot.paneID || self.lastObserved?.tty != snapshot.tty ||
                self.lastObserved?.matchingTitle != snapshot.matchingTitle
            self.current = snapshot; self.lastObserved = snapshot
            self.onFocus?(changed || returning || self.resolving ? nil : self.lastSessionKey)
            guard changed || returning || self.retryAfter.map({ self.now() >= $0 }) == true else { return }
            if changed {
                self.revision += 1; self.hide(.tabChanged)
            }
            self.retryAfter = nil
            self.needsResolve = true
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
            if self.enabled, self.frontmost(), request == self.revision, let snapshot = self.current, self.isCurrentTerminal(snapshot.terminalID) {
                if let session {
                    self.lastSessionKey = session.key
                    self.onFocus?(session.key)
                    self.show(session, snapshot)
                }
                else { self.lastSessionKey = nil; self.onFocus?(nil); self.retryAfter = self.now().addingTimeInterval(5) }
            }
            self.resolve()
        }
    }
}

final class TerminalSessionPopup: NSObject, NSWindowDelegate {
    /// Fade only the material, keeping the text sharp over Terminal content.
    private final class Surface: NSView {
        private let material = NSVisualEffectView()
        private var materialLeading: NSLayoutConstraint!, materialBottom: NSLayoutConstraint!
        private var displayObserver: NSObjectProtocol?
        private var hoverArea: NSTrackingArea?
        var onHover: ((Bool) -> Void)?
        var onContextMenu: (() -> Void)?
        var onPointerDown: ((NSEvent) -> Void)?, onPointerMove: ((NSEvent) -> Void)?, onPointerUp: ((NSEvent) -> Void)?
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            material.material = .popover; material.state = .active; material.blendingMode = .behindWindow
            material.wantsLayer = true; material.layer?.cornerRadius = 12
            material.layer?.cornerCurve = .continuous; material.layer?.masksToBounds = true
            material.translatesAutoresizingMaskIntoConstraints = false; addSubview(material)
            materialLeading = material.leadingAnchor.constraint(equalTo: leadingAnchor)
            materialBottom = material.bottomAnchor.constraint(equalTo: bottomAnchor)
            NSLayoutConstraint.activate([
                materialLeading, material.trailingAnchor.constraint(equalTo: trailingAnchor),
                material.topAnchor.constraint(equalTo: topAnchor), materialBottom,
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
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func rightMouseDown(with event: NSEvent) { onContextMenu?() }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { onContextMenu?() } else { onPointerDown?(event) }
        }
        override func mouseDragged(with event: NSEvent) { onPointerMove?(event) }
        override func mouseUp(with event: NSEvent) { onPointerUp?(event) }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
        var backgroundInset: CGFloat { materialLeading.constant }
        func setBackground(radius: CGFloat, lowerLeftInset: CGFloat) {
            materialLeading.constant = lowerLeftInset
            materialBottom.constant = -lowerLeftInset
            material.layer?.cornerRadius = radius
        }
        private func updateAppearance() {
            material.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.9
        }
    }
    private final class BubbleButton: NSButton {
        var onContextMenu: (() -> Void)?
        var onPointerDown: ((NSEvent) -> Void)?, onPointerMove: ((NSEvent) -> Void)?
        var onPointerUp: ((NSEvent) -> Bool)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func rightMouseDown(with event: NSEvent) { onContextMenu?() }
        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            if event.modifierFlags.contains(.control) { onContextMenu?(); return }
            onPointerDown?(event)
        }
        override func mouseDragged(with event: NSEvent) { onPointerMove?(event) }
        override func mouseUp(with event: NSEvent) {
            if isEnabled, onPointerUp?(event) == true, let action { sendAction(action, to: target) }
        }
    }
    private final class UpdateIndicator: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    let folderButton: FolderButton
    private let path = Label(labelWithString: "")
    private let detail = Label(labelWithString: "")
    private let intro = BubbleButton(title: "", target: nil, action: nil)
    private let bubble = BubbleButton(title: "", target: nil, action: nil)
    private let mark = BubbleButton(image: BrandIcon.image(size: 36), target: nil, action: nil)
    private let stack = NSStackView()
    private var expandedConstraints = [NSLayoutConstraint]()
    private var bubbleConstraints = [NSLayoutConstraint](), introConstraints = [NSLayoutConstraint]()
    private var surfaceWidth: NSLayoutConstraint!, surfaceHeight: NSLayoutConstraint!
    private var markTop: NSLayoutConstraint!, markTrailing: NSLayoutConstraint!
    private var markWidth: NSLayoutConstraint!, indicatorLeading: NSLayoutConstraint!, indicatorBottom: NSLayoutConstraint!
    private var headingClearance: NSLayoutConstraint!, headingHeight: NSLayoutConstraint!
    private var iconSize = UnicornSize.medium
    private var compactSide: CGFloat { 56 * iconSize.scale }
    private var markInset: CGFloat { 7 * iconSize.scale }
    private var titleLeading: NSLayoutConstraint!, titleTrailing: NSLayoutConstraint!
    private var session: Session?, tab: TerminalTabSnapshot?
    private var hovering = false
    private var hoverDelay: DispatchWorkItem?
    private var artifactTimer: Timer?
    private var previousApplication: NSRunningApplication?
    private var persistent = false
    private var overviewPresented = false
    let speech = SessionSpeechBubble()
    static let notificationChirp: NSSound? = {
        let url = Bundle.main.url(forResource: "Grasshopper", withExtension: "caf")
            ?? Bundle.module.url(forResource: "Grasshopper", withExtension: "caf")
        return url.flatMap { NSSound(contentsOf: $0, byReference: false) }
    }()
    var playNotificationSound: () -> Void = {
        guard let chirp = TerminalSessionPopup.notificationChirp else { return }
        if chirp.isPlaying { chirp.stop() }
        chirp.play()
    }
    private var lastNotificationID: UUID?
    private var terminalContextActive = false
    let updateIndicator: NSImageView = UpdateIndicator()
    private var drag = BubbleDrag()
    private var interruptedTransition = false
    private let saveAnchor: (NSPoint) -> Void
    private var placement: NSPoint?
    private var screenObserver: NSObjectProtocol?
    var onBrowseFiles: ((Session) -> Void)?
    var onShowSessions: ((NSView) -> Void)?
    var onNotificationOpen: ((TerminalSwitchTarget) -> Void)?
    var onNotificationHover: ((Bool) -> Void)?
    var onDragStart: (() -> Void)?

    init(artifactBrowser: ArtifactBrowser? = nil, folderButton: FolderButton = FolderButton(),
         saveAnchor: @escaping (NSPoint) -> Void = { UserDefaults.standard.set(["x": $0.x, "y": $0.y], forKey: "unicornAnchor") }) {
        self.saveAnchor = saveAnchor
        self.folderButton = folderButton
        self.artifactBrowser = artifactBrowser ?? ArtifactBrowser(showLocation: false, visibleRowLimit: 5)
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 56),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        speech.onHover = { [weak self] value in self?.onNotificationHover?(value) }
        speech.onOpen = { [weak self] update in self?.onNotificationOpen?(update.target) }
        folderButton.onOpened = { [weak self] in self?.collapse(restoreFocus: false) }
        panel.delegate = self; panel.isReleasedWhenClosed = false; panel.isFloatingPanel = true
        (panel as? Panel)?.onCancel = { [weak self] in self?.collapse() }
        panel.hidesOnDeactivate = false; panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.contentView = surface
        surface.onHover = { [weak self] in self?.setHovering($0) }
        surface.onContextMenu = { [weak self] in self?.showSessions() }
        for button in [intro, bubble] {
            button.isBordered = false; button.font = .systemFont(ofSize: 13, weight: .semibold)
            button.target = self; button.action = #selector(expand)
            button.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(button)
            let leading = button.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16)
            let trailing = button.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -10)
            let constraints = [
                leading, trailing,
                button.topAnchor.constraint(equalTo: surface.topAnchor, constant: 8),
                button.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -8),
            ]
            if button === intro {
                introConstraints = constraints; titleLeading = leading; titleTrailing = trailing
            } else { bubbleConstraints = constraints }
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
        headingClearance = close.trailingAnchor.constraint(equalTo: heading.trailingAnchor, constant: -44)
        headingHeight = heading.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: heading.leadingAnchor), title.topAnchor.constraint(equalTo: heading.topAnchor),
            title.bottomAnchor.constraint(equalTo: heading.bottomAnchor),
            title.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
            headingClearance, headingHeight,
            close.topAnchor.constraint(equalTo: heading.topAnchor), close.widthAnchor.constraint(equalToConstant: 20), close.heightAnchor.constraint(equalToConstant: 20),
        ])
        let metadata = NSView()
        for view in [path, folderButton, detail] { view.translatesAutoresizingMaskIntoConstraints = false; metadata.addSubview(view) }
        NSLayoutConstraint.activate([
            path.leadingAnchor.constraint(equalTo: metadata.leadingAnchor), path.centerYAnchor.constraint(equalTo: metadata.centerYAnchor),
            path.trailingAnchor.constraint(equalTo: folderButton.leadingAnchor, constant: -4),
            folderButton.centerYAnchor.constraint(equalTo: metadata.centerYAnchor),
            folderButton.trailingAnchor.constraint(equalTo: detail.leadingAnchor, constant: -8),
            metadata.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
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
        mark.wantsLayer = true
        for button in [intro, bubble, mark] { button.onContextMenu = { [weak self] in self?.showSessions() } }
        for button in [intro, bubble, mark] {
            button.onPointerDown = { [weak self] _ in
                self?.beginPointerInteraction(at: NSEvent.mouseLocation)
            }
            button.onPointerMove = { [weak self] _ in
                self?.movePointerInteraction(to: NSEvent.mouseLocation)
            }
            button.onPointerUp = { [weak self] _ in
                self?.endPointerInteraction(at: NSEvent.mouseLocation) ?? false
            }
        }
        surface.onPointerDown = mark.onPointerDown; surface.onPointerMove = mark.onPointerMove
        surface.onPointerUp = { [weak self] _ in
            guard let self else { return }
            if self.endPointerInteraction(at: NSEvent.mouseLocation) { self.toggleExpansion() }
        }
        updateIndicator.image = BrandIcon.resource("Firefly")
        updateIndicator.imageScaling = .scaleProportionallyUpOrDown
        updateIndicator.isHidden = true; updateIndicator.translatesAutoresizingMaskIntoConstraints = false
        updateIndicator.setAccessibilityElement(false); surface.addSubview(updateIndicator)
        // The firefly sits at the lower-left corner of the compact launcher.
        indicatorLeading = updateIndicator.leadingAnchor.constraint(equalTo: mark.leadingAnchor, constant: -11.65)
        indicatorBottom = updateIndicator.bottomAnchor.constraint(equalTo: mark.bottomAnchor, constant: 11.65)
        markTop = mark.topAnchor.constraint(equalTo: surface.topAnchor, constant: markInset)
        markTrailing = mark.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -markInset)
        markWidth = mark.widthAnchor.constraint(equalToConstant: 36)
        NSLayoutConstraint.activate([
            markTop, markTrailing, markWidth, mark.heightAnchor.constraint(equalTo: mark.widthAnchor),
            indicatorLeading, indicatorBottom,
            updateIndicator.widthAnchor.constraint(equalTo: mark.widthAnchor, multiplier: 0.5),
            updateIndicator.heightAnchor.constraint(equalTo: updateIndicator.widthAnchor),
        ])
        surfaceWidth = surface.widthAnchor.constraint(equalToConstant: 56)
        surfaceHeight = surface.heightAnchor.constraint(equalToConstant: 56)
        NSLayoutConstraint.activate([surfaceWidth, surfaceHeight])
        setPhase(.collapsed, animate: false)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            self.setPhase(self.phase, animate: false)
        }
    }
    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
    func configureFloating(enabled: Bool, allSpaces: Bool, size: UnicornSize = .medium) {
        let sizeChanged = size != iconSize
        if sizeChanged {
            iconSize = size
            markWidth.constant = 36 * size.scale
            indicatorLeading.constant = -11.65 * size.scale
            indicatorBottom.constant = 11.65 * size.scale
            headingClearance.constant = -(compactSide - 12)
            headingHeight.constant = max(24, compactSide - 24)
        }
        persistent = enabled
        panel.collectionBehavior = allSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary, .transient] : [.fullScreenAuxiliary, .transient]
        guard enabled else { hide(); return }
        if placement == nil, let saved = UserDefaults.standard.dictionary(forKey: "unicornAnchor"),
           let x = saved["x"] as? Double, let y = saved["y"] as? Double, x.isFinite, y.isFinite { placement = NSPoint(x: x, y: y) }
        if !panel.isVisible { showLauncher(clearSession: false) }
        else if sizeChanged { setPhase(phase, animate: false) }
        if placement == nil { placement = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY) }
    }
    func moveAnchor(to point: NSPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        placement = point; setPhase(phase, animate: false)
        placement = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
    }
    func beginPointerInteraction(at point: NSPoint) {
        interruptedTransition = morph?.isAnimating == true
        morph?.stop(); morph = nil; morphRevision += 1
        hoverDelay?.cancel()
        mark.layer?.removeAnimation(forKey: "session-update")
        let anchor = NSPoint(x: panel.frame.maxX + markTrailing.constant + markInset, y: panel.frame.maxY)
        let onCompactBubble = (0...compactSide).contains(anchor.x - point.x) && (0...compactSide).contains(anchor.y - point.y)
        // Grabbing the expanded name/card should bring the compact unicorn
        // under that grip, rather than leave it hundreds of points to the side.
        drag.begin(at: point, anchor: onCompactBubble ? anchor : NSPoint(x: point.x + compactSide / 2, y: point.y + compactSide / 2))
    }
    func movePointerInteraction(to point: NSPoint) {
        let wasDragging = drag.didDrag
        guard let anchor = drag.move(to: point) else { return }
        if !wasDragging {
            onDragStart?(); overviewPresented = false
            stopLoading(); speech.hide(); hovering = false
            intro.title = session?.terminalTitle ?? "CCS · Your active work"
            interruptedTransition = false
            placement = anchor
            setPhase(.collapsed, animate: false, duringDrag: true)
            panel.resignKey()
        }
        placement = anchor
        // Move only the window during the gesture. Rebuilding constraints for
        // every mouse event adds latency and lets hover/layout work fight the drag.
        panel.setFrameOrigin(NSPoint(x: anchor.x - panel.frame.width, y: anchor.y - panel.frame.height))
    }
    /// Returns true only for a click; crossing the drag threshold consumes the
    /// gesture even if the pointer subsequently returns to its starting position.
    @discardableResult func endPointerInteraction(at point: NSPoint) -> Bool {
        guard drag.isTracking else { return false }
        movePointerInteraction(to: point)
        let moved = drag.didDrag
        drag.reset()
        if moved {
            placement = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
            setPhase(.collapsed, animate: false)
            placement = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
            saveAnchor(placement!)
        }
        return !moved
    }
    func setUpdateCount(_ count: Int) {
        updateIndicator.isHidden = count == 0
        let help = count == 0 ? "Drag to move. Right-click for active sessions." : "\(count) session update\(count == 1 ? "" : "s"). Right-click to review."
        mark.toolTip = help; mark.setAccessibilityHelp(help)
    }
    var canShowNotification: Bool { persistent && panel.isVisible && !drag.isTracking && !overviewPresented && phase != .expanded }
    func notify(_ update: SessionUpdate, bubble: Bool, wiggle: Bool, sound: Bool) {
        guard canShowNotification else { speech.hide(); return }
        if lastNotificationID != update.id, sound { playNotificationSound() }
        if lastNotificationID != update.id, wiggle, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let motion = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            motion.values = [0, -0.12, 0.10, -0.06, 0]; motion.duration = 0.45
            mark.layer?.add(motion, forKey: "session-update")
        }
        lastNotificationID = update.id
        if bubble { speech.show(update, beside: panel, anchor: panel.convertToScreen(mark.convert(mark.bounds, to: nil))) }
        else { speech.hide() }
    }
    private func showLauncher(clearSession: Bool) {
        stopLoading()
        if clearSession { session = nil; tab = nil }
        intro.title = session?.terminalTitle ?? "CCS · Your active work"
        intro.toolTip = session == nil ? "Right-click for active sessions" : "Click for files; right-click for active sessions"
        setPhase(.collapsed, animate: false)
        panel.orderFrontRegardless()
    }
    func showSessions() { onShowSessions?(prepareSessionMenu()) }
    func prepareSessionMenu() -> NSView {
        stopLoading(); speech.hide(); hovering = false
        setPhase(.collapsed, animate: false)
        overviewPresented = true
        return mark
    }
    func sessionOverviewClosed() { overviewPresented = false; hovering = false }
    func show(_ session: Session, tab: TerminalTabSnapshot) {
        terminalContextActive = true
        self.session = session; self.tab = tab
        title.stringValue = session.terminalTitle
        folderButton.setFolder(session.cwd)
        path.stringValue = session.cwd.isEmpty ? "Folder unavailable" : shortPath(session.cwd)
        detail.stringValue = [session.provider.title, session.status].filter { !$0.isEmpty }.joined(separator: " · ")
        intro.title = session.terminalTitle
        intro.toolTip = session.terminalTitle + "\n" + path.stringValue + "\nClick for files"
        mark.setAccessibilityLabel(session.terminalTitle + ". Hover for name; click for files.")
        guard !overviewPresented else { return }
        stopLoading()
        setPhase(.collapsed, animate: false)
        // Restore context without replaying the name or moving onto another Space.
        if !panel.isVisible && panel.isOnActiveSpace { panel.orderFrontRegardless() }
        hovering = false
    }
    @objc private func toggleExpansion() { if phase == .expanded { collapse() } else { expand() } }
    @objc func expand() {
        guard terminalContextActive, let session else { return }
        speech.hide()
        let interruptingAnimation = morph?.isAnimating == true || interruptedTransition
        interruptedTransition = false
        hoverDelay?.cancel()
        previousApplication = NSWorkspace.shared.frontmostApplication
        needsFileFocus = true
        artifactBrowser.show(folder: session.cwd, refresh: true)
        setPhase(.expanded, animate: !interruptingAnimation)
        panel.makeKeyAndOrderFront(nil)
        artifactTimer?.invalidate()
        artifactTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.phase == .expanded, self.panel.isVisible else { return }
            self.artifactBrowser.show(folder: self.session?.cwd, refresh: true)
        }
    }
    func collapse(restoreFocus: Bool = true) {
        intro.title = session?.terminalTitle ?? "CCS · Your active work"
        intro.toolTip = "Click for files; right-click for active work"
        let wasKey = panel.isKeyWindow
        stopLoading(); setPhase(.collapsed)
        panel.resignKey()
        if wasKey, restoreFocus,
           previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication?.activate(options: [])
        }
        previousApplication = nil
    }
    @objc private func closeCard() { if persistent { collapse() } else { hide() } }
    @objc private func browseFiles() {
        if let session {
            if persistent { collapse(restoreFocus: false) } else { hide() }
            onBrowseFiles?(session)
        }
    }
    func windowDidResignKey(_ notification: Notification) {
        if phase == .expanded { collapse(restoreFocus: false) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { collapse(); return false }
    private func setPhase(_ value: Phase, animate: Bool = true, duringDrag: Bool = false) {
        guard !drag.isTracking || duringDrag else { return }
        morph?.stop(); morph = nil; morphRevision += 1
        let revision = morphRevision
        phase = value
        (panel as? Panel)?.acceptsKeyboard = value == .expanded
        NSLayoutConstraint.deactivate(expandedConstraints + introConstraints + bubbleConstraints)
        stack.isHidden = true; intro.isHidden = true; bubble.isHidden = true
        stack.layoutSubtreeIfNeeded()
        let size: NSSize = value == .expanded ? NSSize(width: 380, height: max(220, stack.fittingSize.height + 32)) : value == .title ? NSSize(width: 320, height: compactSide) : NSSize(width: compactSide, height: compactSide)
        let startFrame = panel.frame, startRadius = cornerRadius, startMarkTop = markTop.constant
        // Give the compact circle equal padding around the unicorn while the firefly overhangs its rim.
        let startInset = surface.backgroundInset
        let endInset = value == .collapsed ? compactSide - markWidth.constant - 2 * markInset : 0
        let endRadius: CGFloat = value == .expanded ? 16 : (size.height - endInset) / 2
        let endMarkTop = markInset
        var frame = panel.frame
        frame.origin.x += frame.width - size.width; frame.origin.y += frame.height - size.height; frame.size = size
        if placement == nil, let tab, let primary = NSScreen.screens.first {
            let terminal = NSRect(x: tab.bounds.minX, y: primary.frame.maxY - tab.bounds.maxY, width: tab.bounds.width, height: tab.bounds.height)
            let screen = NSScreen.screens.max { a, b in
                let x = a.frame.intersection(terminal), y = b.frame.intersection(terminal)
                return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
            } ?? primary
            let visible = screen.visibleFrame
            frame.origin.x = min(max(terminal.maxX - size.width - 16, visible.minX + 12), visible.maxX - size.width - 12)
            frame.origin.y = min(max(terminal.maxY - size.height - 70, visible.minY + 12), visible.maxY - size.height - 12)
        }
        if let placement {
            frame.origin = NSPoint(x: placement.x - size.width, y: placement.y - size.height)
        } else if tab == nil, let screen = NSScreen.main {
            frame.origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 16, y: screen.visibleFrame.maxY - size.height - 50)
        }
        var endMarkTrailing = -markInset
        let startMarkTrailing = markTrailing.constant
        let compact = NSRect(x: frame.maxX - compactSide, y: frame.maxY - compactSide, width: compactSide, height: compactSide)
        if let screen = NSScreen.screens.max(by: {
            let a = $0.frame.intersection(compact), b = $1.frame.intersection(compact)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }) {
            let visible = screen.visibleFrame
            if value == .title {
                // Fit the name on one side of the controls. Both endpoints of the animation
                // put the unicorn at the same screen coordinates.
                let right = min(max(compact.maxX, visible.minX + 8 + compactSide), visible.maxX - 8)
                let left = right - compactSide
                let roomLeft = right - (visible.minX + 8), roomRight = visible.maxX - 8 - left
                let growRight = roomLeft < size.width && roomRight > roomLeft
                frame.size.width = min(size.width, growRight ? roomRight : roomLeft)
                frame.origin.x = growRight ? left : right - frame.width
                endMarkTrailing = right - frame.maxX - markInset
                titleLeading.constant = growRight ? compactSide + 4 : 16
                titleTrailing.constant = growRight ? -16 : -compactSide - 4
            }
            frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
            frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - size.height - 8)
        }
        let update: (CGFloat) -> Void = { [weak self] progress in
            guard let self, revision == self.morphRevision else { return }
            func blend(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
            let next = NSRect(x: blend(startFrame.minX, frame.minX), y: blend(startFrame.minY, frame.minY),
                              width: blend(startFrame.width, frame.width), height: blend(startFrame.height, frame.height))
            self.surfaceWidth.constant = next.width; self.surfaceHeight.constant = next.height
            self.markTop.constant = blend(startMarkTop, endMarkTop)
            self.markTrailing.constant = blend(startMarkTrailing, endMarkTrailing)
            self.cornerRadius = blend(startRadius, endRadius)
            self.surface.setBackground(radius: self.cornerRadius, lowerLeftInset: blend(startInset, endInset))
            self.panel.setFrame(next, display: true, animate: false)
            self.surface.layoutSubtreeIfNeeded()
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
    func setHovering(_ value: Bool) {
        guard terminalContextActive else { return }
        guard !overviewPresented, !drag.isTracking else { return }
        guard hovering != value else { return }
        hovering = value; hoverDelay?.cancel()
        guard phase != .expanded, panel.isVisible else { return }
        if value {
            guard phase == .collapsed else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hovering, self.phase == .collapsed, self.panel.isVisible else { return }
                self.setPhase(.title)
            }
            hoverDelay = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else if phase == .title { collapse(restoreFocus: false) }
    }
    func contextEnded(_ reason: TerminalSessionMonitor.Dismissal) {
        terminalContextActive = false
        switch reason {
        case .disabled: hide()
        case .tabChanged:
            if persistent { showLauncher(clearSession: true) } else { hide() }
        case .spaceChanged:
            // Collapse in place without replaying the title or changing Spaces.
            stopLoading(); hovering = false
            intro.title = session?.terminalTitle ?? "CCS · Your active work"
            setPhase(.collapsed, animate: false); panel.resignKey()
        case .inactive:
            hovering = false
            if phase == .title { collapse(restoreFocus: false) }
            // A click-opened selector can keep focus; the launcher is otherwise inert.
            if !persistent, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
               phase != .expanded { hide() }
        }
    }
    private func stopLoading() {
        hoverDelay?.cancel()
        artifactTimer?.invalidate(); artifactTimer = nil; artifactBrowser.cancel()
    }
    func hide() {
        drag.reset(); interruptedTransition = false
        overviewPresented = false
        speech.hide(); terminalContextActive = false
        stopLoading(); hovering = false
        morph?.stop(); morph = nil; morphRevision += 1; needsFileFocus = false
        panel.orderOut(nil); previousApplication = nil
    }
}
