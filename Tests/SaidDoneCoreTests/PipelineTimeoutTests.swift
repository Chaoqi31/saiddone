import XCTest
@testable import SaidDoneCore

/// LLM that sleeps before answering — drives the latency-budget (GOALS B1 runtime gate) paths.
private struct SlowLLMProvider: LLMProvider {
    let id = "slow-llm"
    let location: ProviderLocation = .local
    var delay: Duration
    var polishOutput: String = "polished"

    func polish(_ text: String, context: PolishContext) async throws -> String {
        try await Task.sleep(for: delay)
        return polishOutput
    }
    func translate(_ text: String, to targetLanguage: String, context: PolishContext) async throws -> String {
        try await Task.sleep(for: delay)
        return "[\(targetLanguage)] \(text)"
    }
}

private struct BlockingLLMProvider: LLMProvider {
    let id = "blocking-llm"
    let location: ProviderLocation = .local

    func polish(_ text: String, context: PolishContext) async throws -> String {
        let until = Date().addingTimeInterval(0.35)
        while Date() < until {}
        return "late polish"
    }

    func translate(_ text: String, to targetLanguage: String, context: PolishContext) async throws -> String {
        let until = Date().addingTimeInterval(0.35)
        while Date() < until {}
        return "late translate"
    }
}

private struct FailingLLMProvider: LLMProvider {
    let id = "failing-llm"
    let location: ProviderLocation = .local
    func polish(_ text: String, context: PolishContext) async throws -> String {
        throw ProviderError.modelUnavailable("boom")
    }
    func translate(_ text: String, to targetLanguage: String, context: PolishContext) async throws -> String {
        throw ProviderError.modelUnavailable("boom")
    }
}

final class PipelineTimeoutTests: XCTestCase {
    private let audio = AudioSamples(samples: [])

    func testPolishTimeoutDegradesToCorrectedTranscript() async throws {
        let asr = EchoASRProvider(preset: "hello claude")
        let dict = CustomDictionary(entries: [.init(wrong: "claude", right: "Claude")])
        let orch = PipelineOrchestrator(asr: asr, llm: SlowLLMProvider(delay: .seconds(5)),
                                        dictionary: dict, llmTimeout: 0.05)
        let result = try await orch.run(audio, mode: .dictation)
        // Degraded output = dictionary-corrected transcript, not the (late) polish.
        XCTAssertEqual(result.text, "hello Claude")
        XCTAssertLessThan(result.elapsed, 2.0)
    }

    func testPolishTimeoutDoesNotWaitForNonCooperativeProvider() async throws {
        let asr = EchoASRProvider(preset: "hello")
        let orch = PipelineOrchestrator(asr: asr, llm: BlockingLLMProvider(), llmTimeout: 0.05)

        let started = Date()
        let result = try await orch.run(audio, mode: .dictation)

        XCTAssertEqual(result.text, "hello")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
    }

    func testFastPolishUnaffectedByBudget() async throws {
        let asr = EchoASRProvider(preset: "hello")
        let orch = PipelineOrchestrator(asr: asr, llm: SlowLLMProvider(delay: .milliseconds(1)),
                                        llmTimeout: 5)
        let result = try await orch.run(audio, mode: .dictation)
        XCTAssertEqual(result.text, "polished")
    }

    func testZeroBudgetDisablesTimeout() async throws {
        let asr = EchoASRProvider(preset: "hello")
        let orch = PipelineOrchestrator(asr: asr, llm: SlowLLMProvider(delay: .milliseconds(100)),
                                        llmTimeout: 0)
        let result = try await orch.run(audio, mode: .dictation)
        XCTAssertEqual(result.text, "polished")
    }

    func testTranslateTimeoutThrowsLatencyBudgetExceeded() async throws {
        let asr = EchoASRProvider(preset: "hello")
        // Polish fast enough is impossible here (same slow provider), so polish degrades to raw,
        // then translate times out → latencyBudgetExceeded.
        let orch = PipelineOrchestrator(asr: asr, llm: SlowLLMProvider(delay: .seconds(5)),
                                        llmTimeout: 0.05)
        do {
            _ = try await orch.run(audio, mode: .translation(target: "en"))
            XCTFail("expected latencyBudgetExceeded")
        } catch let e as ProviderError {
            guard case .latencyBudgetExceeded = e else { return XCTFail("wrong error: \(e)") }
        }
    }

    func testPolishErrorStillPropagatesUnderBudget() async {
        let asr = EchoASRProvider(preset: "hello")
        let orch = PipelineOrchestrator(asr: asr, llm: FailingLLMProvider(), llmTimeout: 5)
        do {
            _ = try await orch.run(audio, mode: .dictation)
            XCTFail("expected error")
        } catch { /* error path unchanged by the budget */ }
    }
}
