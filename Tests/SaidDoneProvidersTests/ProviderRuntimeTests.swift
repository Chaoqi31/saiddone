import XCTest
@testable import SaidDoneProviders
import SaidDoneCore

final class ProviderRuntimeTests: XCTestCase {
    func testUnrelatedConfigChangeKeepsAdapters() {
        var runtime = ProviderRuntime(config: .default)
        let asrBefore = runtime.asr as AnyObject
        let llmBefore = runtime.llm as AnyObject
        var changed = AppConfig.default
        changed.soundsEnabled.toggle()

        XCTAssertEqual(runtime.apply(changed), .none)
        XCTAssertTrue(asrBefore === (runtime.asr as AnyObject))
        XCTAssertTrue(llmBefore === (runtime.llm as AnyObject))
    }

    func testChangingOnlyLocalASRReplacesOnlyASR() {
        var runtime = ProviderRuntime(config: .default)
        var changed = AppConfig.default
        changed.asr.modelID = "openai_whisper-large-v3"

        XCTAssertEqual(
            runtime.apply(changed),
            ProviderReplacements(asr: true, llm: false))
    }

    func testChangingOnlyLocalLLMReplacesOnlyLLM() {
        var runtime = ProviderRuntime(config: .default)
        var changed = AppConfig.default
        changed.llm.modelID = "mlx-community/Qwen3-1.7B-4bit"

        XCTAssertEqual(
            runtime.apply(changed),
            ProviderReplacements(asr: false, llm: true))
    }

    func testChangingProxyReplacesBothCloudAdapters() {
        var initial = AppConfig.default
        initial.asr.location = .cloud
        initial.llm.location = .cloud
        var runtime = ProviderRuntime(config: initial)
        var changed = initial
        changed.cloud.proxyHost = "127.0.0.1"
        changed.cloud.proxyPort = 7890

        XCTAssertEqual(
            runtime.apply(changed),
            ProviderReplacements(asr: true, llm: true))
    }
}
