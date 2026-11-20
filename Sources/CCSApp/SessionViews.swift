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

final class SessionCell: NSTableCellView {
    init(session s: Session, recent: Bool, terminalOpen: Bool? = nil, unattended: Bool = false) {
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
        let icon = NSImageView(image: NSImage(systemSymbolName: confirmed ? "circle.fill" : terminalOpen == nil && !s.isSaved ? "questionmark.circle" : "circle", accessibilityDescription: status)!)
        icon.contentTintColor = activity.tint(unattended: unattended)
        icon.toolTip = status
        let title = NSTextField(labelWithString: s.displayTitle); title.font = .systemFont(ofSize: 13, weight: .medium); title.lineBreakMode = .byTruncatingTail
        let badge = NSTextField(labelWithString: " \(s.provider.title) ")
        badge.font = .systemFont(ofSize: 9, weight: .semibold); badge.textColor = s.provider == .codex ? .systemTeal : .systemOrange
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        let heading = NSStackView(views: [title, badge]); heading.spacing = 6
        let excerpt = s.provider == .codex && !s.prompts.hasPrefix(s.title) ? String(s.prompts.prefix(160)) : s.recap
        let sub = NSTextField(labelWithString: [s.name.map { "[\($0)]" }, recent ? shortPath(s.cwd) : nil, excerpt.nonEmpty].compactMap { $0 }.joined(separator: " · "))
        sub.font = .systemFont(ofSize: 11); sub.textColor = .secondaryLabelColor; sub.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [heading, sub]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        let stats = NSTextField(labelWithString: s.statistics)
        stats.font = .monospacedDigitSystemFont(ofSize: 11, weight: s.isLarge ? .semibold : .regular); stats.textColor = s.isLarge ? .systemPurple : .secondaryLabelColor
        let age = NSTextField(labelWithString: ageString(s.mtime)); age.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); age.textColor = .secondaryLabelColor; age.alignment = .right
        for view in [icon, text, stats, age] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 10), icon.heightAnchor.constraint(equalToConstant: 10),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: stats.leadingAnchor, constant: -12),
            age.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), age.centerYAnchor.constraint(equalTo: centerYAnchor), age.widthAnchor.constraint(equalToConstant: 36),
            stats.trailingAnchor.constraint(equalTo: age.leadingAnchor, constant: -10), stats.centerYAnchor.constraint(equalTo: centerYAnchor)])
        stats.setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityLabel("\(s.displayTitle), \(s.provider.title), \(status), \(shortPath(s.cwd))\(s.provider == .claude ? ", \(s.turns) prompts" : "")")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
