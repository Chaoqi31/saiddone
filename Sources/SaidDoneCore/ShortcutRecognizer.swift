import Foundation

/// Physical input, parsed from CGEvents at the tap boundary.
public enum RawInput: Equatable, Sendable {
    /// After a flagsChanged event: the solo-capable keys held now, plus side-agnostic flags of every held modifier.
    /// The host derives `.fn` from keycode 63 transitions, never from `.maskSecondaryFn` on key events (arrows and
    /// F-keys carry that flag without fn held), and the right-side keys from the NX_DEVICER*KEYMASK bits.
    case modifiers(held: Set<ModifierKey>, flags: ModifierFlags)
    case keyDown(KeyCode, flags: ModifierFlags, isRepeat: Bool)
    case keyUp(KeyCode)
    case mouseDown(Int)
    case mouseUp(Int)
}

public struct GestureID: Hashable, Sendable {
    public let raw: UInt64
    public init(raw: UInt64) { self.raw = raw }
}

public enum Gesture: Equatable, Sendable {
    case pressed(Mode, GestureID)
    /// A held modifier chord grew into a more specific binding (fn → fn⇧). Chords only ever upgrade:
    /// releasing ⇧ a moment before fn must not flip a translation back to dictation.
    case retargeted(Mode, GestureID)
    case released(Mode, GestureID, held: Duration)
    /// After `.pressed`, the key turned out to be a modifier for another key (fn held, then ⌫).
    case aborted(GestureID)
    case escape
}

public struct Reaction: Equatable, Sendable {
    /// Swallow the event so the focused app never sees it: bound combos, bound mouse buttons, a live Esc.
    /// Modifier events are never swallowed.
    public var swallow = false
    public var gestures: [Gesture] = []
    /// When set, the host calls `tick(at:)` at this instant.
    public var wakeAt: ContinuousClock.Instant?
    public init(swallow: Bool = false, gestures: [Gesture] = [], wakeAt: ContinuousClock.Instant? = nil) {
        self.swallow = swallow
        self.gestures = gestures
        self.wakeAt = wakeAt
    }
}

/// Turns physical input into gestures. Pure: the tap host feeds it events and a clock, and performs the reaction.
public struct ShortcutRecognizer: Sendable {
    /// A modifier-only trigger fires only after being held this long without another key, or on a clean release.
    /// fn+⌫ and fn+← then never open the microphone (and never drop AirPods into their low-quality call mode).
    public static let armDelay: Duration = .milliseconds(150)
    /// A stray key pressed this long into a held modifier trigger is typing noise, not "fn used as a modifier":
    /// it no longer aborts the recording.
    public static let abortWindow: Duration = .seconds(1)

    private struct Armed {
        let key: ModifierKey
        let id: GestureID
        let downAt: ContinuousClock.Instant
        var candidate: (mode: Mode, specificity: Int)?
        var emitted: Mode?
        var polluted = false
    }

    private struct Active {
        let id: GestureID
        let mode: Mode
        let downAt: ContinuousClock.Instant
        let code: Int   // key code or mouse button number
    }

    private var shortcuts: Shortcuts
    private var held: Set<ModifierKey> = []
    private var flags: ModifierFlags = []
    private var armed: Armed?
    private var combo: Active?
    private var mouse: Active?
    private var lastID: UInt64 = 0

    public init(_ shortcuts: Shortcuts) { self.shortcuts = shortcuts }

    /// New bindings apply to the next gesture. See `reset()` for the gesture in flight.
    public mutating func update(_ shortcuts: Shortcuts) -> [Gesture] {
        self.shortcuts = shortcuts
        return reset()
    }

    /// Forget physical state (the tap was disabled and re-enabled, so key-ups may have been missed). A gesture that
    /// was pressed but not released gets a zero-length release, which a session treats as a tap: a recording in
    /// progress continues hands-free instead of waiting forever for a key-up that will never come.
    public mutating func reset() -> [Gesture] {
        var releases: [Gesture] = []
        if let armed, let mode = armed.emitted { releases.append(.released(mode, armed.id, held: .zero)) }
        for active in [combo, mouse].compactMap({ $0 }) {
            releases.append(.released(active.mode, active.id, held: .zero))
        }
        held = []
        flags = []
        armed = nil
        combo = nil
        mouse = nil
        return releases
    }

    public mutating func handle(_ input: RawInput, at now: ContinuousClock.Instant, escapeIsLive: Bool) -> Reaction {
        switch input {
        case let .modifiers(newHeld, newFlags):
            return modifiersChanged(newHeld, newFlags, at: now)
        case let .keyDown(code, keyFlags, isRepeat):
            return keyDown(code, keyFlags, isRepeat: isRepeat, at: now, escapeIsLive: escapeIsLive)
        case let .keyUp(code):
            guard let active = combo, active.code == Int(code.rawValue) else { return Reaction() }
            combo = nil
            return Reaction(swallow: true, gestures: [.released(active.mode, active.id, held: now - active.downAt)])
        case let .mouseDown(number):
            guard let button = MouseButton(number), let mode = shortcuts.mode(for: .mouse(button)) else {
                return Reaction()
            }
            if armed?.emitted == nil { armed?.polluted = true }
            let id = nextID()
            mouse = Active(id: id, mode: mode, downAt: now, code: number)
            return Reaction(swallow: true, gestures: [.pressed(mode, id)])
        case let .mouseUp(number):
            guard let active = mouse, active.code == number else { return Reaction() }
            mouse = nil
            return Reaction(swallow: true, gestures: [.released(active.mode, active.id, held: now - active.downAt)])
        }
    }

