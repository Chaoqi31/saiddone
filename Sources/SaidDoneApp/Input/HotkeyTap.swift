import AppKit
import ApplicationServices
import os
import SaidDoneCore

/// Events SaidDone synthesizes (⌘V, ⌘C) carry this tag, so the tap never mistakes them for the user's typing:
/// pasting a finished job while the user holds fn for the next one must not count as "fn used with another key".
enum SyntheticKeys {
    static let tag: Int64 = 0x5344_4F4E   // "SDON"

    /// A private event source, so keys the user is still holding (fn, ⌃) don't combine into the shortcut.
    static func command(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: tag)
            event.post(tap: .cghidEventTap)
        }
    }
}

/// One CGEvent tap on its own thread: an active tap on the main run loop would stall typing system-wide whenever the
/// main thread is busy. It feeds the pure `ShortcutRecognizer` and hands gestures to the main actor in order.
@MainActor
final class HotkeyTap {
    let gestures: AsyncStream<Gesture>
    private let box: TapBox
    private var started = false

    init(_ shortcuts: Shortcuts) {
        let (stream, continuation) = AsyncStream.makeStream(of: Gesture.self)
        gestures = stream
        box = TapBox(recognizer: ShortcutRecognizer(shortcuts), gestures: continuation)
    }

    /// Needs Accessibility; returns false without it. Call again once it is granted.
    @discardableResult
    func start() -> Bool {
        guard !started else { return true }
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp, .otherMouseDown, .otherMouseUp]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard AXIsProcessTrusted(),
              let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: tapCallback,
                                           userInfo: Unmanaged.passUnretained(box).toOpaque())
        else { return false }
        started = true
        box.port = port
        let thread = Thread { [box] in box.run() }
        thread.name = "SaidDone hotkeys"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    var isRunning: Bool { started }

    func update(_ shortcuts: Shortcuts) { box.update(shortcuts) }

    var escapeIsLive: Bool {
        get { box.state.withLock { $0.escapeIsLive } }
        set { box.state.withLock { $0.escapeIsLive = newValue } }
    }

    /// The shortcut recorder: the next input becomes a trigger (nil when cancelled with Esc). Hotkeys pause meanwhile.
    func captureNextTrigger() async -> Trigger? {
        await withCheckedContinuation { continuation in
            let previous = box.state.withLock { state -> CheckedContinuation<Trigger?, Never>? in
                let previous = state.capture?.done
                state.capture = (TriggerCapture(), continuation)
                return previous
            }
            previous?.resume(returning: nil)
        }
    }

    func cancelCapture() {
        box.state.withLock { state in
            let done = state.capture?.done
            state.capture = nil
            return done
        }?.resume(returning: nil)
    }
}

/// State shared with the tap thread. Each callback holds the lock for one pure recognizer step.
final class TapBox: Sendable {
    struct State: Sendable {
        var recognizer: ShortcutRecognizer
        var escapeIsLive = false
        /// Tracked from keycode 63 alone: arrow and F-keys carry the fn flag without fn being held.
        var fnDown = false
        var capture: (step: TriggerCapture, done: CheckedContinuation<Trigger?, Never>)?
    }

    let state: OSAllocatedUnfairLock<State>
    let gestures: AsyncStream<Gesture>.Continuation
    /// Set once, before the tap thread starts; read by the callback to re-enable a timed-out tap.
    private let portBox = OSAllocatedUnfairLock<CFMachPort?>(uncheckedState: nil)

    var port: CFMachPort? {
        get { portBox.withLockUnchecked { $0 } }
        set { portBox.withLockUnchecked { $0 = newValue } }
    }

    init(recognizer: ShortcutRecognizer, gestures: AsyncStream<Gesture>.Continuation) {
        state = OSAllocatedUnfairLock(initialState: State(recognizer: recognizer))
        self.gestures = gestures
    }

    /// The tap thread's body: serves the tap until the process ends.
    func run() {
        guard let port else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopRun()
    }

