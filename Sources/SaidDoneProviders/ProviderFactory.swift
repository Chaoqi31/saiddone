import Foundation
import SaidDoneCore

/// Builds exactly the Provider the user configured — no silent fallback. If the chosen provider
/// fails at runtime, the error surfaces (the caller shows it) rather than quietly switching engines.
public enum ProviderFactory {
    public static func makeASR(_ config: AppConfig) -> ASRProvider {
        switch config.asr.location {
        case .local:
            // Local ASR = WhisperKit (offline). (Qwen3-ASR will slot in here once wired.)
            return WhisperKitASRProvider()
        case .cloud:
            let url = URL(string: config.cloud.asrBaseURL) ?? URL(string: "https://api.openai.com/v1")!
            return CloudASRProvider(apiKey: config.cloud.asrKey, baseURL: url, model: config.cloud.asrModel)
        }
    }

    public static func makeLLM(_ config: AppConfig) -> LLMProvider {
        switch config.llm.location {
        case .local:
            // "mlx-community/..." -> MLX Qwen; otherwise the deterministic rule-based cleaner.
            if config.llm.modelID.hasPrefix("mlx-community/") {
                return MLXQwenLLMProvider(modelID: config.llm.modelID)
            }
            return RuleBasedLLM()
        case .cloud:
            let url = URL(string: config.cloud.llmBaseURL) ?? URL(string: "https://api.openai.com/v1")!
            return CloudLLMProvider(apiKey: config.cloud.llmKey, baseURL: url, model: config.cloud.llmModel)
        }
    }
}
