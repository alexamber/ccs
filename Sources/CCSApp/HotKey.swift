import AppKit
import Carbon
import CCSCore

final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?
    private var gate = KeyPressGate()
    init() {
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) { hotkey.gate.release() }
            else if hotkey.gate.press() { hotkey.onPress?() }
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(code: UInt32, modifiers: UInt32) throws {
        gate.release()
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        let status = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x43435332, id: 1), GetApplicationEventTarget(), 0, &reference)
        if status != noErr { throw NSError(domain: "CCS", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "This shortcut is unavailable. Choose another in Settings, or disable the old CCS Hammerspoon shortcut."]) }
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
