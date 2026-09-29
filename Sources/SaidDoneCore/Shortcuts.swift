import Foundation

/// Side-agnostic modifier flags held together with a trigger key.
public struct ModifierFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let control = ModifierFlags(rawValue: 1 << 0)
    public static let option = ModifierFlags(rawValue: 1 << 1)
    public static let shift = ModifierFlags(rawValue: 1 << 2)
    public static let command = ModifierFlags(rawValue: 1 << 3)
}

/// A physical key that can trigger on its own. Left-side ⌘⌥⌃⇧ are excluded: they are too busy in normal shortcuts.
public enum ModifierKey: String, Codable, CaseIterable, Sendable {
    case fn, rightCommand, rightOption, rightControl, rightShift

    /// The side-agnostic flag this key also sets while held (nil for fn).
    public var flag: ModifierFlags? {
        switch self {
        case .fn: nil
        case .rightCommand: .command
        case .rightOption: .option
        case .rightControl: .control
        case .rightShift: .shift
        }
    }
}

/// A hardware virtual key code (kVK_*), independent of the keyboard layout.
public struct KeyCode: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ rawValue: UInt16) { self.rawValue = rawValue }

    public static let escape = KeyCode(53)
    public static let space = KeyCode(49)

    /// F1–F20 may trigger without a modifier; any other key needs ⌃, ⌥ or ⌘ so ordinary typing never fires.
    public var isFunctionKey: Bool { Self.functionKeys.contains(rawValue) }
    static let functionKeys: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]
}

/// A mouse button that can trigger. Left and right click never can.
public struct MouseButton: Codable, Hashable, Sendable {
    public let number: Int   // NSEvent numbering: 2 = middle, 3 / 4 = side buttons
    public init?(_ number: Int) {
        guard number >= 2 else { return nil }
        self.number = number
    }
}

public enum Trigger: Codable, Hashable, Sendable {
    /// A modifier key alone or with side-agnostic modifiers: fn, fn ⇧, fn ⌃, right ⌥.
    case modifierKey(ModifierKey, with: ModifierFlags)
    /// A regular key with modifiers: ⌃⌥D. Build with `combo(_:_:)`.
    case keyCombo(KeyCode, ModifierFlags)
    case mouse(MouseButton)

    /// nil unless the combo can't fire during ordinary typing (needs ⌃, ⌥ or ⌘, or an F-key).
    public static func combo(_ key: KeyCode, _ modifiers: ModifierFlags) -> Trigger? {
        guard key != .escape else { return nil }
        guard key.isFunctionKey || !modifiers.isDisjoint(with: [.control, .option, .command]) else { return nil }
        return .keyCombo(key, modifiers)
    }

    public static let fn = Trigger.modifierKey(.fn, with: [])

    public var usesFn: Bool {
        if case .modifierKey(.fn, _) = self { return true }
        return false
    }

    /// Display order inside one mode: modifier triggers, then key combos, then mouse buttons.
    var sortRank: Int {
        switch self {
        case .modifierKey: 0
        case .keyCombo: 1
        case .mouse: 2
        }
    }
}

/// Trigger → mode. Keyed by trigger, so one trigger can never start two modes.
public struct Shortcuts: Equatable, Sendable {
    public private(set) var owners: [Trigger: Mode]

    public init(_ owners: [Trigger: Mode] = [:]) { self.owners = owners }

    /// fn / fn⇧ / fn⌃ plus ⌃⌥D / ⌃⌥T / ⌃⌥A for keyboards without a 🌐 key.
    public static let `default` = Shortcuts([
        .fn: .dictation,
        .modifierKey(.fn, with: .shift): .translation,
        .modifierKey(.fn, with: .control): .ask,
        .keyCombo(KeyCode(2), [.control, .option]): .dictation,
        .keyCombo(KeyCode(17), [.control, .option]): .translation,
        .keyCombo(KeyCode(0), [.control, .option]): .ask,
    ])

    public func mode(for trigger: Trigger) -> Mode? { owners[trigger] }

    public func triggers(for mode: Mode) -> [Trigger] {
        owners.filter { $0.value == mode }.map(\.key)
            .sorted { ($0.sortRank, "\($0)") < ($1.sortRank, "\($1)") }
    }

    /// Binds `trigger`, returning the mode it was taken from (so the UI can say "moved from Translation").
    @discardableResult
    public mutating func bind(_ trigger: Trigger, to mode: Mode) -> Mode? {
        let previous = owners[trigger]
        owners[trigger] = mode
        return previous == mode ? nil : previous
    }

    public mutating func unbind(_ trigger: Trigger) { owners[trigger] = nil }

    public var usesFn: Bool { owners.keys.contains(where: \.usesFn) }
}

extension Shortcuts: Codable {
    private struct Binding: Codable {
        var trigger: Trigger
        var mode: Mode
    }

    public init(from decoder: Decoder) throws {
        let bindings = try decoder.singleValueContainer().decode([Binding].self)
        owners = Dictionary(bindings.map { ($0.trigger, $0.mode) }, uniquingKeysWith: { first, _ in first })
    }

    public func encode(to encoder: Encoder) throws {
        let bindings = Mode.allCases.flatMap { mode in triggers(for: mode).map { Binding(trigger: $0, mode: mode) } }
        var container = encoder.singleValueContainer()
        try container.encode(bindings)
    }
}
