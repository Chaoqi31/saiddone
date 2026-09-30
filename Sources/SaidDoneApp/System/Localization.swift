import AppKit
import Foundation
import Observation
import SaidDoneCore
import SwiftUI

/// Switches the interface language at runtime. Every string lookup in the app goes through `Bundle.main`, whose class
/// is swapped for one that forwards to the chosen `.lproj`; SwiftUI re-renders when `locale` changes.
@MainActor @Observable
final class Localization {
    private(set) var locale: Locale

    init(_ language: InterfaceLanguage) {
        let code = Self.resolve(language)
        Self.install(code)
        locale = Locale(identifier: code)
    }

    func apply(_ language: InterfaceLanguage) {
        let code = Self.resolve(language)
        Self.install(code)
        locale = Locale(identifier: code)
        // Also makes the next launch start in this language before any window exists.
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
    }

    /// The shipped language to use: English or Simplified Chinese.
    static func resolve(_ language: InterfaceLanguage) -> String {
        switch language {
        case .english: return "en"
        case .simplifiedChinese: return "zh-Hans"
        case .system:
            // The global list, not Locale.preferredLanguages: that one includes this app's own override.
            let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"]
            let first = (global as? [String])?.first ?? Locale.preferredLanguages.first ?? "en"
            return first.hasPrefix("zh") ? "zh-Hans" : "en"
        }
    }

    static func install(_ code: String) {
        if !(Bundle.main is ForwardingBundle) { object_setClass(Bundle.main, ForwardingBundle.self) }
        ForwardingBundle.target = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
    }
}

/// `Bundle.main` after `Localization.install`: string lookups go to the chosen language's bundle.
final class ForwardingBundle: Bundle, @unchecked Sendable {
    nonisolated(unsafe) static var target: Bundle?

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let target = Self.target { return target.localizedString(forKey: key, value: value, table: tableName) }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

/// A localized string for AppKit and model code; SwiftUI views use `Text(tr("…"))`. Keys are the English text, and
/// `arguments` fill the translation's `%@` and `%lld`. Goes through `Bundle.main.localizedString`, which the
/// language switch overrides.
func tr(_ key: String, _ arguments: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}
