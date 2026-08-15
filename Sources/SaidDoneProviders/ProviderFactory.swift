import Foundation
import SaidDoneCore

/// Builds exactly the Provider the user configured — no silent fallback. If the chosen provider
/// fails at runtime, the error surfaces (the caller shows it) rather than quietly switching engines.
public enum ProviderFactory {
    public static func makeASR(_ config: AppConfig) -> ASRProvider {
        switch config.asr.location {
        case .local:
            // Local ASR = WhisperKit (offline). modelID picks turbo vs large-v3 (sanitised in the provider).
            return WhisperKitASRProvider(model: config.asr.modelID)
        case .cloud:
            let url = URL(string: config.cloud.asrBaseURL) ?? URL(string: "https://api.openai.com/v1")!
            // Volcengine uses its own protocol (JSON + base64 WAV), not OpenAI multipart.
            if url.host?.contains("bytedance") == true {
                let resource = config.cloud.asrModel.isEmpty ? "volc.bigasr.auc_turbo" : config.cloud.asrModel
                return VolcengineASRProvider(appID: config.cloud.asrAppID,
                                             accessToken: config.cloud.asrKey,
                                             resourceID: resource,
                                             session: session(config.cloud))
            }
            return CloudASRProvider(apiKey: config.cloud.asrKey, baseURL: url, model: config.cloud.asrModel,
                                    session: session(config.cloud))
        }
    }

    /// URLSession honoring an optional HTTP(S) proxy from config (helps behind restrictive networks).
    private static func session(_ cloud: CloudConfig) -> URLSession {
        CloudSessionPool.shared.session(for: cloud)
    }

    /// Prime TLS + HTTP connections for cloud ASR/LLM so the first dictation isn't a cold start.
    public static func warmCloud(_ config: AppConfig) async {
        await CloudSessionPool.shared.warm(config: config)
    }

    public static func makeLLM(_ config: AppConfig) -> LLMProvider {
        switch config.llm.location {
        case .local:
            // Local LLM = MLX Qwen (the provider sanitises any non-mlx id to the default model).
            return MLXQwenLLMProvider(modelID: config.llm.modelID)
        case .cloud:
            let url = URL(string: config.cloud.llmBaseURL) ?? URL(string: "https://api.openai.com/v1")!
            let key = config.cloud.llmAPIKeys[config.cloud.llmProviderID] ?? ""
            return CloudLLMProvider(apiKey: key, baseURL: url, model: config.cloud.llmModel,
                                    session: session(config.cloud))
        }
    }
}
