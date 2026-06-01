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
    /// A non-Whisper id (e.g. a stale "qwen3-asr-*" left in config) maps to the turbo default so
    /// local ASR always has a loadable model — this is name sanitising, not an engine fallback.
    public init(model: String = "openai_whisper-large-v3-v20240930_turbo") {
        let m = model.lowercased().contains("whisper") ? model : "openai_whisper-large-v3-v20240930_turbo"
        self.modelName = m
        self.id = "whisperkit:\(m)"
    }

    private func loadIfNeeded() async throws {
        guard pipe == nil else { return }
        // Load from the already-downloaded local folder with download:false so it never touches the
        // network (a VPN/proxy breaking TLS to huggingface.co would otherwise fail the load). Only
        // hit the network on a genuine first run when the model isn't present yet.
        let local = URL.documentsDirectory
            .appending(path: "huggingface/models/argmaxinc/whisperkit-coreml", directoryHint: .isDirectory)
            .appending(path: modelName, directoryHint: .isDirectory)
        let hasModel = FileManager.default.fileExists(atPath: local.appendingPathComponent("AudioEncoder.mlmodelc").path)
        let config = hasModel
            ? WhisperKitConfig(modelFolder: local.path, download: false)
            : WhisperKitConfig(model: modelName)
        pipe = try await WhisperKit(config)
    }

    public func transcribe(_ audio: AudioSamples, languageHint: String?) async throws -> String {
        try await loadIfNeeded()
        guard let pipe else { throw ProviderError.modelUnavailable(id) }
        // Allow an env override to experiment with a forced language (nil = auto-detect).
        let lang = languageHint ?? ProcessInfo.processInfo.environment["SAIDDONE_ASR_LANG"]
        // suppressBlank trims leading/trailing blank tokens; the threshold guards (compressionRatio /
        // logProb / noSpeech) are on by default and drop low-confidence hallucinated segments.
        let options = DecodingOptions(language: lang, suppressBlank: true)
        let results = try await pipe.transcribe(audioArray: audio.samples, decodeOptions: options)
        return results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
