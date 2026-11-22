import AppKit
import CCSCore

extension SessionActivity {
    func tint(unattended: Bool) -> NSColor {
        switch self {
        case .attention: return .systemPurple
        case .busy: return .systemYellow
        case .ready: return unattended ? .systemPurple : .systemGreen
        case .unknown: return .secondaryLabelColor
        }
    }
}

final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PickerRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.24).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 7, yRadius: 7).fill()
    }
}

final class StatusDot: NSView {
    let color: NSColor
    let hasDraft: Bool

    init(color: NSColor, hasDraft: Bool) {
        self.color = color
        self.hasDraft = hasDraft
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = 7.7
        let dot = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                         width: diameter, height: diameter)
        let centerDiameter: CGFloat = hasDraft ? 2.5 : diameter
        let inset = (diameter - centerDiameter) / 2
        let center = dot.insetBy(dx: inset, dy: inset)
        color.setFill()
        NSBezierPath(ovalIn: center).fill()
        if hasDraft {
            let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            color.setStroke()
            ring.stroke()
        }
    }
}

final class SessionCell: NSTableCellView {
    init(session s: Session, recent: Bool, terminalOpen: Bool? = nil, unattended: Bool = false, references: [ReportReference] = [], possibleDraft: Bool = false) {
        super.init(frame: .zero)
        let confirmed = terminalOpen == true
        let activity: SessionActivity
        let status: String
        if confirmed {
            // The completion event can arrive before the picker's next history refresh.
            activity = unattended ? .ready : SessionActivity(status: s.status)
            status = unattended ? "Finished" : s.status
        } else {
            activity = .unknown
            status = terminalOpen == false ? "No confirmed Terminal tab" : "Terminal status unavailable"
        }
        let icon: NSView
        if confirmed {
            icon = StatusDot(color: activity.tint(unattended: unattended), hasDraft: possibleDraft)
        } else {
            let symbol = terminalOpen == nil && !s.isSaved ? "questionmark.circle" : "circle"
            let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: status)!)
            image.contentTintColor = activity.tint(unattended: unattended)
            icon = image
        }
        icon.toolTip = possibleDraft ? status + " · Likely unsent input" : status
        let title = NSTextField(labelWithString: s.displayTitle); title.font = .systemFont(ofSize: 13, weight: .medium); title.lineBreakMode = .byTruncatingTail
        let badge = NSTextField(labelWithString: " \(s.provider.title) ")
        badge.font = .systemFont(ofSize: 9, weight: .semibold); badge.textColor = s.provider == .codex ? .systemTeal : .systemOrange
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        let heading = NSStackView(views: [title, badge]); heading.spacing = 6
        let excerpt = s.provider == .codex && !s.prompts.hasPrefix(s.title) ? String(s.prompts.prefix(160)) : s.recap
        let sub = NSTextField(labelWithString: [s.name.map { "[\($0)]" }, recent ? shortPath(s.cwd) : nil, excerpt.nonEmpty].compactMap { $0 }.joined(separator: " · "))
        if let ref = references.first {
            sub.stringValue = ref.action.label + " · " + shortPath(ref.path) + (references.count > 1 ? " (+\(references.count - 1))" : "")
            toolTip = references.map { $0.action.label + " · " + $0.path }.joined(separator: "\n")
        }
        sub.font = .systemFont(ofSize: 11); sub.textColor = .secondaryLabelColor; sub.lineBreakMode = references.isEmpty ? .byTruncatingTail : .byTruncatingMiddle
        let text = NSStackView(views: [heading, sub]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        let stats = NSTextField(labelWithString: s.statistics)
        stats.font = .monospacedDigitSystemFont(ofSize: 11, weight: s.isLarge ? .semibold : .regular); stats.textColor = s.isLarge ? .systemPurple : .secondaryLabelColor
        let age = NSTextField(labelWithString: ageString(s.mtime)); age.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); age.textColor = .secondaryLabelColor; age.alignment = .right
        for view in [icon, text, stats, age] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 12), icon.heightAnchor.constraint(equalToConstant: 12),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: stats.leadingAnchor, constant: -12),
            age.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), age.centerYAnchor.constraint(equalTo: centerYAnchor), age.widthAnchor.constraint(equalToConstant: 36),
            stats.trailingAnchor.constraint(equalTo: age.leadingAnchor, constant: -10), stats.centerYAnchor.constraint(equalTo: centerYAnchor)])
        stats.setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityLabel((possibleDraft ? "Draft, likely unsent input, " : "") + (references.isEmpty ? "" : sub.stringValue + ", ") + "\(s.displayTitle), \(s.provider.title), \(status), \(shortPath(s.cwd))\(s.provider == .claude ? ", \(s.turns) prompts" : "")")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
