import Foundation
import SaidDoneCore
import MLXLLM
import MLXLMCommon
import Hub

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
/// Default here is Qwen3-4B-4bit (best small-model Chinese polish; ~2.3GB). Smaller (0.6B/1.7B) and
/// larger (8B) are selectable in Settings. Swap once a Qwen3.5 MLX build exists.
public actor MLXQwenLLMProvider: LLMProvider {
    public nonisolated let id: String
    public nonisolated let location: ProviderLocation = .local
    private let hubID: String
    private var container: ModelContainer?

    public init(modelID: String = "mlx-community/Qwen3-4B-4bit") {
        // Map our config model ids to a real MLX hub id.
        self.hubID = modelID.hasPrefix("mlx-community/") ? modelID : "mlx-community/Qwen3-4B-4bit"
        self.id = "mlx-qwen-llm:\(hubID)"
    }

    private func loaded() async throws -> ModelContainer {
        if let container { return container }
        // Prefer a local snapshot to bypass the Hub network path (swift-transformers has a
        // CheckedContinuation crash under strict concurrency). Falls back to id-based download.
        let hfBase = URL.documentsDirectory.appending(path: "huggingface", directoryHint: .isDirectory)
        let base = hfBase.appending(path: "models", directoryHint: .isDirectory)
            .appending(path: hubID, directoryHint: .isDirectory)
        let localConfig = base.appending(path: "config.json")
        let hasLocal = FileManager.default.fileExists(atPath: localConfig.path)
        let config: ModelConfiguration = hasLocal
            ? ModelConfiguration(directory: base)
            : ModelConfiguration(id: hubID)
        // When the weights are already on disk, load fully offline so we never round-trip to
        // HuggingFace for tokenizer/config — that network check is slow (or blocked) on some networks
        // and needlessly inflates cold-load time. Only allow the network when we still need to fetch.
        let hub = HubApi(downloadBase: hfBase, useOfflineMode: hasLocal ? true : nil)
        let c = try await loadModelContainer(hub: hub, configuration: config)
        container = c
        return c
    }

    private func run(instructions: String, prompt: String) async throws -> String {
        let container = try await loaded()
        // Scale output headroom with input length so long dictation isn't truncated (Chinese ≈ 1 token
        // per character); keep a floor for short clips and a ceiling to bound worst-case latency.
        let maxTokens = min(2048, max(512, prompt.count * 2))
        let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.0)
        // Build a real system + user chat. ChatSession.respond() resets the message list to JUST the
        // user turn (dropping any `instructions:` system prompt), which made a small model echo the
        // rules back as output. Preparing the chat one level down keeps the system role intact, so the
        // model TRANSFORMS the user text instead of continuing the instructions. "/no_think" turns off
        // Qwen3 reasoning so we don't generate (and then strip) a <think> block.
        let sys = instructions + " /no_think"   // Strings are Sendable; build the messages inside perform.
        let out = try await container.perform { (context: ModelContext) -> String in
            let messages: [Chat.Message] = [.system(sys), .user(prompt)]
            let input = try await context.processor.prepare(input: UserInput(chat: messages))
            let result = try MLXLMCommon.generate(input: input, parameters: params, context: context) { (_: [Int]) in .more }
            return result.output
        }
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
        let out = try await run(instructions: polishSystemPrompt(context: context), prompt: text)
        // Guard: a small LLM sometimes collapses the whole utterance to a fragment. Rather than emit
        // garbage, fall back to the (dictionary-corrected) raw transcript — never lose the user's words.
        if !text.isEmpty, out.count < max(4, text.count / 3) { return text }
        return out
    }

    public func translate(_ text: String, to targetLanguage: String, context: PolishContext) async throws -> String {
        let sys = "You are a translator. Translate the user's text into \(targetLanguage). "
            + "Reply with ONLY the translation — no preamble, no explanation, no quotes, no original text."
        return try await run(instructions: sys, prompt: text)
    }

    public func rewrite(_ instruction: String, selection: String, context: PolishContext) async throws -> String {
        let sys = "你是文本改写助手。根据指令改写【原文】，若原文为空则按指令生成。中文用简体。只输出结果，不要解释、不要引号。"
        let prompt = selection.isEmpty ? "指令：\(instruction)" : "指令：\(instruction)\n\n【原文】：\(selection)"
        return try await run(instructions: sys, prompt: prompt)
    }
}