    public mutating func tick(at now: ContinuousClock.Instant) -> Reaction {
        guard var armed, armed.emitted == nil, !armed.polluted, let candidate = armed.candidate,
              now >= armed.downAt + Self.armDelay else { return Reaction() }
        armed.emitted = candidate.mode
        self.armed = armed
        return Reaction(gestures: [.pressed(candidate.mode, armed.id)])
    }

    // MARK: - Modifier chords

    private mutating func modifiersChanged(_ newHeld: Set<ModifierKey>, _ newFlags: ModifierFlags,
                                           at now: ContinuousClock.Instant) -> Reaction {
        let wentDown = newHeld.subtracting(held)
        let wentUp = held.subtracting(newHeld)
        held = newHeld
        flags = newFlags

        guard var armed else {
            // Releasing keys never presses a chord: only a key going down can arm.
            guard let key = wentDown.contains(.fn) ? .fn : wentDown.sorted(by: { $0.rawValue < $1.rawValue }).first
            else { return Reaction() }
            let id = nextID()
            self.armed = Armed(key: key, id: id, downAt: now, candidate: candidate(for: key))
            return Reaction(wakeAt: now + Self.armDelay)
        }

        if wentUp.contains(armed.key) {
            self.armed = nil
            let heldFor = now - armed.downAt
            if let mode = armed.emitted {
                return Reaction(gestures: [.released(mode, armed.id, held: heldFor)])
            }
            if !armed.polluted, let candidate = armed.candidate {
                return Reaction(gestures: [.pressed(candidate.mode, armed.id),
                                           .released(candidate.mode, armed.id, held: heldFor)])
            }
            return Reaction()
        }

        var reaction = Reaction()
        if let next = candidate(for: armed.key), next.specificity > (armed.candidate?.specificity ?? -1) {
            armed.candidate = next
            if let emitted = armed.emitted, emitted != next.mode {
                armed.emitted = next.mode
                reaction.gestures.append(.retargeted(next.mode, armed.id))
            }
        }
        if armed.emitted == nil, !armed.polluted, let candidate = armed.candidate {
            if now >= armed.downAt + Self.armDelay {
                armed.emitted = candidate.mode
                reaction.gestures.append(.pressed(candidate.mode, armed.id))
            } else {
                reaction.wakeAt = armed.downAt + Self.armDelay
            }
        }
        self.armed = armed
        return reaction
    }

    /// The binding for `key` with the other currently held modifiers; specificity = number of extra modifiers.
    private func candidate(for key: ModifierKey) -> (mode: Mode, specificity: Int)? {
        var with = flags
        if let own = key.flag { with.remove(own) }
        guard let mode = shortcuts.mode(for: .modifierKey(key, with: with)) else { return nil }
        return (mode, with.rawValue.nonzeroBitCount)
    }

    // MARK: - Keys

    private mutating func keyDown(_ code: KeyCode, _ keyFlags: ModifierFlags, isRepeat: Bool,
                                  at now: ContinuousClock.Instant, escapeIsLive: Bool) -> Reaction {
        if code == .escape, escapeIsLive {
            armed?.polluted = true
            armed?.emitted = nil
            return Reaction(swallow: true, gestures: isRepeat ? [] : [.escape])
        }
        if let trigger = Trigger.combo(code, keyFlags), let mode = shortcuts.mode(for: trigger) {
            guard !isRepeat else { return Reaction(swallow: true) }
            // A bound combo is a deliberate press, not "fn used as a modifier". An unfired modifier chord must not
            // fire on release after it; a fired one keeps its release so the session can still tell tap from hold.
            if armed?.emitted == nil { armed?.polluted = true }
            let id = nextID()
            combo = Active(id: id, mode: mode, downAt: now, code: Int(code.rawValue))
            return Reaction(swallow: true, gestures: [.pressed(mode, id)])
        }
        guard var armed, !armed.polluted, now - armed.downAt < Self.abortWindow else { return Reaction() }
        armed.polluted = true
        let wasEmitted = armed.emitted != nil
        armed.emitted = nil
        self.armed = armed
        return Reaction(gestures: wasEmitted ? [.aborted(armed.id)] : [])
    }

    private mutating func nextID() -> GestureID {
        lastID += 1
        return GestureID(raw: lastID)
    }
}

/// Records the next physical input as a Trigger, for the shortcut recorder.
public struct TriggerCapture: Sendable {
    public enum Step: Equatable, Sendable {
        case listening
        case captured(Trigger)
        case cancelled
    }

    private var primary: ModifierKey?
    private var widest: ModifierFlags = []

    public init() {}

    public mutating func handle(_ input: RawInput) -> Step {
        switch input {
        case let .modifiers(held, flags):
            if primary == nil {
                primary = held.contains(.fn) ? .fn : held.sorted(by: { $0.rawValue < $1.rawValue }).first
            }
            guard let primary else { return .listening }
            if held.contains(primary) {
                var with = flags
                if let own = primary.flag { with.remove(own) }
                widest.formUnion(with)
                return .listening
            }
            return .captured(.modifierKey(primary, with: widest))
        case let .keyDown(code, flags, _):
            if code == .escape, flags.isEmpty { return .cancelled }
            if let trigger = Trigger.combo(code, flags) { return .captured(trigger) }
            return .listening
        case let .mouseDown(number):
            guard let button = MouseButton(number) else { return .listening }
            return .captured(.mouse(button))
        case .keyUp, .mouseUp:
            return .listening
        }
    }
}
