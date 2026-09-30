import Foundation
import SaidDoneCore
@preconcurrency import WhisperKit

/// On-device speech via WhisperKit (Core ML). Loads once, however many callers ask at the same time.
actor WhisperKitTranscriber: Transcriber, LocalEngine {
    private let model: WhisperModel
    private let files: ModelFiles
    private var loading: Task<Loaded, any Error>?

    /// WhisperKit is not Sendable; the instance never leaves this actor.
    private struct Loaded: @unchecked Sendable { let kit: WhisperKit }

    init(model: WhisperModel, files: ModelFiles) {
        self.model = model
        self.files = files
    }

    func load() async throws(EngineError) { _ = try await kit() }

    func transcribe(_ audio: AudioSamples, hints: RecognitionHints) async throws(EngineError) -> String {
        let kit = try await kit()
        var hints = hints
        do {
            // Terms only steer Whisper inside a sentence in the spoken language, so auto-detect with a dictionary
            // detects first. That costs one more encoder pass (about 0.4 s), which plain auto-detect skips.
            if hints.language == nil, !hints.vocabulary.isEmpty {
                hints.language = Language(rawValue: try await kit.detectLangauge(audioArray: audio.samples).language)
            }
            var options = DecodingOptions(language: hints.language?.rawValue, detectLanguage: hints.language == nil,
                                          skipSpecialTokens: true, suppressBlank: true)
            if let tokenizer = kit.tokenizer, let prompt = hints.prompt {
                options.promptTokens = tokenizer.encode(text: prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            }
            let results = try await kit.transcribe(audioArray: audio.samples, decodeOptions: options)
            return results.map(\.text).joined(separator: " ")
        } catch {
            throw Task.isCancelled ? .cancelled : .badResponse
        }
    }

    private func kit() async throws(EngineError) -> WhisperKit {
        guard files.isInstalled(.whisper(model)) else { throw .modelMissing }
        let task = loading ?? Task { [model, files] in
            let config = WhisperKitConfig(modelFolder: files.folder(.whisper(model)).path,
                                          tokenizerFolder: files.root, verbose: false, logLevel: .none,
                                          load: true, download: false)
            return Loaded(kit: try await WhisperKit(config))
        }
        loading = task
        do {
            return try await task.value.kit
        } catch {
            loading = nil
            throw .modelMissing
        }
    }

    /// Downloads the model and the tokenizer every large-v3 variant shares.
    static func download(_ model: WhisperModel, into files: ModelFiles, endpoint: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await WhisperKit.download(variant: model.rawValue, downloadBase: files.root, endpoint: endpoint) {
            progress($0.fractionCompleted * 0.99)
        }
        _ = try await HubApiWrapper(downloadBase: files.root, endpoint: endpoint)
            .snapshot(from: .init(id: ModelFiles.whisperTokenizer),
                      matching: ["config.json", "tokenizer.json", "tokenizer_config.json"])
    }
}
