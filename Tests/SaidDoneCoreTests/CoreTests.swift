import Foundation
import Testing
@testable import SaidDoneCore

struct CustomDictionaryTests {
    @Test func wholeWordASCIICaseInsensitive() {
        let dict = CustomDictionary(entries: [.init(wrong: "claude", right: "Claude")])
        #expect((dict.apply(to: "i love claude and Claude")) == "i love Claude and Claude")
        // Whole-word: should not touch substring inside another word.
        #expect((dict.apply(to: "claudette")) == "claudette")
    }

    @Test func cJKSubstring() {
        let dict = CustomDictionary(entries: [.init(wrong: "塞门", right: "Simon")])
        #expect((dict.apply(to: "我叫塞门")) == "我叫Simon")
    }

    @Test func longerEntryWinsFirst() {
        let dict = CustomDictionary(entries: [
            .init(wrong: "vs code", right: "VS Code"),
            .init(wrong: "code", right: "Code"),
        ])
        #expect((dict.apply(to: "open vs code now")) == "open VS Code now")
    }

    @Test func regexSpecialCharsAreLiteral() {
        let dict = CustomDictionary(entries: [.init(wrong: "c++", right: "C++")])
        #expect((dict.apply(to: "i code in c++")) == "i code in C++")
    }
}

struct AppProfileTests {
    @Test func mostSpecificWins() {
        let store = AppProfileStore(profiles: [
            .init(bundleID: nil, tonePrompt: "neutral"),
            .init(bundleID: "com.tinyspeck.slackmacgap", tonePrompt: "casual"),
        ])
        #expect((store.context(bundleID: "com.tinyspeck.slackmacgap").tonePrompt) == "casual")
        #expect((store.context(bundleID: "com.apple.mail").tonePrompt) == "neutral")
    }
}

struct PipelineTests {
    @Test func dictationAppliesDictionaryThenPolish() async throws {
        let asr = EchoASRProvider(preset: "  i  use   claude  ")
        let dict = CustomDictionary(entries: [.init(wrong: "claude", right: "Claude")])
        let orch = PipelineOrchestrator(asr: asr, llm: EchoLLMProvider(), dictionary: dict)
        let result = try await orch.run(.init(samples: []), mode: .dictation)
        #expect(result.text == "i use Claude")
        #expect(result.rawTranscript == "  i  use   claude  ")
    }

    @Test func translationMode() async throws {
        let asr = EchoASRProvider(preset: "你好")
        let orch = PipelineOrchestrator(asr: asr, llm: EchoLLMProvider())
        let result = try await orch.run(.init(samples: []), mode: .translation(target: "en"))
        #expect(result.text == "[en] 你好")
    }
}

struct ConfigTests {
    @Test func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(directory: dir, secrets: KeychainSecrets(service: "SaidDoneTests.\(UUID().uuidString)"))
        var cfg = AppConfig.default
        cfg.targetLanguage = "zh"
        cfg.dictionary.entries.append(.init(wrong: "a", right: "b"))
        try store.save(cfg)

        let loaded = store.load()
        #expect(loaded.targetLanguage == "zh")
        #expect(loaded.dictionary.entries.last == (.init(wrong: "a", right: "b")))
    }

    @Test func defaultIsZeroKeyLocal() {
        #expect(AppConfig.default.asr.location == .local)
        #expect(AppConfig.default.llm.location == .local)
    }
}
