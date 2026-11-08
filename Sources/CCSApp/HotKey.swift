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
