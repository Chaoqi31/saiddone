import Foundation
import SwiftUI

/// Runtime UI-language switching. `NSLocalizedString` / SwiftUI `Text` resolve through
/// `Bundle.main.localizedString(...)`; we swap `Bundle.main`'s class for one that forwards to a
/// chosen `.lproj`, so the language changes live (no relaunch) once the views re-render.
///
/// Mutated only on the main thread (via LocalizationManager, which is @MainActor), so the unsafe
/// global is fine in practice.
nonisolated(unsafe) private var forwardedBundle: Bundle?

private final class LanguageForwardingBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let b = forwardedBundle {
            return b.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

@MainActor
final class LocalizationManager: ObservableObject {
    /// Active lproj code, e.g. "en" or "zh-Hans". Views key off this to re-render on change.
    @Published private(set) var code: String

    /// Resolve the starting language: an explicit override, else the best system match.
    init(override: String) {
        let resolved = Self.resolve(override)
        self.code = resolved
        Self.installBundle(resolved)
    }

    var locale: Locale { Locale(identifier: code) }

    func set(_ newCode: String) {
        let resolved = Self.resolve(newCode)
        Self.installBundle(resolved)
        code = resolved
        UserDefaults.standard.set([resolved], forKey: "AppleLanguages")
    }

    /// "" → pick zh-Hans if the system is Chinese, otherwise en. Otherwise honor the override if we ship it.
    private static func resolve(_ override: String) -> String {
        if !override.isEmpty { return shipped(override) }
        let sys = Locale.preferredLanguages.first ?? "en"
        return sys.hasPrefix("zh") ? "zh-Hans" : "en"
    }

    /// Map to a language we actually bundle (Resources/*.lproj): en or zh-Hans.
    private static func shipped(_ code: String) -> String {
        code.hasPrefix("zh") ? "zh-Hans" : "en"
    }

    private static func installBundle(_ code: String) {
        if !(Bundle.main is LanguageForwardingBundle) {
            object_setClass(Bundle.main, LanguageForwardingBundle.self)
        }
        forwardedBundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap { Bundle(path: $0) }
    }
}

/// Wraps a window's root so every `Text` re-resolves when the language changes (the `.id(code)`
/// forces SwiftUI to rebuild the subtree).
struct LocalizedRoot<Content: View>: View {
    @ObservedObject var localization: LocalizationManager
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .environment(\.locale, localization.locale)
            .id(localization.code)
    }
}
