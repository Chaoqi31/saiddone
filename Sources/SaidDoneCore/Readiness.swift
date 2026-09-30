import Foundation

/// Something that keeps the user from dictating, or makes it worse.
public enum Issue: Hashable, Sendable {
    case microphoneNotAllowed
    /// The hotkey tap and pasting both need Accessibility.
    case accessibilityNotAllowed
    /// 🌐 is set to switch input sources, show emoji or start Dictation, so pressing fn does that too.
    case globeKeyAssigned
    case modelNotInstalled(LocalModel)
    /// On-device AI is chosen, but this build can't run it.
    case onDeviceAIUnavailable
    case credentialMissing(VendorID)
    /// A cloud endpoint has no model name yet.
    case speechModelNotChosen
    case aiModelNotChosen

    public var blocksRecording: Bool { self != .globeKeyAssigned }
}

/// What the system and the stores currently say. Gathered by the shell; judged here.
public struct SetupFacts: Equatable, Sendable {
    public var microphoneAllowed: Bool
    public var accessibilityAllowed: Bool
    public var globeKeyFree: Bool
    public var installed: Set<LocalModel>
    /// Vendors with a non-empty key.
    public var credentials: Set<VendorID>
    /// The build carries what on-device AI needs to run.
    public var onDeviceAI: Bool

    public init(microphoneAllowed: Bool, accessibilityAllowed: Bool, globeKeyFree: Bool,
                installed: Set<LocalModel>, credentials: Set<VendorID>, onDeviceAI: Bool) {
        self.microphoneAllowed = microphoneAllowed
        self.accessibilityAllowed = accessibilityAllowed
        self.globeKeyFree = globeKeyFree
        self.installed = installed
        self.credentials = credentials
        self.onDeviceAI = onDeviceAI
    }
}

/// One answer to "can the user dictate, and if not, why". Onboarding, Home, the status menu and the recording guard
/// all read it, so they can't disagree.
public enum Readiness {
    /// In the order the user should fix them.
    public static func issues(_ prefs: Preferences, _ facts: SetupFacts) -> [Issue] {
        var issues: [Issue] = []
        if !facts.microphoneAllowed { issues.append(.microphoneNotAllowed) }
        if !facts.accessibilityAllowed { issues.append(.accessibilityNotAllowed) }
        if case let .cloud(endpoint) = prefs.speech, endpoint.model.isEmpty { issues.append(.speechModelNotChosen) }
        if case let .cloud(endpoint) = prefs.ai, endpoint.model.isEmpty { issues.append(.aiModelNotChosen) }
        // No point downloading an on-device AI model this build can't run.
        let aiRuns = prefs.ai.localModel == nil || facts.onDeviceAI
        if !aiRuns { issues.append(.onDeviceAIUnavailable) }
        for model in [prefs.speech.localModel, aiRuns ? prefs.ai.localModel : nil].compactMap({ $0 })
        where !facts.installed.contains(model) {
            issues.append(.modelNotInstalled(model))
        }
        var vendors: [VendorID] = []
        for vendor in [prefs.speech.vendor, prefs.ai.vendor].compactMap({ $0 }) where !vendors.contains(vendor) {
            vendors.append(vendor)
        }
        for vendor in vendors where requiresKey(vendor) && !facts.credentials.contains(vendor) {
            issues.append(.credentialMissing(vendor))
        }
        if prefs.shortcuts.usesFn && !facts.globeKeyFree { issues.append(.globeKeyAssigned) }
        return issues
    }

    public static func recordingBlocker(_ prefs: Preferences, _ facts: SetupFacts) -> Issue? {
        issues(prefs, facts).first(where: \.blocksRecording)
    }

    private static func requiresKey(_ vendor: VendorID) -> Bool {
        if vendor == .volcengine { return true }
        return (CloudPreset.chat(vendor) ?? CloudPreset.speech(vendor))?.requiresKey ?? true
    }
}
