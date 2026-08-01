import Foundation
import SaidDoneCore

/// A user-actionable reason recording cannot start yet.
enum EngineReadinessIssue: Equatable {
    case speechModelMissing
    case aiModelMissing
    case cloudSpeechIncomplete
    case cloudAIIncomplete

    var message: String {
        switch self {
        case .speechModelMissing:
            return NSLocalizedString(
                "Speech model not downloaded — open Settings → Setup.",
                comment: "missing model")
        case .aiModelMissing:
            return NSLocalizedString(
                "AI model not downloaded — open Settings → Setup.",
                comment: "missing model")
        case .cloudSpeechIncomplete:
            return NSLocalizedString(
                "Cloud speech setup is incomplete — add its API key, Base URL, and model in Settings → Cloud.",
                comment: "cloud ASR setup")
        case .cloudAIIncomplete:
            return NSLocalizedString(
                "Cloud AI setup is incomplete — add its API key, Base URL, and model in Settings → Cloud.",
                comment: "cloud LLM setup")
        }
    }

    var menuMessage: String {
        switch self {
        case .speechModelMissing, .aiModelMissing:
            return NSLocalizedString("Model not downloaded — open Setup", comment: "menu")
        case .cloudSpeechIncomplete, .cloudAIIncomplete:
            return NSLocalizedString("Cloud setup incomplete — open Settings", comment: "menu")
        }
    }
}

enum EngineReadiness {
    static func issue(
        for config: AppConfig,
        asrModelReady: Bool,
        llmModelReady: Bool
    ) -> EngineReadinessIssue? {
        if config.asr.location == .local {
            if !asrModelReady { return .speechModelMissing }
        } else if !cloudSpeechConfigured(config.cloud) {
            return .cloudSpeechIncomplete
        }

        if config.llm.location == .local {
            if !llmModelReady { return .aiModelMissing }
        } else if !cloudAIConfigured(config.cloud) {
            return .cloudAIIncomplete
        }

        return nil
    }

    static func cloudSpeechConfigured(_ cloud: CloudConfig) -> Bool {
        hasText(cloud.asrKey) && hasText(cloud.asrBaseURL) && hasText(cloud.asrModel)
    }

    static func cloudAIConfigured(_ cloud: CloudConfig) -> Bool {
        guard hasText(cloud.llmBaseURL), hasText(cloud.llmModel) else { return false }
        let provider = CloudProviderRegistry.builtIn.first { $0.id == cloud.llmProviderID }
        guard provider?.needsAPIKey != false else { return true }
        return hasText(cloud.llmAPIKeys[cloud.llmProviderID] ?? "")
    }

    private static func hasText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
