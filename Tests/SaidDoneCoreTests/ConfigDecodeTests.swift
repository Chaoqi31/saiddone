import Foundation
import Testing
@testable import SaidDoneCore

struct ConfigDecodeTests {
    /// A config.json written before `proxyHost`/`proxyPort` existed must still decode (not silently
    /// reset to the local default — that bug once knocked a cloud DeepSeek setup back to local).
    @Test func decodesCloudConfigMissingNewerFields() throws {
        let json = """
        {
          "dictationHotkey": {"keyCode": 2, "modifiers": 786432},
          "translationHotkey": {"keyCode": 17, "modifiers": 786432},
          "asr": {"location": "local", "modelID": "x"},
          "llm": {"location": "cloud", "modelID": "y"},
          "cloud": {"llmKey": "k", "llmBaseURL": "https://api.deepseek.com", "llmModel": "deepseek-v4-flash"}
        }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(cfg.llm.location == .cloud)                  // NOT reset to default local
        #expect(cfg.cloud.llmBaseURL == "https://api.deepseek.com")
        #expect(cfg.cloud.llmModel == "deepseek-v4-flash")
        #expect(cfg.cloud.proxyPort == 0)                    // missing field -> default
    }

    /// Onboarding/mirror fields added in v0.9.0 must default when absent from an older config.json.
    @Test func newFieldsDefaultWhenAbsent() throws {
        let json = """
        {
          "dictationHotkey": {"keyCode": 2, "modifiers": 786432},
          "translationHotkey": {"keyCode": 17, "modifiers": 786432},
          "asr": {"location": "local", "modelID": "x"},
          "llm": {"location": "local", "modelID": "y"}
        }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(!cfg.onboardingCompleted)
        #expect(cfg.huggingFaceEndpoint == "")
    }

    @Test func configStorePersistsCloudKeysOutsideJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let secrets = KeychainSecrets(service: "SaidDoneTests.\(UUID().uuidString)")
        defer {
            try? secrets.delete(account: "cloud-llm:openai")
            try? secrets.delete(account: "asrKey")
        }
        let store = ConfigStore(directory: dir, secrets: secrets)
        var cfg = AppConfig.default
        cfg.cloud.llmProviderID = "openai"
        cfg.cloud.llmAPIKeys = ["openai": "llm-secret"]
        cfg.cloud.asrKey = "asr-secret"

        try store.save(cfg)

        let json = try String(contentsOf: store.url, encoding: .utf8)
        #expect(!(json.contains("llm-secret")))
        #expect(!(json.contains("asr-secret")))
        #expect((store.load().cloud.llmAPIKeys["openai"]) == "llm-secret")
        #expect((store.load().cloud.asrKey) == "asr-secret")
    }

    @Test func loadWithoutSecretsLeavesRuntimeKeysEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(
            directory: dir,
            secrets: KeychainSecrets(service: "SaidDoneTests.\(UUID().uuidString)"))
        var cfg = AppConfig.default
        cfg.cloud.llmProviderID = "openai"
        cfg.cloud.llmAPIKeys = ["openai": "runtime-only"]
        cfg.cloud.asrKey = "runtime-only-asr"

        try store.saveWithoutSecrets(cfg)
        let decoded = store.loadWithoutSecrets()

        #expect(decoded.cloud.llmAPIKeys == ([:]))
        #expect(decoded.cloud.asrKey.isEmpty)
        #expect(decoded.cloud.llmProviderID == "openai")
    }
}
