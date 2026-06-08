import Foundation

/// Shared language lists so users pick from names, never raw ISO codes.
enum Languages {
    /// Translation targets (ISO code → display name). Covers the common cases; the picker also keeps
    /// whatever code is already configured even if it's not listed.
    static let translationTargets: [(code: String, name: String)] = [
        ("en", "English"),
        ("zh", "中文（简体）"),
        ("zh-Hant", "中文（繁體）"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("es", "Español"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("ru", "Русский"),
        ("pt", "Português"),
        ("it", "Italiano"),
        ("ar", "العربية"),
    ]

    /// Primary spoken-language choices for ASR ("" = auto-detect).
    static let spokenLanguages: [(code: String, name: String)] = [
        ("zh", "中文 Chinese"),
        ("en", "English"),
        ("ja", "日本語 Japanese"),
        ("ko", "한국어 Korean"),
        ("es", "Español Spanish"),
        ("fr", "Français French"),
        ("de", "Deutsch German"),
        ("", "Auto-detect"),
    ]

    /// App UI languages (maps to the .lproj bundles shipped in Resources).
    static let ui: [(code: String, name: String)] = [
        ("en", "English"),
        ("zh-Hans", "中文（简体）"),
    ]

    static func translationName(_ code: String) -> String {
        translationTargets.first { $0.code == code }?.name ?? code
    }
}
