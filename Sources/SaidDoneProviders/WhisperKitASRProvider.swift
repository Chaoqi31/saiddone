import Foundation
import SaidDoneCore
import WhisperKit

/// Real local ASR via WhisperKit (ADR-0003 fallback engine; also the working baseline today).
/// Downloads the model on first use. languageHint nil = auto-detect (needed for zh-en, GOALS A2).
public actor WhisperKitASRProvider: ASRProvider {
    public nonisolated let id: String
    public nonisolated let location: ProviderLocation = .local

    private let modelName: String
    private var pipe: WhisperKit?

    /// `model`: a WhisperKit model id, e.g. "openai_whisper-large-v3-v20240930_turbo".
    public init(model: String = "openai_whisper-large-v3-v20240930_turbo") {
        self.modelName = model
        self.id = "whisperkit:\(model)"
    }

    private func loadIfNeeded() async throws {
        if pipe == nil {
            pipe = try await WhisperKit(WhisperKitConfig(model: modelName))
        }
    }

    public func transcribe(_ audio: AudioSamples, languageHint: String?) async throws -> String {
        try await loadIfNeeded()
        guard let pipe else { throw ProviderError.modelUnavailable(id) }
        // Allow an env override to experiment with a forced language (nil = auto-detect).
        let lang = languageHint ?? ProcessInfo.processInfo.environment["SAIDDONE_ASR_LANG"]
        let options = DecodingOptions(language: lang)
        let results = try await pipe.transcribe(audioArray: audio.samples, decodeOptions: options)
        return results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
