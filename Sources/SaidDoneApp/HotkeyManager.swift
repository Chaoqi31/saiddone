import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SaidDoneCore

/// Thread-safe mouse-button handlers — read from the CGEvent tap on a non-main thread.
private final class MouseHotkeyState: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [Int: () -> Void] = [:]

    func set(_ button: Int, handler: @escaping () -> Void) {
        lock.lock(); handlers[button] = handler; lock.unlock()
    }

    func removeAll() {
        lock.lock(); handlers.removeAll(); lock.unlock()
    }

    func isHandled(_ button: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return handlers[button] != nil
    }

    func fire(_ button: Int) {
        lock.lock()
        let handler = handlers[button]
        lock.unlock()
        handler?()
    }
}

/// Registers global shortcuts: keyboard via Carbon `RegisterEventHotKey`, mouse buttons via CGEvent tap.
/// Toggle semantics live in AppController (ADR-0006).
@MainActor
final class HotkeyManager {
    private var refs: [EventHotKeyRef?] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private let mouseState = MouseHotkeyState()
    private var nextID: UInt32 = 1
    private var keyboardInstalled = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Register `hotkey`; `onPress` fires on each press. Returns false if registration failed.
    @discardableResult
    func register(_ hotkey: Hotkey, onPress: @escaping () -> Void) -> Bool {
        if let button = hotkey.mouseButton {
            return registerMouse(button: button, onPress: onPress)
        }
        return registerKeyboard(hotkey, onPress: onPress)
    }

    /// Unregister all shortcuts (before re-registering after a config change).
    func unregisterAll() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs.removeAll()
        handlers.removeAll()
        mouseState.removeAll()
        nextID = 1
        tearDownMouseTap()
    }

    fileprivate func fire(id: UInt32) {
        handlers[id]?()
    }

    // MARK: Keyboard (Carbon)

    @discardableResult
    private func registerKeyboard(_ hotkey: Hotkey, onPress: @escaping () -> Void) -> Bool {
        installKeyboardHandlerIfNeeded()
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

    private func installKeyboardHandlerIfNeeded() {
        guard !keyboardInstalled else { return }
        keyboardInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, nil)
    }

    // MARK: Mouse (CGEvent tap — needs Accessibility)

    @discardableResult
    private func registerMouse(button: Int, onPress: @escaping () -> Void) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard installMouseTapIfNeeded() else { return false }
        mouseState.set(button, handler: onPress)
        return true
    }

    @discardableResult
    private func installMouseTapIfNeeded() -> Bool {
        guard eventTap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mouseTapCallback,
            userInfo: Unmanaged.passUnretained(mouseState).toOpaque()
        ) else { return false }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func tearDownMouseTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
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

/// Mouse side buttons arrive as `otherMouseDown`; swallow handled presses so they don't also navigate back/forward.
private func mouseTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard type == .otherMouseDown, let userInfo else {
        return Unmanaged.passRetained(event)
    }
    let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
    let state = Unmanaged<MouseHotkeyState>.fromOpaque(userInfo).takeUnretainedValue()
    guard state.isHandled(button) else {
        return Unmanaged.passRetained(event)
    }
    DispatchQueue.main.async {
        state.fire(button)
    }
    return nil
}
