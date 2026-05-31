import AppKit
import Carbon.HIToolbox
import SaidDoneCore

/// Registers global hotkeys (Carbon RegisterEventHotKey) and fires a callback on press.
/// One hotkey per Mode (GOALS v1). Toggle semantics live in AppController (ADR-0006).
@MainActor
final class HotkeyManager {
    private var refs: [EventHotKeyRef?] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    /// Register `hotkey`; `onPress` fires on each key-down. Returns false if registration failed.
    @discardableResult
    func register(_ hotkey: Hotkey, onPress: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        handlers[id] = onPress
        HotkeyManager.shared = self

        var hotKeyID = EventHotKeyID(signature: OSType(0x53_44_4F_4E), id: id) // 'SDON'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            HotkeyManager.carbonModifiers(fromCocoa: hotkey.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr else {
            handlers[id] = nil
            return false
        }
        refs.append(ref)
        return true
    }

    fileprivate func fire(id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, nil)
    }

    static weak var shared: HotkeyManager?

    /// Convert Cocoa NSEvent.ModifierFlags rawValue to Carbon modifier mask.
    static func carbonModifiers(fromCocoa raw: UInt) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: raw)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }
}

/// C trampoline — Carbon handlers can't capture Swift context, so route via the shared manager.
private func hotKeyCallback(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    DispatchQueue.main.async {
        HotkeyManager.shared?.fire(id: id)
    }
    return noErr
}
