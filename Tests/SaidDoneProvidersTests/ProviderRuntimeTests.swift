import Foundation
import Testing
@testable import SaidDoneProviders
import SaidDoneCore

struct ProviderRuntimeTests {
    @Test func unrelatedConfigChangeKeepsAdapters() {
        var runtime = ProviderRuntime(config: .default)
        let asrBefore = runtime.asr as AnyObject
        let llmBefore = runtime.llm as AnyObject
        var changed = AppConfig.default
        changed.soundsEnabled.toggle()

        #expect((runtime.apply(changed)) == .none)
        let asrKept = asrBefore === (runtime.asr as AnyObject)
        let llmKept = llmBefore === (runtime.llm as AnyObject)
        #expect(asrKept)
        #expect(llmKept)
    }

    @Test func changingOnlyLocalASRReplacesOnlyASR() {
        var runtime = ProviderRuntime(config: .default)
        var changed = AppConfig.default
        changed.asr.modelID = "openai_whisper-large-v3"

        #expect((runtime.apply(changed)) == (ProviderReplacements(asr: true, llm: false)))
    }

    @Test func changingOnlyLocalLLMReplacesOnlyLLM() {
        var runtime = ProviderRuntime(config: .default)
        var changed = AppConfig.default
        changed.llm.modelID = "mlx-community/Qwen3-1.7B-4bit"

        #expect((runtime.apply(changed)) == (ProviderReplacements(asr: false, llm: true)))
    }

    @Test func changingProxyReplacesBothCloudAdapters() {
        var initial = AppConfig.default
        initial.asr.location = .cloud
        initial.llm.location = .cloud
        var runtime = ProviderRuntime(config: initial)
        var changed = initial
        changed.cloud.proxyHost = "127.0.0.1"
        changed.cloud.proxyPort = 7890

        #expect((runtime.apply(changed)) == (ProviderReplacements(asr: true, llm: true)))
    }
}
