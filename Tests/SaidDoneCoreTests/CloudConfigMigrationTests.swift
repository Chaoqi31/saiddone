import XCTest
@testable import SaidDoneCore

final class CloudConfigMigrationTests: XCTestCase {
    /// Pre-registry config.json with a DeepSeek baseURL -> migrates to llmProviderID="deepseek".
    func testMigratesKnownBaseURLToBuiltInProvider() throws {
        let json = """
        {"llmBaseURL": "https://api.deepseek.com/v1", "llmModel": "deepseek-chat",
         "asrBaseURL": "https://api.openai.com/v1", "asrModel": "gpt-4o-transcribe",
         "proxyHost": "", "proxyPort": 0}
        """.data(using: .utf8)!
        let cloud = try JSONDecoder().decode(CloudConfig.self, from: json)
        XCTAssertEqual(cloud.llmProviderID, "deepseek")
        XCTAssertEqual(cloud.llmBaseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(cloud.llmModel, "deepseek-chat")
    }

    func testKeepsUnknownBaseURLAsEditableEndpoint() throws {
        let json = """
        {"llmBaseURL": "https://my-private.example/v1", "llmModel": "my-model",
         "asrBaseURL": "https://api.openai.com/v1", "asrModel": "gpt-4o-transcribe"}
        """.data(using: .utf8)!
        let cloud = try JSONDecoder().decode(CloudConfig.self, from: json)
        XCTAssertEqual(cloud.llmProviderID, "openai")
        XCTAssertEqual(cloud.llmBaseURL, "https://my-private.example/v1")
        XCTAssertEqual(cloud.llmModel, "my-model")
    }

    /// New-shape config decodes directly without invoking the legacy path.
    func testDecodesNewShapeDirectly() throws {
        let json = """
        {"llmProviderID": "moonshot", "llmModel": "kimi-k2-0905-preview",
         "asrBaseURL": "https://api.openai.com/v1", "asrModel": "gpt-4o-transcribe",
         "proxyHost": "", "proxyPort": 0}
        """.data(using: .utf8)!
        let cloud = try JSONDecoder().decode(CloudConfig.self, from: json)
        XCTAssertEqual(cloud.llmProviderID, "moonshot")
        XCTAssertEqual(cloud.llmBaseURL, "https://api.moonshot.cn/v1")
        XCTAssertEqual(cloud.llmModel, "kimi-k2-0905-preview")
        XCTAssertTrue(cloud.llmAPIKeys.isEmpty, "keys are hydrated from Keychain, never from JSON")
    }

    /// Empty/missing config → defaults (OpenAI).
    func testDefaultsOnEmpty() throws {
        let cloud = try JSONDecoder().decode(CloudConfig.self, from: "{}".data(using: .utf8)!)
        XCTAssertEqual(cloud.llmProviderID, "openai")
        XCTAssertEqual(cloud.llmBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(cloud.llmModel, "gpt-4o-mini")
    }

    /// Encode must never persist API keys (Keychain only).
    func testEncodeOmitsAPIKeys() throws {
        var cloud = CloudConfig()
        cloud.llmProviderID = "deepseek"
        cloud.llmAPIKeys = ["deepseek": "secret-key"]
        let data = try JSONEncoder().encode(cloud)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("secret-key"))
        XCTAssertFalse(json.contains("llmAPIKeys"))
    }

    /// Round-trip preserves provider id + endpoint + model, drops keys.
    func testRoundTrip() throws {
        var cloud = CloudConfig()
        cloud.llmProviderID = "zhipu"
        cloud.llmBaseURL = "https://open.bigmodel.cn/api/paas/v4"
        cloud.llmModel = "glm-4.5-air"
        cloud.llmAPIKeys = ["zhipu": "k"]
        let data = try JSONEncoder().encode(cloud)
        let decoded = try JSONDecoder().decode(CloudConfig.self, from: data)
        XCTAssertEqual(decoded.llmProviderID, "zhipu")
        XCTAssertEqual(decoded.llmBaseURL, "https://open.bigmodel.cn/api/paas/v4")
        XCTAssertEqual(decoded.llmModel, "glm-4.5-air")
        XCTAssertTrue(decoded.llmAPIKeys.isEmpty, "keys do not round-trip through JSON")
    }
}
