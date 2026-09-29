import Foundation
import Testing
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

struct PipelineTimeoutTests {
    private let audio = AudioSamples(samples: [])

    @Test func polishTimeoutThrowsLatencyBudgetExceeded() async throws {
        let asr = EchoASRProvider(preset: "hello claude")
        let dict = CustomDictionary(entries: [.init(wrong: "claude", right: "Claude")])
        let orch = PipelineOrchestrator(asr: asr, llm: SlowLLMProvider(delay: .seconds(5)),
                                        dictionary: dict, llmTimeout: 0.05)
        do {
            _ = try await orch.run(audio, mode: .dictation)
            Issue.record("expected latencyBudgetExceeded")
        } catch let e as ProviderError {
            guard case .latencyBudgetExceeded = e else { Issue.record("wrong error: \(e)"); return }
        }
    }

    @Test func polishTimeoutDoesNotWaitForNonCooperativeProvider() async throws {
        let asr = EchoASRProvider(preset: "hello")
        let orch = PipelineOrchestrator(asr: asr, llm: BlockingLLMProvider(), llmTimeout: 0.05)

        let started = Date()
        do {
            _ = try await orch.run(audio, mode: .dictation)
            Issue.record("expected latencyBudgetExceeded")
        } catch let e as ProviderError {
            guard case .latencyBudgetExceeded = e else { Issue.record("wrong error: \(e)"); return }
        }
        #expect((Date().timeIntervalSince(started)) < 0.2)
    }

    @Test func fastPolishUnaffectedByBudget() async throws {
        let asr = EchoASRProvider(preset: "hello")
        let orch = PipelineOrchestrator(asr: asr, llm: SlowLLMProvider(delay: .milliseconds(1)),
                                        llmTimeout: 5)
        let result = try await orch.run(audio, mode: .dictation)
        #expect(result.text == "polished")
    }

    @Test func emptyPolishFallsBackForNormalText() async throws {
        let asr = EchoASRProvider(preset: "send the report tomorrow")
        let orch = PipelineOrchestrator(asr: asr,
                                        llm: SlowLLMProvider(delay: .milliseconds(1), polishOutput: ""),
                                        llmTimeout: 5)
        let result = try await orch.run(audio, mode: .dictation)
        #expect(result.text == "send the report tomorrow")
    }

    @Test func explicitCancelCanProduceEmptyPolish() async throws {
        let asr = EchoASRProvider(preset: "send email no wait cancel that")
        let orch = PipelineOrchestrator(asr: asr,
                                        llm: SlowLLMProvider(delay: .milliseconds(1), polishOutput: ""),
                                        llmTimeout: 5)
        let result = try await orch.run(audio, mode: .dictation)
        #expect(result.text == "")
    }

    @Test func pureFillerCanProduceEmptyPolish() async throws {
        let asr = EchoASRProvider(preset: "嗯 那个 就是 呃")
        let orch = PipelineOrchestrator(asr: asr,
                                        llm: SlowLLMProvider(delay: .milliseconds(1), polishOutput: ""),
                                        llmTimeout: 5)
        let result = try await orch.run(audio, mode: .dictation)
        #expect(result.text == "")
    }

    @Test func zeroBudgetDisablesTimeout() async throws {
        let asr = EchoASRProvider(preset: "hello")
        let orch = PipelineOrchestrator(asr: asr, llm: SlowLLMProvider(delay: .milliseconds(100)),
                                        llmTimeout: 0)
        let result = try await orch.run(audio, mode: .dictation)
        #expect(result.text == "polished")
    }

    @Test func translateTimeoutThrowsLatencyBudgetExceeded() async throws {
        let asr = EchoASRProvider(preset: "hello")
        // Same slow provider for polish + translate: polish times out first → latencyBudgetExceeded.
        let orch = PipelineOrchestrator(asr: asr, llm: SlowLLMProvider(delay: .seconds(5)),
                                        llmTimeout: 0.05)
        do {
            _ = try await orch.run(audio, mode: .translation(target: "en"))
            Issue.record("expected latencyBudgetExceeded")
        } catch let e as ProviderError {
            guard case .latencyBudgetExceeded = e else { Issue.record("wrong error: \(e)"); return }
        }
    }

    @Test func polishErrorStillPropagatesUnderBudget() async {
        let asr = EchoASRProvider(preset: "hello")
        let orch = PipelineOrchestrator(asr: asr, llm: FailingLLMProvider(), llmTimeout: 5)
        do {
            _ = try await orch.run(audio, mode: .dictation)
            Issue.record("expected error")
        } catch { /* error path unchanged by the budget */ }
    }
}
