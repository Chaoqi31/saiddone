import XCTest
@testable import SaidDoneCore

private actor RecordingLLMProvider: LLMProvider {
    nonisolated let id = "recording-llm"
    nonisolated let location: ProviderLocation = .local

    private var polishCalls = 0
    private var translateCalls = 0
    private var combinedCalls = 0
    private var askCalls = 0
    private var lastAskQuestion = ""
    private var lastAskSelection = ""
    private let askResponse: String
    private let combinedResponse: String?

    init(askResponse: String = "answer", combinedResponse: String? = nil) {
        self.askResponse = askResponse
        self.combinedResponse = combinedResponse
    }

    func polish(_ text: String, context: PolishContext) async throws -> String {
        polishCalls += 1
        return "polished:\(text)"
    }

    func translate(_ text: String, to targetLanguage: String,
                   context: PolishContext) async throws -> String {
        translateCalls += 1
        return "[\(targetLanguage)] translated:\(text)"
    }

    func polishAndTranslate(_ text: String, to targetLanguage: String,
                            context: PolishContext) async throws -> String {
        combinedCalls += 1
        return combinedResponse ?? "[\(targetLanguage)] combined:\(text)"
    }

    func ask(_ question: String, selection: String,
             context: PolishContext) async throws -> String {
        askCalls += 1
        lastAskQuestion = question
        lastAskSelection = selection
        return askResponse
    }

    func snapshot() -> (polish: Int, translate: Int, combined: Int, ask: Int,
                        question: String, selection: String) {
        (polishCalls, translateCalls, combinedCalls, askCalls, lastAskQuestion, lastAskSelection)
    }
}

private struct DelayedASRProvider: ASRProvider {
    let id = "delayed-asr"
    let location: ProviderLocation = .local
    var delay: Duration
    var text: String

    func transcribe(_ audio: AudioSamples, languageHint: String?) async throws -> String {
        try await Task.sleep(for: delay)
        return text
    }
}

private actor DraftRecorder {
    private var drafts: [String] = []
    var accepts: Bool

    init(accepts: Bool) { self.accepts = accepts }

    func insert(_ draft: String) -> Bool {
        drafts.append(draft)
        return accepts
    }

    func snapshot() -> [String] { drafts }
}

final class PipelineFlowTests: XCTestCase {
    func testTranslationUsesOneCombinedLLMOperation() async throws {
        let llm = RecordingLLMProvider()
        let orchestrator = PipelineOrchestrator(
            asr: EchoASRProvider(preset: "你好"),
            llm: llm)

        let result = try await orchestrator.run(
            AudioSamples(samples: []),
            mode: .translation(target: "en"))
        let calls = await llm.snapshot()

        XCTAssertEqual(result.text, "[en] combined:你好")
        XCTAssertEqual(calls.polish, 0)
        XCTAssertEqual(calls.translate, 0)
        XCTAssertEqual(calls.combined, 1)
    }

    func testTranslationLetsCombinedOperationClassifyPureFiller() async throws {
        let llm = RecordingLLMProvider(combinedResponse: "")
        let orchestrator = PipelineOrchestrator(
            asr: EchoASRProvider(preset: "嗯 那个 就是 呃"),
            llm: llm)

        let result = try await orchestrator.run(
            AudioSamples(samples: []),
            mode: .translation(target: "en"))
        let calls = await llm.snapshot()

        XCTAssertEqual(result.text, "")
        XCTAssertEqual(calls.combined, 1)
    }

    func testTranslationDoesNotTreatCancellationPhraseAsCommand() async throws {
        let llm = RecordingLLMProvider()
        let orchestrator = PipelineOrchestrator(
            asr: EchoASRProvider(preset: "Translate cancel that"),
            llm: llm)

        let result = try await orchestrator.run(
            AudioSamples(samples: []),
            mode: .translation(target: "zh"))
        let calls = await llm.snapshot()

        XCTAssertEqual(result.text, "[zh] combined:Translate cancel that")
        XCTAssertEqual(calls.combined, 1)
    }

    func testElapsedIncludesASR() async throws {
        let orchestrator = PipelineOrchestrator(
            asr: DelayedASRProvider(delay: .milliseconds(60), text: "hello"),
            llm: EchoLLMProvider())

        let result = try await orchestrator.run(
            AudioSamples(samples: []), mode: .dictation)

        XCTAssertGreaterThanOrEqual(result.elapsed, 0.05)
    }

    func testAskUsesCommonCleanupDictionarySelectionAndLLM() async throws {
        let llm = RecordingLLMProvider()
        let orchestrator = PipelineOrchestrator(
            asr: EchoASRProvider(preset: "  ask   clod  "),
            llm: llm,
            dictionary: CustomDictionary(entries: [.init(wrong: "clod", right: "Claude")]))

        let result = try await orchestrator.run(
            AudioSamples(samples: []),
            mode: .ask,
            options: PipelineOptions(askSelection: "selected text"))
        let calls = await llm.snapshot()

        XCTAssertEqual(result.text, "answer")
        XCTAssertEqual(calls.ask, 1)
        XCTAssertEqual(calls.question, "ask Claude")
        XCTAssertEqual(calls.selection, "selected text")
    }

    func testAllModesTrimModelOutputBoundaries() async throws {
        let orchestrator = PipelineOrchestrator(
            asr: EchoASRProvider(preset: "question"),
            llm: RecordingLLMProvider(askResponse: "  answer \n"))

        let result = try await orchestrator.run(
            AudioSamples(samples: []), mode: .ask)

        XCTAssertEqual(result.text, "answer")
    }

    func testFastDraftWaitsForSuccessfulInsertAndRecordsActualDraft() async throws {
        let recorder = DraftRecorder(accepts: true)
        let orchestrator = PipelineOrchestrator(
            asr: EchoASRProvider(preset: "hello"),
            llm: RecordingLLMProvider(),
            onDraft: { draft in await recorder.insert(draft) })

        let result = try await orchestrator.run(
            AudioSamples(samples: []),
            mode: .dictation,
            options: PipelineOptions(fastDraftEnabled: true))
        let drafts = await recorder.snapshot()

        XCTAssertEqual(drafts, ["hello"])
        XCTAssertEqual(result.draftText, "hello")
        XCTAssertEqual(result.text, "polished:hello")
    }

    func testRejectedFastDraftIsNotReportedAsInserted() async throws {
        let recorder = DraftRecorder(accepts: false)
        let orchestrator = PipelineOrchestrator(
            asr: EchoASRProvider(preset: "hello"),
            llm: RecordingLLMProvider(),
            onDraft: { draft in await recorder.insert(draft) })

        let result = try await orchestrator.run(
            AudioSamples(samples: []),
            mode: .dictation,
            options: PipelineOptions(fastDraftEnabled: true))

        XCTAssertNil(result.draftText)
    }
}
