import Foundation
import SaidDoneCore

/// Builds the concrete ASR/LLM Providers for a config, wiring the ladders (ADR-0001/0003/0004).
public enum ProviderFactory {
    /// Local ASR ladder: Qwen3-ASR-1.7B → 0.6B → WhisperKit-turbo. Cloud ASR (opt-in) when selected
    /// and a key is set, with the local ladder as a safety net.
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
            guard !config.cloud.asrKey.isEmpty, let url = URL(string: config.cloud.asrBaseURL) else { return local }
            let cloud = CloudASRProvider(apiKey: config.cloud.asrKey, baseURL: url, model: config.cloud.asrModel)
            return FallbackASRProvider([cloud, local], location: .cloud)
        }
    }

    /// Local LLM ladder: MLX-Qwen3.5 (only if an `mlx-community/...` id is set) → RuleBasedLLM floor.
    /// Cloud LLM (opt-in) when selected and a key is set.
    public static func makeLLM(_ config: AppConfig) -> LLMProvider {
        var localRungs: [LLMProvider] = []
        if config.llm.modelID.hasPrefix("mlx-community/") {
            localRungs.append(MLXQwenLLMProvider(modelID: config.llm.modelID))
        }
        localRungs.append(RuleBasedLLM())
        let local = FallbackLLMProvider(localRungs)

        switch config.llm.location {
        case .local:
            return local
        case .cloud:
            guard !config.cloud.llmKey.isEmpty, let url = URL(string: config.cloud.llmBaseURL) else { return local }
            let cloud = CloudLLMProvider(apiKey: config.cloud.llmKey, baseURL: url, model: config.cloud.llmModel)
            return FallbackLLMProvider([cloud, local], location: .cloud)
        }
    }
}
