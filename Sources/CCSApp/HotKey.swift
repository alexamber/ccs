import AppKit
import Carbon

final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?
    private var lastPress = Date.distantPast
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            if Date().timeIntervalSince(hotkey.lastPress) > 0.3 {
                hotkey.lastPress = Date(); hotkey.onPress?()
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(code: UInt32, modifiers: UInt32) throws {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        let status = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x43435332, id: 1), GetApplicationEventTarget(), 0, &reference)
        if status != noErr { throw NSError(domain: "CCS", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "This shortcut is unavailable. Choose another in Settings, or disable the old CCS Hammerspoon shortcut."]) }
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

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
