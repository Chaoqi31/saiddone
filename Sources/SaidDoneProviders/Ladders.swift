import Foundation
import SaidDoneCore

/// ASR ladder (ADR-0003): try providers in order, fail over to the next on error.
/// Order for local default: Qwen3-ASR-1.7B → Qwen3-ASR-0.6B → WhisperKit-turbo.
/// (≤2s latency gate / auto-demotion is a Phase-0 spike; today we fail over on error.)
public struct FallbackASRProvider: ASRProvider {
    public let id = "asr-ladder"
    public let location: ProviderLocation
    let rungs: [ASRProvider]

    public init(_ rungs: [ASRProvider], location: ProviderLocation = .local) {
        precondition(!rungs.isEmpty)
        self.rungs = rungs
        self.location = location
    }

    public func transcribe(_ audio: AudioSamples, languageHint: String?) async throws -> String {
        var lastError: Error = ProviderError.modelUnavailable("asr-ladder empty")
        for rung in rungs {
            do { return try await rung.transcribe(audio, languageHint: languageHint) }
            catch { lastError = error }
        }
        throw lastError
    }
}

/// LLM with per-operation fallback: try providers in order for polish/translate independently.
/// e.g. [MLX-Qwen, CloudLLM] — Polish tries each rung in order until one succeeds.
public struct FallbackLLMProvider: LLMProvider {
    public let id = "llm-ladder"
    public let location: ProviderLocation
    let rungs: [LLMProvider]

    public init(_ rungs: [LLMProvider], location: ProviderLocation = .local) {
        precondition(!rungs.isEmpty)
        self.rungs = rungs
        self.location = location
    }

    public func polish(_ text: String, context: PolishContext) async throws -> String {
        var lastError: Error = ProviderError.modelUnavailable("llm-ladder empty")
        for rung in rungs {
            do { return try await rung.polish(text, context: context) }
            catch { lastError = error }
        }
        throw lastError
    }

    public func translate(_ text: String, to targetLanguage: String, context: PolishContext) async throws -> String {
        var lastError: Error = ProviderError.modelUnavailable("llm-ladder empty")
        for rung in rungs {
            do { return try await rung.translate(text, to: targetLanguage, context: context) }
            catch { lastError = error }
        }
        throw lastError
    }
}
