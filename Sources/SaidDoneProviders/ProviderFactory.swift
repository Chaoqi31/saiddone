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
            return CloudASRProvider(apiKey: config.cloud.asrKey, baseURL: url, model: config.cloud.asrModel,
                                    session: session(config.cloud))
        }
    }

    /// URLSession honoring an optional HTTP(S) proxy from config (helps behind restrictive networks).
    private static func session(_ cloud: CloudConfig) -> URLSession {
        guard !cloud.proxyHost.isEmpty, cloud.proxyPort > 0 else { return .shared }
        let c = URLSessionConfiguration.default
        c.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: cloud.proxyHost,
            kCFNetworkProxiesHTTPPort as String: cloud.proxyPort,
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: cloud.proxyHost,
            kCFNetworkProxiesHTTPSPort as String: cloud.proxyPort,
        ]
        return URLSession(configuration: c)
    }

    public static func makeLLM(_ config: AppConfig) -> LLMProvider {
        switch config.llm.location {
        case .local:
            // Local LLM = MLX Qwen (the provider sanitises any non-mlx id to the default model).
            return MLXQwenLLMProvider(modelID: config.llm.modelID)
        case .cloud:
            let url = URL(string: config.cloud.llmBaseURL) ?? URL(string: "https://api.openai.com/v1")!
            return CloudLLMProvider(apiKey: config.cloud.llmKey, baseURL: url, model: config.cloud.llmModel,
                                    session: session(config.cloud))
        }
    }
}
