import XCTest
@testable import SaidDoneCore

final class CustomDictionaryTests: XCTestCase {
    func testWholeWordASCIICaseInsensitive() {
        let dict = CustomDictionary(entries: [.init(wrong: "claude", right: "Claude")])
        XCTAssertEqual(dict.apply(to: "i love claude and Claude"), "i love Claude and Claude")
        // Whole-word: should not touch substring inside another word.
        XCTAssertEqual(dict.apply(to: "claudette"), "claudette")
    }

    func testCJKSubstring() {
        let dict = CustomDictionary(entries: [.init(wrong: "塞门", right: "Simon")])
        XCTAssertEqual(dict.apply(to: "我叫塞门"), "我叫Simon")
    }

    func testLongerEntryWinsFirst() {
        let dict = CustomDictionary(entries: [
            .init(wrong: "vs code", right: "VS Code"),
            .init(wrong: "code", right: "Code"),
        ])
        XCTAssertEqual(dict.apply(to: "open vs code now"), "open VS Code now")
    }

    func testRegexSpecialCharsAreLiteral() {
        let dict = CustomDictionary(entries: [.init(wrong: "c++", right: "C++")])
        XCTAssertEqual(dict.apply(to: "i code in c++"), "i code in C++")
    }
}

final class AppProfileTests: XCTestCase {
    func testMostSpecificWins() {
        let store = AppProfileStore(profiles: [
            .init(bundleID: nil, tonePrompt: "neutral"),
            .init(bundleID: "com.tinyspeck.slackmacgap", tonePrompt: "casual"),
            .init(bundleID: "com.tinyspeck.slackmacgap", urlContains: "x", tonePrompt: "specific"),
        ])
        XCTAssertEqual(store.context(bundleID: "com.tinyspeck.slackmacgap", url: nil).tonePrompt, "casual")
        XCTAssertEqual(store.context(bundleID: "com.apple.mail", url: nil).tonePrompt, "neutral")
    }

    func testURLMatch() {
        let store = AppProfileStore(profiles: [
            .init(bundleID: "com.google.Chrome", urlContains: "github.com", tonePrompt: "technical"),
        ])
        XCTAssertEqual(store.context(bundleID: "com.google.Chrome", url: "https://github.com/x").tonePrompt, "technical")
        XCTAssertNil(store.context(bundleID: "com.google.Chrome", url: "https://news.com").tonePrompt)
    }
}

final class PipelineTests: XCTestCase {
    func testDictationAppliesDictionaryThenPolish() async throws {
        let asr = EchoASRProvider(preset: "  i  use   claude  ")
        let dict = CustomDictionary(entries: [.init(wrong: "claude", right: "Claude")])
        let orch = PipelineOrchestrator(asr: asr, llm: EchoLLMProvider(), dictionary: dict)
        let result = try await orch.run(.init(samples: []), mode: .dictation)
        XCTAssertEqual(result.text, "i use Claude")
        XCTAssertEqual(result.rawTranscript, "  i  use   claude  ")
    }

    func testTranslationMode() async throws {
        let asr = EchoASRProvider(preset: "你好")
        let orch = PipelineOrchestrator(asr: asr, llm: EchoLLMProvider())
        let result = try await orch.run(.init(samples: []), mode: .translation(target: "en"))
        XCTAssertEqual(result.text, "[en] 你好")
    }
}

final class ConfigTests: XCTestCase {
    func testRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(directory: dir, secrets: KeychainSecrets(service: "SaidDoneTests.\(UUID().uuidString)"))
        var cfg = AppConfig.default
        cfg.targetLanguage = "zh"
        cfg.dictionary.entries.append(.init(wrong: "a", right: "b"))
        try store.save(cfg)

        let loaded = store.load()
        XCTAssertEqual(loaded.targetLanguage, "zh")
        XCTAssertEqual(loaded.dictionary.entries.last, .init(wrong: "a", right: "b"))
    }

    func testDefaultIsZeroKeyLocal() {
        XCTAssertEqual(AppConfig.default.asr.location, .local)
        XCTAssertEqual(AppConfig.default.llm.location, .local)
    }
}
