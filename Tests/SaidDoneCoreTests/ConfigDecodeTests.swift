import XCTest
@testable import SaidDoneCore

final class ConfigDecodeTests: XCTestCase {
    /// A config.json written before `proxyHost`/`proxyPort` existed must still decode (not silently
    /// reset to the local default — that bug made cloud DeepSeek fall back to rule-based).
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
}
