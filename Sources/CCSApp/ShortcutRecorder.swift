import AppKit
import Carbon

final class ShortcutRecorder: NSButton {
    var onRecord: ((UInt32, UInt32, String) -> Void)?
    var savedTitle = "⌥Space"
    private(set) var recording = false
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(frame: .zero); bezelStyle = .rounded; target = self; action = #selector(record)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func record() { recording = true; title = "Press shortcut… (Esc cancels)"; window?.makeFirstResponder(self) }
    func cancelRecording() { recording = false; title = savedTitle }
    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = savedTitle; return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return }
        var carbon: UInt32 = 0, label = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); label += "⌘" }
        let names: [UInt16: String] = [49:"Space", 36:"Return", 48:"Tab", 123:"←", 124:"→", 125:"↓", 126:"↑", 122:"F1", 120:"F2", 99:"F3", 118:"F4", 96:"F5", 97:"F6", 98:"F7", 100:"F8", 101:"F9", 109:"F10", 103:"F11", 111:"F12"]
        label += names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        recording = false; title = label; onRecord?(UInt32(event.keyCode), carbon, label)
    }
}
