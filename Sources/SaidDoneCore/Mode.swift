import Foundation

/// The three things a recording can be for. Each has its own shortcuts.
public enum Mode: String, Codable, CaseIterable, Sendable {
    case dictation
    case translation
    case ask
}

/// What the user asked for, resolved when the recording ends. Stored in History so Retry replays it.
/// Payloads are per case, so a translation without a target cannot be represented.
public enum Request: Codable, Equatable, Sendable {
    case dictate
    case translate(to: Language)
    /// The text that was selected when Ask began (or when the recording switched into Ask). "" = an open question.
    case ask(selection: String)

    public var mode: Mode {
        switch self {
        case .dictate: .dictation
        case .translate: .translation
        case .ask: .ask
        }
    }
}

/// A language code as Whisper and the prompts use it ("en", "zh", "zh-Hant", "ja"). Codable as a bare string.
public struct Language: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var id: String { rawValue }

    public static let english = Language(rawValue: "en")
    public static let chinese = Language(rawValue: "zh")

    public static let translationTargets: [Language] =
        ["en", "zh", "zh-Hant", "ja", "ko", "es", "fr", "de", "ru", "pt", "it", "ar"]
    public static let spoken: [Language] = ["zh", "en", "ja", "ko", "es", "fr", "de"]

    /// The name in the language itself, for pickers.
    public var endonym: String { Self.names[rawValue]?.endonym ?? rawValue }
    /// The English name, for prompts ("Translate into Japanese").
    public var englishName: String { Self.names[rawValue]?.english ?? rawValue }

    private static let names: [String: (endonym: String, english: String)] = [
        "en": ("English", "English"),
        "zh": ("中文（简体）", "Simplified Chinese"),
        "zh-Hant": ("中文（繁體）", "Traditional Chinese"),
        "ja": ("日本語", "Japanese"),
        "ko": ("한국어", "Korean"),
        "es": ("Español", "Spanish"),
        "fr": ("Français", "French"),
        "de": ("Deutsch", "German"),
        "ru": ("Русский", "Russian"),
        "pt": ("Português", "Portuguese"),
        "it": ("Italiano", "Italian"),
        "ar": ("العربية", "Arabic"),
    ]
}

extension Language: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(rawValue: value) }
}
