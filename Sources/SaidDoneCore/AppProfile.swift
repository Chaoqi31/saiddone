import Foundation

/// Per-app (and optional URL) tone for Polish (GOALS A5′: "能按 App 切语气").
/// e.g. Slack -> casual, Mail -> professional. Matched against the foreground app at insert time.
public struct AppProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Bundle id of the target app, e.g. "com.tinyspeck.slackmacgap". nil = applies to any app.
    public var bundleID: String?
    /// Optional substring matched against the foreground browser URL (only meaningful for browsers).
    public var urlContains: String?
    /// Tone instruction fed to the LLM Provider as PolishContext.
    public var tonePrompt: String

    public init(id: UUID = UUID(), bundleID: String?, urlContains: String? = nil, tonePrompt: String) {
        self.id = id
        self.bundleID = bundleID
        self.urlContains = urlContains
        self.tonePrompt = tonePrompt
    }
}

/// Resolves the active foreground context to a PolishContext. More specific profiles win.
public struct AppProfileStore: Codable, Sendable {
    public var profiles: [AppProfile]
    public init(profiles: [AppProfile] = []) { self.profiles = profiles }

    /// Pick the best-matching profile's tone for the current foreground app/url.
    /// Specificity: bundleID+url > bundleID > url-only > wildcard.
    public func context(bundleID: String?, url: String?) -> PolishContext {
        let matches = profiles.filter { $0.matches(bundleID: bundleID, url: url) }
        let best = matches.max { $0.specificity < $1.specificity }
        return PolishContext(tonePrompt: best?.tonePrompt)
    }
}

extension AppProfile {
    func matches(bundleID: String?, url: String?) -> Bool {
        if let want = self.bundleID, want != bundleID { return false }
        if let needle = self.urlContains {
            guard let url, url.localizedCaseInsensitiveContains(needle) else { return false }
        }
        return true
    }

    var specificity: Int {
        (bundleID != nil ? 2 : 0) + (urlContains != nil ? 1 : 0)
    }
}
