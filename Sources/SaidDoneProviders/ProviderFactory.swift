import Foundation
import SaidDoneCore

/// Opt-in cloud credentials (kept out of AppConfig JSON; load from Keychain at call sites).
public struct CloudCredentials: Sendable {
    public var llmKey: String
    public var llmBaseURL: URL
    public var llmModel: String
    public init(llmKey: String, llmBaseURL: URL, llmModel: String) {
        self.llmKey = llmKey
        self.llmBaseURL = llmBaseURL
        self.llmModel = llmModel
    }
}

/// Builds the concrete ASR/LLM Providers for a config, wiring the ladders (ADR-0001/0003/0004).
public enum ProviderFactory {
    /// Local ASR ladder: Qwen3-ASR-1.7B → 0.6B → WhisperKit-turbo. Cloud ASR if explicitly selected
    /// (falls back to the local ladder when not yet wired).
    public static func makeASR(_ config: AppConfig) -> ASRProvider {
        let local = FallbackASRProvider([
            MLXQwenASRProvider(modelID: config.asr.modelID),
            MLXQwenASRProvider(modelID: "qwen3-asr-0.6b"),
            WhisperKitASRProvider(),
        ])
        switch config.asr.location {
        case .local:
            return local
        case .cloud:
            // Cloud ASR scaffold not wired -> ladder ends in the working local engine.
            return FallbackASRProvider([CloudASRProvider(apiKey: ""), local], location: .cloud)
        }
    }

    /// Local LLM ladder: MLX-Qwen3.5 → RuleBasedLLM (Polish always has a deterministic floor).
    /// Cloud LLM (opt-in) when selected and credentials are present.
    public static func makeLLM(_ config: AppConfig, cloud: CloudCredentials? = nil) -> LLMProvider {
        let local = FallbackLLMProvider([
            MLXQwenLLMProvider(modelID: config.llm.modelID),
            RuleBasedLLM(),
        ])
        switch config.llm.location {
        case .local:
            return local
        case .cloud:
            if let cloud {
                let cloudLLM = CloudLLMProvider(apiKey: cloud.llmKey, baseURL: cloud.llmBaseURL, model: cloud.llmModel)
                // Cloud first, local floor as safety net.
                return FallbackLLMProvider([cloudLLM, local], location: .cloud)
            }
            return local
        }
    }
}
