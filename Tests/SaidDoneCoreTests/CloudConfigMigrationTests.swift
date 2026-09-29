import Foundation
import Testing
@testable import SaidDoneCore

struct CloudConfigMigrationTests {
    /// Pre-registry config.json with a DeepSeek baseURL -> migrates to llmProviderID="deepseek".
    @Test func migratesKnownBaseURLToBuiltInProvider() throws {
        let json = """
        {"llmBaseURL": "https://api.deepseek.com/v1", "llmModel": "deepseek-chat",
         "asrBaseURL": "https://api.openai.com/v1", "asrModel": "gpt-4o-transcribe",
         "proxyHost": "", "proxyPort": 0}
        """.data(using: .utf8)!
        let cloud = try JSONDecoder().decode(CloudConfig.self, from: json)
        #expect(cloud.llmProviderID == "deepseek")
        #expect(cloud.llmBaseURL == "https://api.deepseek.com/v1")
        #expect(cloud.llmModel == "deepseek-chat")
    }

    @Test func keepsUnknownBaseURLAsEditableEndpoint() throws {
        let json = """
        {"llmBaseURL": "https://my-private.example/v1", "llmModel": "my-model",
         "asrBaseURL": "https://api.openai.com/v1", "asrModel": "gpt-4o-transcribe"}
        """.data(using: .utf8)!
        let cloud = try JSONDecoder().decode(CloudConfig.self, from: json)
        #expect(cloud.llmProviderID == "openai")
        #expect(cloud.llmBaseURL == "https://my-private.example/v1")
        #expect(cloud.llmModel == "my-model")
    }

    /// New-shape config decodes directly without invoking the legacy path.
    @Test func decodesNewShapeDirectly() throws {
        let json = """
        {"llmProviderID": "moonshot", "llmModel": "kimi-k2-0905-preview",
         "asrBaseURL": "https://api.openai.com/v1", "asrModel": "gpt-4o-transcribe",
         "proxyHost": "", "proxyPort": 0}
        """.data(using: .utf8)!
        let cloud = try JSONDecoder().decode(CloudConfig.self, from: json)
        #expect(cloud.llmProviderID == "moonshot")
        #expect(cloud.llmBaseURL == "https://api.moonshot.cn/v1")
        #expect(cloud.llmModel == "kimi-k2-0905-preview")
        #expect(cloud.llmAPIKeys.isEmpty, "keys are hydrated from Keychain, never from JSON")
    }

    /// Empty/missing config → defaults (OpenAI).
    @Test func defaultsOnEmpty() throws {
        let cloud = try JSONDecoder().decode(CloudConfig.self, from: "{}".data(using: .utf8)!)
        #expect(cloud.llmProviderID == "openai")
        #expect(cloud.llmBaseURL == "https://api.openai.com/v1")
        #expect(cloud.llmModel == "gpt-4o-mini")
    }

    /// Encode must never persist API keys (Keychain only).
    @Test func encodeOmitsAPIKeys() throws {
        var cloud = CloudConfig()
        cloud.llmProviderID = "deepseek"
        cloud.llmAPIKeys = ["deepseek": "secret-key"]
        let data = try JSONEncoder().encode(cloud)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!(json.contains("secret-key")))
        #expect(!(json.contains("llmAPIKeys")))
    }

    /// Round-trip preserves provider id + endpoint + model, drops keys.
    @Test func roundTrip() throws {
        var cloud = CloudConfig()
        cloud.llmProviderID = "zhipu"
        cloud.llmBaseURL = "https://open.bigmodel.cn/api/paas/v4"
        cloud.llmModel = "glm-4.5-air"
        cloud.llmAPIKeys = ["zhipu": "k"]
        let data = try JSONEncoder().encode(cloud)
        let decoded = try JSONDecoder().decode(CloudConfig.self, from: data)
        #expect(decoded.llmProviderID == "zhipu")
        #expect(decoded.llmBaseURL == "https://open.bigmodel.cn/api/paas/v4")
        #expect(decoded.llmModel == "glm-4.5-air")
        #expect(decoded.llmAPIKeys.isEmpty, "keys do not round-trip through JSON")
    }
}
