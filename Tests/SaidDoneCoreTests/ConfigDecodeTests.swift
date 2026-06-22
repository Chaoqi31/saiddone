import XCTest
@testable import SaidDoneCore

final class ConfigDecodeTests: XCTestCase {
    /// A config.json written before `proxyHost`/`proxyPort` existed must still decode (not silently
    /// reset to the local default — that bug once knocked a cloud DeepSeek setup back to local).
    func testDecodesCloudConfigMissingNewerFields() throws {
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
        XCTAssertEqual(cfg.llm.location, .cloud)                  // NOT reset to default local
        XCTAssertEqual(cfg.cloud.llmModel, "deepseek-v4-flash")
        XCTAssertEqual(cfg.cloud.proxyPort, 0)                    // missing field -> default
    }

    /// Onboarding/mirror fields added in v0.9.0 must default when absent from an older config.json.
    func testNewFieldsDefaultWhenAbsent() throws {
        let json = """
        {
          "dictationHotkey": {"keyCode": 2, "modifiers": 786432},
          "translationHotkey": {"keyCode": 17, "modifiers": 786432},
          "asr": {"location": "local", "modelID": "x"},
          "llm": {"location": "local", "modelID": "y"}
        }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertFalse(cfg.onboardingCompleted)
        XCTAssertEqual(cfg.huggingFaceEndpoint, "")
    }

    func testConfigStorePersistsCloudKeysOutsideJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let secrets = KeychainSecrets(service: "SaidDoneTests.\(UUID().uuidString)")
        defer {
            try? secrets.delete(account: "llmKey")
            try? secrets.delete(account: "asrKey")
        }
        let store = ConfigStore(directory: dir, secrets: secrets)
        var cfg = AppConfig.default
        cfg.cloud.llmKey = "llm-secret"
        cfg.cloud.asrKey = "asr-secret"

        try store.save(cfg)

        let json = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(json.contains("llm-secret"))
        XCTAssertFalse(json.contains("asr-secret"))
        XCTAssertEqual(store.load().cloud.llmKey, "llm-secret")
        XCTAssertEqual(store.load().cloud.asrKey, "asr-secret")
    }
}
