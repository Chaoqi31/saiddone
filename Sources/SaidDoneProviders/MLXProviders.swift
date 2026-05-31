import Foundation
import SaidDoneCore
import MLXLLM
import MLXLMCommon

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

/// Default local LLM (ADR-0004) via MLX-LM (mlx-swift-examples), doing Polish + Translate on-device.
///
/// Note: ADR-0004 specified Qwen3.5-0.8B, but Qwen3.5 is not yet published in mlx-community format.
/// Default here is the newest available small Qwen in MLX: Qwen3-1.7B-4bit (strong Chinese, ~1GB).
/// Swap `hubID` once a Qwen3.5 MLX build exists.
public actor MLXQwenLLMProvider: LLMProvider {
    public nonisolated let id: String
    public nonisolated let location: ProviderLocation = .local
    private let hubID: String
    private var container: ModelContainer?

    public init(modelID: String = "mlx-community/Qwen3-1.7B-4bit") {
        // Map our config model ids to a real MLX hub id.
        self.hubID = modelID.hasPrefix("mlx-community/") ? modelID : "mlx-community/Qwen3-1.7B-4bit"
        self.id = "mlx-qwen-llm:\(hubID)"
    }

    private func loaded() async throws -> ModelContainer {
        if let container { return container }
        // Prefer a local snapshot to bypass the Hub network path (swift-transformers has a
        // CheckedContinuation crash under strict concurrency). Falls back to id-based download.
        let base = URL.documentsDirectory
            .appending(path: "huggingface/models", directoryHint: .isDirectory)
            .appending(path: hubID, directoryHint: .isDirectory)
        let localConfig = base.appending(path: "config.json")
        let config: ModelConfiguration = FileManager.default.fileExists(atPath: localConfig.path)
            ? ModelConfiguration(directory: base)
            : ModelConfiguration(id: hubID)
        let c = try await loadModelContainer(configuration: config)
        container = c
        return c
    }

    private func run(instructions: String, prompt: String) async throws -> String {
        let container = try await loaded()
        // Greedy-ish, bounded output for a dictation-sized utterance.
        let params = GenerateParameters(maxTokens: 512, temperature: 0.2)
        let session = ChatSession(container, instructions: instructions, generateParameters: params)
        let out = try await session.respond(to: prompt)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func polish(_ text: String, context: PolishContext) async throws -> String {
        let tone = context.tonePrompt.map { "\($0) " } ?? ""
        let sys = tone + "Clean up the user's dictated text: fix punctuation, remove filler words and "
            + "repeats, keep the original language and meaning and technical terms. Output ONLY the cleaned text, nothing else."
        return try await run(instructions: sys, prompt: text)
    }

    public func translate(_ text: String, to targetLanguage: String, context: PolishContext) async throws -> String {
        let sys = "Translate the user's text into \(targetLanguage). Output ONLY the translation, no notes or quotes."
        return try await run(instructions: sys, prompt: text)
    }
}
