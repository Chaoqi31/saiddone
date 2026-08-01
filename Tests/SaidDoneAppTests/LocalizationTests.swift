import Foundation
import XCTest
import SaidDoneCore
@testable import SaidDoneApp

final class LocalizationTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func simplifiedChineseCatalog() throws -> [String: String] {
        let url = repositoryRoot
            .appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    func testCriticalProductFlowCopyHasSimplifiedChineseTranslations() throws {
        let catalog = try simplifiedChineseCatalog()
        let keys = [
            "Press a hotkey once to start, speak, then press it again to stop and insert.",
            "Cloud models by default for the best accuracy — or fully on-device, zero-key and private, if you prefer.",
            "Cloud is recommended for best quality. No API keys? Switch both stages to Local for a fully offline setup.",
            "On-device models are smaller and can mishear technical terms or mixed-language speech more often. Cloud gives the most reliable results.",
            "Microphone access was denied. Enable SaidDone in System Settings → Privacy & Security → Microphone, then click Re-check.",
            "Microphone access is restricted by system policy. Contact your administrator to allow SaidDone.",
            "press to start and stop voice input",
            "press to start and stop translation",
            "press to start and stop asking",
            "App language",
            "Use system language",
            "API keys are stored in Keychain (never in exported JSON). Audio/text leaves your device when Cloud is selected in Providers.",
            "Export / import your configuration as JSON. Cloud API keys stay in Keychain and are omitted from exports.",
            "Provider",
            "Setup progress",
            "Engine readiness",
            "Cloud setup incomplete — open Settings",
            "Cloud speech setup is incomplete — add its API key, Base URL, and model in Settings → Cloud.",
            "Cloud AI setup is incomplete — add its API key, Base URL, and model in Settings → Cloud.",
            "Couldn't start recording — check your microphone input and try again.",
            "Clear all history?",
            "This permanently deletes every saved transcript and its audio recording.",
        ]

        for key in keys {
            let translation = try XCTUnwrap(catalog[key], "Missing zh-Hans translation for: \(key)")
            XCTAssertNotEqual(translation, key, "Untranslated zh-Hans key: \(key)")
        }
    }

    func testReusableOnboardingCopyKeepsLocalizedStringKeyTypes() throws {
        let source = try String(contentsOf: repositoryRoot
            .appendingPathComponent("Sources/SaidDoneApp/Onboarding.swift"))

        XCTAssertTrue(source.contains(
            "private func bullet(_ symbol: String, _ text: LocalizedStringKey)"))
        XCTAssertTrue(source.contains(
            "static let asrModels: [(LocalizedStringKey, String)]"))
        XCTAssertTrue(source.contains(
            "static let llmModels: [(LocalizedStringKey, String)]"))
    }

    func testMicrophoneUsageDescriptionIsLocalized() throws {
        let url = repositoryRoot
            .appendingPathComponent("Resources/zh-Hans.lproj/InfoPlist.strings")
        let data = try Data(contentsOf: url)
        let catalog = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])

        let value = try XCTUnwrap(catalog["NSMicrophoneUsageDescription"])
        XCTAssertTrue(value.contains("麦克风"))
    }

    @MainActor
    func testReopenedOnboardingPreservesSystemLanguageAndCurrentProviders() {
        var config = AppConfig.default
        config.onboardingCompleted = true
        config.appLanguage = ""
        config.asr = ProviderSelection(location: .local, modelID: "speech-model")
        config.llm = ProviderSelection(location: .cloud, modelID: "cloud-model")
        config.cloud.llmBaseURL = "https://example.invalid/v1"

        let model = OnboardingModel()
        model.loadDraft(from: config, effectiveLanguage: "zh-Hans")

        XCTAssertEqual(model.appLanguage, "zh-Hans")
        XCTAssertFalse(model.languageWasChosen)
        XCTAssertEqual(
            model.appLanguageOverride(preserving: config.appLanguage, onboardingCompleted: true), "")
        XCTAssertTrue(model.asrLocal)
        XCTAssertEqual(model.asrModelID, "speech-model")
        XCTAssertFalse(model.llmLocal)
        XCTAssertEqual(model.cloud.llmBaseURL, "https://example.invalid/v1")

        model.chooseLanguage("en")
        XCTAssertTrue(model.languageWasChosen)
        XCTAssertEqual(
            model.appLanguageOverride(preserving: config.appLanguage, onboardingCompleted: true), "en")
    }
}
