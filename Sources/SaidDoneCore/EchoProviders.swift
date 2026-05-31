import Foundation

/// Deterministic no-model providers for tests and a dev "no engine" mode.
/// EchoASR cannot hear audio; it returns a fixed/preset string. Real ASR lives in SaidDoneApp.

public struct EchoASRProvider: ASRProvider {
    public let id = "echo-asr"
    public let location: ProviderLocation = .local
    public var preset: String
    public init(preset: String = "") { self.preset = preset }
    public func transcribe(_ audio: AudioSamples, languageHint: String?) async throws -> String {
        preset
    }
}

/// Minimal deterministic LLM: trims/collapses whitespace for "polish"; tags target for "translate".
public struct EchoLLMProvider: LLMProvider {
    public let id = "echo-llm"
    public let location: ProviderLocation = .local
    public init() {}

    public func polish(_ text: String, context: PolishContext) async throws -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func translate(_ text: String, to targetLanguage: String, context: PolishContext) async throws -> String {
        "[\(targetLanguage)] \(text)"
    }
}
