import Foundation

/// Per-app tone for Polish (GOALS A5′: "能按 App 切语气").
/// e.g. Slack -> casual, Mail -> professional. Matched against the foreground app at insert time.
public struct AppProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Bundle id of the target app, e.g. "com.tinyspeck.slackmacgap". nil = applies to any app.
    public var bundleID: String?
    /// Tone instruction fed to the LLM Provider as PolishContext.
    public var tonePrompt: String

    public init(id: UUID = UUID(), bundleID: String?, tonePrompt: String) {
        self.id = id
        self.bundleID = bundleID
        self.tonePrompt = tonePrompt
    }
}

/// Resolves the active foreground context to a PolishContext. More specific profiles win.
public struct AppProfileStore: Codable, Sendable {
    public var profiles: [AppProfile]
    public init(profiles: [AppProfile] = []) { self.profiles = profiles }

    /// Pick the best-matching profile's tone for the current foreground app.
    /// Specificity: bundleID > wildcard.
    public func context(bundleID: String?) -> PolishContext {
        let matches = profiles.filter { $0.matches(bundleID: bundleID) }
        let best = matches.max { $0.specificity < $1.specificity }
        return PolishContext(tonePrompt: best?.tonePrompt)
    }
}

extension AppProfile {
    func matches(bundleID: String?) -> Bool {
        if let want = self.bundleID, want != bundleID { return false }
        return true
    }

    var specificity: Int {
        bundleID != nil ? 1 : 0
    }
}
