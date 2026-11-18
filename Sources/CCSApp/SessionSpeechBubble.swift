import AppKit
import QuartzCore

/// A separate, nonactivating speech balloon. Its tail points at the unicorn;
/// it never replaces the session-name pill or steals keyboard focus.
final class SessionSpeechBubble: NSObject {
    final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private final class Balloon: NSView {
        static let trailHeight: CGFloat = 24
        var tailOnTop = true { didSet { if tailOnTop != oldValue { needsLayout = true } } }
        var tailX: CGFloat = 280 { didSet { if tailX != oldValue { needsLayout = true } } }
        private let material = NSVisualEffectView()
        private let mask = CAShapeLayer(), outline = CAShapeLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            material.material = .popover; material.state = .active; material.blendingMode = .behindWindow
            material.wantsLayer = true; material.layer?.mask = mask
            material.layer?.addSublayer(outline); addSubview(material)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            material.frame = bounds
            let inset = bounds.insetBy(dx: 1, dy: 1)
            let body = NSRect(x: inset.minX, y: inset.minY + (tailOnTop ? 0 : Self.trailHeight),
                              width: inset.width, height: inset.height - Self.trailHeight)
            let path = CGMutablePath()
            path.addRoundedRect(in: body, cornerWidth: 16, cornerHeight: 16)
            // A short, quiet thought trail connects the card to the mouth.
            let x = min(max(tailX, 36), bounds.width - 20)
            let ovals: [(dx: CGFloat, gap: CGFloat, width: CGFloat, height: CGFloat)] = [
                (-10, 4, 10, 7), (0, 17, 5, 4)
            ]
            for oval in ovals {
                let y = tailOnTop ? body.maxY + oval.gap : body.minY - oval.gap - oval.height
                path.addEllipse(in: CGRect(x: x + oval.dx - oval.width / 2, y: y,
                                          width: oval.width, height: oval.height))
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            mask.path = path; outline.path = path; outline.lineWidth = 0.75
            updateColors()
            CATransaction.commit()
        }
        private func updateColors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                material.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.94
                outline.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.24).cgColor
                outline.strokeColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            }
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance(); updateColors()
        }
    }
    private final class MessageButton: NSButton {
        var onHover: ((Bool) -> Void)?
        private var area: NSTrackingArea?
        private let event = NSTextField(labelWithString: ""), topic = NSTextField(wrappingLabelWithString: ""), symbol = NSImageView()
        override init(frame: NSRect) {
            super.init(frame: frame)
            title = ""; isBordered = false
            event.font = .systemFont(ofSize: 12); event.textColor = .labelColor
            topic.font = .systemFont(ofSize: 13, weight: .semibold); topic.textColor = .labelColor
            topic.maximumNumberOfLines = 2; topic.cell?.wraps = true; topic.cell?.usesSingleLineMode = false
            event.lineBreakMode = .byTruncatingTail; topic.lineBreakMode = .byWordWrapping
            symbol.imageScaling = .scaleProportionallyDown
            for view in [symbol, event, topic] { view.setAccessibilityElement(false); addSubview(view) }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func configure(_ update: SessionUpdate) {
            event.stringValue = update.message; topic.stringValue = update.target.title
            symbol.image = NSImage(systemSymbolName: update.kind == .finished ? "checkmark" : "exclamationmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            symbol.contentTintColor = .systemPurple
            needsLayout = true
        }
        override func layout() {
            super.layout()
            topic.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 22)
            symbol.frame = NSRect(x: 0, y: bounds.height - 16, width: 14, height: 14)
            event.frame = NSRect(x: 20, y: bounds.height - 18, width: bounds.width - 20, height: 18)
        }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(next); area = next
        }
        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }
    let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 90), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let balloon = Balloon(), button = MessageButton()
    private var update: SessionUpdate?
    var onHover: ((Bool) -> Void)?, onOpen: ((SessionUpdate) -> Void)?
    override init() {
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.contentView = balloon
        button.target = self; button.action = #selector(open)
        button.onHover = { [weak self] value in self?.onHover?(value) }
        balloon.addSubview(button)
    }
    func show(_ update: SessionUpdate, beside parent: NSWindow, anchor: NSRect) {
        if self.update?.id != update.id {
            button.configure(update)
            button.toolTip = update.message + "\n" + update.target.title + "\nClick to open session"
            button.setAccessibilityLabel(update.message + ", " + update.target.title)
        }
        self.update = update
        let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parent.frame
        let topicWidth = (update.target.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
        let eventWidth = (update.message as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width + 20
        let width = min(304, screen.width - 24, max(240, ceil(max(topicWidth, eventWidth)) + 32))
        let bodyHeight: CGFloat = topicWidth > width - 32 ? 80 : 62
        let height = bodyHeight + Balloon.trailHeight
        let mouth = NSPoint(x: anchor.midX, y: anchor.minY + anchor.height * 0.08)
        let below = mouth.y - height - 2 >= screen.minY + 8
        balloon.tailOnTop = below
        let x = min(max(mouth.x - width + 42, screen.minX + 8), screen.maxX - width - 8)
        let y = below ? mouth.y - height - 2 : anchor.maxY + 4
        balloon.tailX = min(max(mouth.x - x, 36), width - 20)
        let frame = NSRect(x: x, y: min(max(y, screen.minY + 8), screen.maxY - height - 8), width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        button.frame = NSRect(x: 16, y: 12 + (below ? 0 : Balloon.trailHeight), width: width - 32, height: bodyHeight - 24)
        balloon.layoutSubtreeIfNeeded()
        if panel.parent !== parent { panel.parent?.removeChildWindow(panel); parent.addChildWindow(panel, ordered: .above) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
    func hide() { panel.orderOut(nil); update = nil }
    @objc func open() { if let update { onOpen?(update) } }
}
