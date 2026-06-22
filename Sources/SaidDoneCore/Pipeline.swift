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
    /// Per-LLM-stage latency budget in seconds (GOALS B1 runtime gate). 0/nil = no budget.
    /// On timeout, Polish degrades to the dictionary-corrected transcript (never lose the user's
    /// words); Translate throws `latencyBudgetExceeded` (a stale source-language insert is worse).
    public var llmTimeout: TimeInterval?
    /// Optional 0…1 progress + stage label (e.g. for the recording overlay).
    public var onProgress: (@Sendable (Double, String) -> Void)?

    public init(asr: ASRProvider, llm: LLMProvider, dictionary: CustomDictionary = .init(),
                llmTimeout: TimeInterval? = nil,
                onProgress: (@Sendable (Double, String) -> Void)? = nil) {
        self.asr = asr
        self.llm = llm
        self.dictionary = dictionary
        self.llmTimeout = llmTimeout
        self.onProgress = onProgress
    }

    /// Run audio through the full pipeline for `mode`. `context` is the resolved App Profile tone.
    public func run(_ audio: AudioSamples, mode: Mode, context: PolishContext = .none,
                    languageHint: String? = nil) async throws -> PipelineResult {
        let clock = ContinuousClock()
        let start = clock.now
        onProgress?(0.05, "transcribing")

        let raw = try await asr.transcribe(audio.trimmedSilence(), languageHint: languageHint)
        onProgress?(0.45, "polishing")
        let cleaned = ASRCleanup.strip(raw)          // drop hallucinations (谢谢大家 …)
        let corrected = dictionary.apply(to: cleaned) // user term corrections

        // Nothing intelligible captured — skip the LLM (it would hallucinate on empty input) and let
        // the caller show a "no speech" hint rather than insert garbage.
        guard !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PipelineResult(text: "", rawTranscript: raw, elapsed: start.duration(to: clock.now).asSeconds)
        }

        let final: String
        switch mode {
        case .dictation:
            final = try await polishWithBudget(corrected, context: context)
        case .translation(let target):
            // Polish first for clean source, then translate (ARCHITECTURE: Polish → Translate).
            let polished = try await polishWithBudget(corrected, context: context)
            guard let translated = try await withBudget({ try await llm.translate(polished, to: target, context: context) }) else {
                throw ProviderError.latencyBudgetExceeded
            }
            final = translated
        case .rewrite:
            // Rewrite Mode is handled by the app (needs the selected text); treat as polish here.
            final = try await polishWithBudget(corrected, context: context)
        }

        onProgress?(1.0, "done")
        let elapsed = start.duration(to: clock.now).asSeconds
        return PipelineResult(text: final, rawTranscript: raw, elapsed: elapsed)
    }

    /// Polish under the latency budget: timeout → the input text as-is (degrade, don't error).
    private func polishWithBudget(_ text: String, context: PolishContext) async throws -> String {
        let polished = try await withBudget { try await llm.polish(text, context: context) } ?? text
        // Empty cloud response → keep the dictionary-corrected transcript.
        return polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : polished
    }

    /// Run `op` racing the budget. Returns nil on timeout; no budget = just run `op`.
    /// The losing task is cancelled (providers that can't observe cancellation finish in the background).
    private func withBudget(_ op: @escaping @Sendable () async throws -> String) async throws -> String? {
        guard let budget = llmTimeout, budget > 0 else { return try await op() }
        let state = BudgetRaceState()
        return try await withCheckedThrowingContinuation { continuation in
            let work = Task {
                do {
                    let value = try await op()
                    state.finish { continuation.resume(returning: value) }
                } catch {
                    state.finish { continuation.resume(throwing: error) }
                }
            }
            let timer = Task {
                try? await Task.sleep(for: .seconds(budget))
                state.finish { continuation.resume(returning: nil) }
            }
            state.setTasks([work, timer])
        }
    }
}

private final class BudgetRaceState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var tasks: [Task<Void, Never>] = []

    func setTasks(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        if finished {
            lock.unlock()
            tasks.forEach { $0.cancel() }
        } else {
            self.tasks = tasks
            lock.unlock()
        }
    }

    func finish(_ resume: () -> Void) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let tasks = self.tasks
        lock.unlock()
        tasks.forEach { $0.cancel() }
        resume()
    }
}

extension Duration {
    var asSeconds: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
