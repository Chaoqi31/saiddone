import Foundation
import SaidDoneCore

/// Default local ASR per ADR-0003: Qwen3-ASR (1.7B / 0.6B) via MLX.
///
/// SCAFFOLD: conforms to the Provider contract but is not yet wired to an MLX runtime, because
/// on-device Qwen3-ASR inference can't be validated in this environment (Phase-0 spike in
/// ARCHITECTURE). Until a real MLX backend is attached, it reports unavailable and the ASR ladder
/// falls through to WhisperKit. To wire: load the MLX Qwen3-ASR weights (e.g. mlx-audio / qwen3-asr-swift)
/// and implement `transcribe`.
public actor MLXQwenASRProvider: ASRProvider {
    public nonisolated let id: String
    public nonisolated let location: ProviderLocation = .local
    private let modelID: String

    public init(modelID: String = "qwen3-asr-1.7b") {
        self.modelID = modelID
        self.id = "mlx-qwen-asr:\(modelID)"
    }

    public func transcribe(_ audio: AudioSamples, languageHint: String?) async throws -> String {
        throw ProviderError.modelUnavailable("\(id) not wired yet — see Phase-0 spike (ADR-0003)")
    }
}

/// Default local LLM per ADR-0004: Qwen3.5-0.8B via MLX-LM (Polish + Translate).
///
/// SCAFFOLD: same rationale as above. Until wired, Polish falls back to RuleBasedLLM and Translate
/// requires a Cloud Provider. To wire: load Qwen3.5 via MLXLLM (mlx-swift-examples) and prompt it.
public actor MLXQwenLLMProvider: LLMProvider {
    public nonisolated let id: String
    public nonisolated let location: ProviderLocation = .local
    private let modelID: String

    public init(modelID: String = "qwen3.5-0.8b") {
        self.modelID = modelID
        self.id = "mlx-qwen-llm:\(modelID)"
    }

    public func polish(_ text: String, context: PolishContext) async throws -> String {
        throw ProviderError.modelUnavailable("\(id) not wired yet — see Phase-0 spike (ADR-0004)")
    }

    public func translate(_ text: String, to targetLanguage: String, context: PolishContext) async throws -> String {
        throw ProviderError.modelUnavailable("\(id) not wired yet — see Phase-0 spike (ADR-0004)")
    }
}
