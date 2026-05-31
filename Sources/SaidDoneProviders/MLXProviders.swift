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
        let params = GenerateParameters(maxTokens: 256, temperature: 0.0)
        // NOTE: ChatSession.respond() overwrites messages, dropping the `instructions:` system prompt,
        // so embed the instruction directly in the user turn. "/no_think" disables Qwen3 reasoning.
        let session = ChatSession(container, generateParameters: params)
        let full = "\(instructions) /no_think\n\nText:\n\(prompt)"
        let out = try await session.respond(to: full)
        return Self.sanitize(out)
    }

    /// Strip Qwen3 <think> blocks and surrounding markdown, leaving only the answer.
    static func sanitize(_ raw: String) -> String {
        var s = raw
        if let r = s.range(of: "</think>", options: .backwards) {
            s = String(s[r.upperBound...])
        }
        s = s.replacingOccurrences(of: "<think>", with: "")
            .replacingOccurrences(of: "</think>", with: "")
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\"*"))
    }

    public func polish(_ text: String, context: PolishContext) async throws -> String {
        let tone = context.tonePrompt.map { "\($0) " } ?? ""
        let sys = tone + "你是听写文本整理助手。务必做到："
            + "⓪ 中文一律用**简体中文**输出（不要繁体）；"
            + "① 加上正确标点并合理断句——中文用，。？！，英文用 , . ? !，保证读起来有停顿、每句都收尾；"
            + "② 去掉口头禅（嗯/呃/啊/那个/就是说/um/uh/like/you know）和重复的词；"
            + "③ 若说话者中途改口（先说错再重说），只保留最终版本；"
            + "④ 保留原文的语言、原意和专业术语（如 React、bug、run、MVP）。"
            + "只输出整理后的文本，不要解释、不要加引号、不要任何前后缀。"
        let out = try await run(instructions: sys, prompt: text)
        // Guard: a small LLM sometimes collapses the whole utterance to a fragment. If the output
        // is implausibly short vs input, treat as failure so the ladder falls back to RuleBasedLLM.
        if !text.isEmpty, out.count < max(4, text.count / 3) {
            throw ProviderError.modelUnavailable("\(id) polish output implausibly short — falling back")
        }
        return out
    }

    public func translate(_ text: String, to targetLanguage: String, context: PolishContext) async throws -> String {
        let sys = "You are a translator. Translate the user's text into \(targetLanguage). "
            + "Reply with ONLY the translation — no preamble, no explanation, no quotes, no original text."
        return try await run(instructions: sys, prompt: text)
    }
}
