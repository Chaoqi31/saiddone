import Foundation

/// A capture intent, bound to its own global hotkey (GOALS v1: Dictation + Translation Modes).
public enum Mode: Sendable, Equatable {
    case dictation
    case translation(target: String)
    case rewrite   // speech is an instruction to rewrite the selected text
}

/// Result of running the pipeline, with timing so callers can check the B1 (≤2s) latency bar.
public struct PipelineResult: Sendable {
    public var text: String
    public var rawTranscript: String
    public var elapsed: TimeInterval
    public init(text: String, rawTranscript: String, elapsed: TimeInterval) {
        self.text = text
        self.rawTranscript = rawTranscript
        self.elapsed = elapsed
    }
}

/// Orchestrates one Mode's pipeline (ARCHITECTURE data flow):
/// Capture(audio) → ASR → Custom Dictionary → Polish [→ Translate] → text for Insert.
public struct PipelineOrchestrator: Sendable {
    public var asr: ASRProvider
    public var llm: LLMProvider
    public var dictionary: CustomDictionary

    public init(asr: ASRProvider, llm: LLMProvider, dictionary: CustomDictionary = .init()) {
        self.asr = asr
        self.llm = llm
        self.dictionary = dictionary
    }

    /// Run audio through the full pipeline for `mode`. `context` is the resolved App Profile tone.
    public func run(_ audio: AudioSamples, mode: Mode, context: PolishContext = .none,
                    languageHint: String? = nil) async throws -> PipelineResult {
        let clock = ContinuousClock()
        let start = clock.now

        let raw = try await asr.transcribe(audio.trimmedSilence(), languageHint: languageHint)
        let cleaned = ASRCleanup.strip(raw)          // drop hallucinations (谢谢大家 …)
        let corrected = dictionary.apply(to: cleaned) // user term corrections

        let final: String
        switch mode {
        case .dictation:
            final = try await llm.polish(corrected, context: context)
        case .translation(let target):
            // Polish first for clean source, then translate (ARCHITECTURE: Polish → Translate).
            let polished = try await llm.polish(corrected, context: context)
            final = try await llm.translate(polished, to: target, context: context)
        case .rewrite:
            // Rewrite Mode is handled by the app (needs the selected text); treat as polish here.
            final = try await llm.polish(corrected, context: context)
        }

        let elapsed = start.duration(to: clock.now).asSeconds
        return PipelineResult(text: final, rawTranscript: raw, elapsed: elapsed)
    }
}

extension Duration {
    var asSeconds: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
