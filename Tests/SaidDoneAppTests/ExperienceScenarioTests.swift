import Foundation
import Testing
import SaidDoneCore
@testable import SaidDoneApp

@MainActor
struct ExperienceScenarioTests {
    @Test func manualLaunchOpensWindowEvenWhenLoginItemPreferenceIsEnabled() {
        #expect(AppController.shouldOpenMainWindow(
            onboardingCompleted: true, launchedAsLoginItem: false))
        #expect(!(AppController.shouldOpenMainWindow(
            onboardingCompleted: true, launchedAsLoginItem: true)))
        #expect(!(AppController.shouldOpenMainWindow(
            onboardingCompleted: false, launchedAsLoginItem: false)))
    }

    @Test func hybridLocalSpeechAndConfiguredCloudAIIsReady() {
        var config = AppConfig.default
        config.asr = ProviderSelection(location: .local, modelID: "speech")
        config.llm = ProviderSelection(location: .cloud, modelID: "")
        config.cloud.llmProviderID = "deepseek"
        config.cloud.llmBaseURL = "https://api.deepseek.com/v1"
        config.cloud.llmModel = "deepseek-chat"
        config.cloud.llmAPIKeys["deepseek"] = "test-key"

        #expect((EngineReadiness.issue(
            for: config, asrModelReady: true, llmModelReady: false)) == nil)
    }

    @Test func cloudAIWithoutRequiredKeyFailsBeforeRecording() {
        var config = AppConfig.default
        config.asr = ProviderSelection(location: .local, modelID: "speech")
        config.llm = ProviderSelection(location: .cloud, modelID: "")
        config.cloud.llmProviderID = "deepseek"
        config.cloud.llmBaseURL = "https://api.deepseek.com/v1"
        config.cloud.llmModel = "deepseek-chat"
        config.cloud.llmAPIKeys = [:]

        #expect((EngineReadiness.issue(for: config, asrModelReady: true, llmModelReady: false)) == .cloudAIIncomplete)
    }

    @Test func noKeyLocalCloudPresetCanBeReady() {
        var config = AppConfig.default
        config.asr = ProviderSelection(location: .local, modelID: "speech")
        config.llm = ProviderSelection(location: .cloud, modelID: "")
        config.cloud.llmProviderID = "ollama"
        config.cloud.llmBaseURL = "http://localhost:11434/v1"
        config.cloud.llmModel = "qwen3"
        config.cloud.llmAPIKeys = [:]

        #expect((EngineReadiness.issue(
            for: config, asrModelReady: true, llmModelReady: false)) == nil)
    }

    @Test func cloudSpeechRequiresEndpointModelAndKey() {
        var config = AppConfig.default
        config.asr = ProviderSelection(location: .cloud, modelID: "")
        config.llm = ProviderSelection(location: .local, modelID: "ai")
        config.cloud.asrBaseURL = "https://example.invalid/v1"
        config.cloud.asrModel = "speech-model"
        config.cloud.asrKey = ""

        #expect((EngineReadiness.issue(for: config, asrModelReady: false, llmModelReady: true)) == .cloudSpeechIncomplete)
    }

    @Test func lateSecretHydrationPreservesNewerOrdinarySettings() {
        var hydrated = AppConfig.default
        hydrated.soundsEnabled = true
        hydrated.cloud.llmAPIKeys["deepseek"] = "key-from-keychain"
        hydrated.cloud.asrKey = "asr-from-keychain"

        var editedWhileLoading = AppConfig.default
        editedWhileLoading.soundsEnabled = false
        editedWhileLoading.userProfile = "newer profile"

        let merged = ConfigHydration.mergeSecrets(
            from: hydrated, into: editedWhileLoading)

        #expect(!merged.soundsEnabled)
        #expect(merged.userProfile == "newer profile")
        #expect(merged.cloud.llmAPIKeys["deepseek"] == "key-from-keychain")
        #expect(merged.cloud.asrKey == "asr-from-keychain")
    }

    @Test func lateHydrationNeverOverwritesAUserEnteredSecret() {
        var hydrated = AppConfig.default
        hydrated.cloud.llmAPIKeys["deepseek"] = "older-key"

        var current = AppConfig.default
        current.cloud.llmAPIKeys["deepseek"] = "newer-key"

        let merged = ConfigHydration.mergeSecrets(from: hydrated, into: current)

        #expect(merged.cloud.llmAPIKeys["deepseek"] == "newer-key")
    }

    @Test @MainActor
    func cloudOnlySetupDoesNotSuggestModelDownloads() {
        var config = AppConfig.default
        config.asr = ProviderSelection(location: .cloud, modelID: "")
        config.llm = ProviderSelection(location: .cloud, modelID: "")
        config.cloud.asrBaseURL = "https://example.invalid/v1"
        config.cloud.asrModel = "speech-model"
        config.cloud.asrKey = "test-key"
        config.cloud.llmProviderID = "ollama"
        config.cloud.llmBaseURL = "http://localhost:11434/v1"
        config.cloud.llmModel = "qwen3"

        let model = SetupModel()
        model.sync(from: config)

        #expect(!model.asrLocal)
        #expect(!model.llmLocal)
        #expect(model.asrReady)
        #expect(model.llmReady)
    }

    @Test @MainActor
    func captureStartFailuresAreActionable() {
        let permission = AppController.friendlyCaptureError(
            NSError(domain: "capture", code: 1), microphoneAuthorized: false)
        #expect(permission.contains("Microphone"))

        let missingInput = AppController.friendlyCaptureError(
            CaptureError.invalidInputFormat, microphoneAuthorized: true)
        #expect(missingInput.contains("microphone input"))
    }
}
