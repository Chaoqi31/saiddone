import XCTest
import SaidDoneCore
@testable import SaidDoneApp

final class ExperienceScenarioTests: XCTestCase {
    func testManualLaunchOpensWindowEvenWhenLoginItemPreferenceIsEnabled() {
        XCTAssertTrue(AppController.shouldOpenMainWindow(
            onboardingCompleted: true, launchedAsLoginItem: false))
        XCTAssertFalse(AppController.shouldOpenMainWindow(
            onboardingCompleted: true, launchedAsLoginItem: true))
        XCTAssertFalse(AppController.shouldOpenMainWindow(
            onboardingCompleted: false, launchedAsLoginItem: false))
    }

    func testHybridLocalSpeechAndConfiguredCloudAIIsReady() {
        var config = AppConfig.default
        config.asr = ProviderSelection(location: .local, modelID: "speech")
        config.llm = ProviderSelection(location: .cloud, modelID: "")
        config.cloud.llmProviderID = "deepseek"
        config.cloud.llmBaseURL = "https://api.deepseek.com/v1"
        config.cloud.llmModel = "deepseek-chat"
        config.cloud.llmAPIKeys["deepseek"] = "test-key"

        XCTAssertNil(EngineReadiness.issue(
            for: config, asrModelReady: true, llmModelReady: false))
    }

    func testCloudAIWithoutRequiredKeyFailsBeforeRecording() {
        var config = AppConfig.default
        config.asr = ProviderSelection(location: .local, modelID: "speech")
        config.llm = ProviderSelection(location: .cloud, modelID: "")
        config.cloud.llmProviderID = "deepseek"
        config.cloud.llmBaseURL = "https://api.deepseek.com/v1"
        config.cloud.llmModel = "deepseek-chat"
        config.cloud.llmAPIKeys = [:]

        XCTAssertEqual(
            EngineReadiness.issue(for: config, asrModelReady: true, llmModelReady: false),
            .cloudAIIncomplete)
    }

    func testNoKeyLocalCloudPresetCanBeReady() {
        var config = AppConfig.default
        config.asr = ProviderSelection(location: .local, modelID: "speech")
        config.llm = ProviderSelection(location: .cloud, modelID: "")
        config.cloud.llmProviderID = "ollama"
        config.cloud.llmBaseURL = "http://localhost:11434/v1"
        config.cloud.llmModel = "qwen3"
        config.cloud.llmAPIKeys = [:]

        XCTAssertNil(EngineReadiness.issue(
            for: config, asrModelReady: true, llmModelReady: false))
    }

    func testCloudSpeechRequiresEndpointModelAndKey() {
        var config = AppConfig.default
        config.asr = ProviderSelection(location: .cloud, modelID: "")
        config.llm = ProviderSelection(location: .local, modelID: "ai")
        config.cloud.asrBaseURL = "https://example.invalid/v1"
        config.cloud.asrModel = "speech-model"
        config.cloud.asrKey = ""

        XCTAssertEqual(
            EngineReadiness.issue(for: config, asrModelReady: false, llmModelReady: true),
            .cloudSpeechIncomplete)
    }

    func testLateSecretHydrationPreservesNewerOrdinarySettings() {
        var hydrated = AppConfig.default
        hydrated.soundsEnabled = true
        hydrated.cloud.llmAPIKeys["deepseek"] = "key-from-keychain"
        hydrated.cloud.asrKey = "asr-from-keychain"

        var editedWhileLoading = AppConfig.default
        editedWhileLoading.soundsEnabled = false
        editedWhileLoading.userProfile = "newer profile"

        let merged = ConfigHydration.mergeSecrets(
            from: hydrated, into: editedWhileLoading)

        XCTAssertFalse(merged.soundsEnabled)
        XCTAssertEqual(merged.userProfile, "newer profile")
        XCTAssertEqual(merged.cloud.llmAPIKeys["deepseek"], "key-from-keychain")
        XCTAssertEqual(merged.cloud.asrKey, "asr-from-keychain")
    }

    func testLateHydrationNeverOverwritesAUserEnteredSecret() {
        var hydrated = AppConfig.default
        hydrated.cloud.llmAPIKeys["deepseek"] = "older-key"

        var current = AppConfig.default
        current.cloud.llmAPIKeys["deepseek"] = "newer-key"

        let merged = ConfigHydration.mergeSecrets(from: hydrated, into: current)

        XCTAssertEqual(merged.cloud.llmAPIKeys["deepseek"], "newer-key")
    }

    @MainActor
    func testCloudOnlySetupDoesNotSuggestModelDownloads() {
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

        XCTAssertFalse(model.asrLocal)
        XCTAssertFalse(model.llmLocal)
        XCTAssertTrue(model.asrReady)
        XCTAssertTrue(model.llmReady)
    }

    @MainActor
    func testCaptureStartFailuresAreActionable() {
        let permission = AppController.friendlyCaptureError(
            NSError(domain: "capture", code: 1), microphoneAuthorized: false)
        XCTAssertTrue(permission.contains("Microphone"))

        let missingInput = AppController.friendlyCaptureError(
            CaptureError.invalidInputFormat, microphoneAuthorized: true)
        XCTAssertTrue(missingInput.contains("microphone input"))
    }
}