    func update(_ shortcuts: Shortcuts) {
        let releases = state.withLock { $0.recognizer.update(shortcuts) }
        releases.forEach { gestures.yield($0) }
    }

    /// Returns true to swallow the event.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            // Key-ups may have been missed while the tap was off.
            let releases = state.withLock { state in
                state.fnDown = false
                return state.recognizer.reset()
            }
            releases.forEach { gestures.yield($0) }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == SyntheticKeys.tag { return false }

        let now = ContinuousClock.now
        // Unchecked: the event is only read inside this synchronous call, on the tap thread.
        let (reaction, finished) = state.withLockUnchecked { state -> (Reaction, (CheckedContinuation<Trigger?, Never>, Trigger?)?) in
            guard let input = Self.input(type, event, fnDown: &state.fnDown) else { return (Reaction(), nil) }
            if var capture = state.capture {
                let step = capture.step.handle(input)
                // Keys and buttons go to the recorder only; modifier changes always reach the system.
                let swallow = type != .flagsChanged
                switch step {
                case .listening:
                    state.capture = capture
                    return (Reaction(swallow: swallow), nil)
                case let .captured(trigger):
                    state.capture = nil
                    _ = state.recognizer.reset()
                    return (Reaction(swallow: swallow), (capture.done, trigger))
                case .cancelled:
                    state.capture = nil
                    _ = state.recognizer.reset()
                    return (Reaction(swallow: swallow), (capture.done, nil))
                }
            }
            return (state.recognizer.handle(input, at: now, escapeIsLive: state.escapeIsLive), nil)
        }
        finished.map { $0.0.resume(returning: $0.1) }
        perform(reaction, now: now)
        return reaction.swallow
    }

    private func perform(_ reaction: Reaction, now: ContinuousClock.Instant) {
        reaction.gestures.forEach { gestures.yield($0) }
        guard let wake = reaction.wakeAt else { return }
        let fireAt = CFAbsoluteTimeGetCurrent() + max(0, now.duration(to: wake).seconds)
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, fireAt, 0, 0, 0) { [self] _ in
            let reaction = state.withLock { $0.capture == nil ? $0.recognizer.tick(at: .now) : Reaction() }
            perform(reaction, now: .now)
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
    }

    private static func input(_ type: CGEventType, _ event: CGEvent, fnDown: inout Bool) -> RawInput? {
        let raw = event.flags
        var flags: ModifierFlags = []
        if raw.contains(.maskControl) { flags.insert(.control) }
        if raw.contains(.maskAlternate) { flags.insert(.option) }
        if raw.contains(.maskShift) { flags.insert(.shift) }
        if raw.contains(.maskCommand) { flags.insert(.command) }
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .flagsChanged:
            if code == 63 { fnDown = raw.contains(.maskSecondaryFn) }
            var held: Set<ModifierKey> = fnDown ? [.fn] : []
            // NX_DEVICER*KEYMASK: which side of each modifier is down.
            if raw.rawValue & 0x10 != 0 { held.insert(.rightCommand) }
            if raw.rawValue & 0x40 != 0 { held.insert(.rightOption) }
            if raw.rawValue & 0x2000 != 0 { held.insert(.rightControl) }
            if raw.rawValue & 0x04 != 0 { held.insert(.rightShift) }
            return .modifiers(held: held, flags: flags)
        case .keyDown:
            return .keyDown(KeyCode(code), flags: flags, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp:
            return .keyUp(KeyCode(code))
        case .otherMouseDown:
            return .mouseDown(Int(event.getIntegerValueField(.mouseEventButtonNumber)))
        case .otherMouseUp:
            return .mouseUp(Int(event.getIntegerValueField(.mouseEventButtonNumber)))
        default:
            return nil
        }
    }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                         userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let box = Unmanaged<TapBox>.fromOpaque(userInfo).takeUnretainedValue()
    return box.handle(type, event) ? nil : Unmanaged.passUnretained(event)
}
