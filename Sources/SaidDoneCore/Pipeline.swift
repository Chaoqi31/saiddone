import Foundation

/// A capture intent, bound to its own global hotkey (GOALS v1: Dictation + Translation Modes).
public enum Mode: Sendable, Equatable {
    case dictation
    case translation(target: String)
    case ask       // Ask Anything — edit/query selection or answer a spoken question
}

/// Result of running the pipeline, with timing so callers can check the B1 (≤2s) latency bar.
public struct PipelineResult: Sendable {
    public var text: String
    public var rawTranscript: String
    public var elapsed: TimeInterval
    /// Post-ASR, dictionary-corrected text before polish (for fast-insert UX).
    public var draftText: String?
    /// True when Dictation/Translation returned the same text as the corrected draft.
    public var polishSkipped: Bool
    public init(text: String, rawTranscript: String, elapsed: TimeInterval,
                draftText: String? = nil, polishSkipped: Bool = false) {
        self.text = text
        self.rawTranscript = rawTranscript
        self.elapsed = elapsed
        self.draftText = draftText
        self.polishSkipped = polishSkipped
    }
}

/// Per-run policy and context. The Pipeline owns stage ordering; callers supply only user choices.
public struct PipelineOptions: Sendable {
    public var context: PolishContext
    public var languageHint: String?
    public var askSelection: String
    public var fastDraftEnabled: Bool
    public var voiceCommandsEnabled: Bool

    public init(
        context: PolishContext = .none,
        languageHint: String? = nil,
        askSelection: String = "",
        fastDraftEnabled: Bool = false,
        voiceCommandsEnabled: Bool = false
    ) {
        self.context = context
        self.languageHint = languageHint
        self.askSelection = askSelection
        self.fastDraftEnabled = fastDraftEnabled
        self.voiceCommandsEnabled = voiceCommandsEnabled
    }
}

/// Orchestrates one Mode's pipeline (ARCHITECTURE data flow):
/// Capture(audio) → ASR → Custom Dictionary → Polish [→ Translate] → text for Insert.
public struct PipelineOrchestrator: Sendable {
    public var asr: ASRProvider
    public var llm: LLMProvider
    public var dictionary: CustomDictionary
    /// Per-Mode AI-operation latency budget in seconds. ASR is timed independently by its Provider.
    /// 0/nil = no budget; timeout throws `latencyBudgetExceeded`.
    public var llmTimeout: TimeInterval?
    /// Optional 0…1 progress + stage label (e.g. for the recording overlay).
    public var onProgress: (@Sendable (Double, String) -> Void)?
    /// Optional fast-Insert hook. Returns true only when the draft actually reached the target app.
    public var onDraft: (@Sendable (String) async -> Bool)?

    public init(asr: ASRProvider, llm: LLMProvider, dictionary: CustomDictionary = .init(),
                llmTimeout: TimeInterval? = nil,
                onProgress: (@Sendable (Double, String) -> Void)? = nil,
                onDraft: (@Sendable (String) async -> Bool)? = nil) {
        self.asr = asr
        self.llm = llm
        self.dictionary = dictionary
        self.llmTimeout = llmTimeout
        self.onProgress = onProgress
        self.onDraft = onDraft
    }

    /// Run one complete Mode pipeline. Callers do not orchestrate individual ASR/LLM stages.
    public func run(_ audio: AudioSamples, mode: Mode,
                    options: PipelineOptions = .init()) async throws -> PipelineResult {
        let clock = ContinuousClock()
        let start = clock.now
        onProgress?(0.05, "transcribing")
        let raw = try await asr.transcribe(
            audio.trimmedSilence(), languageHint: options.languageHint)
        let corrected = dictionary.apply(to: ASRCleanup.strip(raw))
        guard !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PipelineResult(
                text: "", rawTranscript: raw,
                elapsed: start.duration(to: clock.now).asSeconds)
        }

        var insertedDraft: String?
        if case .dictation = mode,
           options.fastDraftEnabled,
           !PolishOutput.acceptsEmpty(for: corrected),
           let onDraft {
            let draft = options.voiceCommandsEnabled ? VoiceCommands.apply(corrected) : corrected
            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               await onDraft(draft) {
                insertedDraft = draft
            }
        }

        let final: String
        switch mode {
        case .dictation:
            onProgress?(0.45, "polishing")
            final = try await polishWithBudget(corrected, context: options.context)
        case .translation(let target):
            onProgress?(0.45, "translating")
            guard let translated = try await withBudget({
                try await llm.polishAndTranslate(
                    corrected, to: target, context: options.context)
            }) else {
                throw ProviderError.latencyBudgetExceeded
            }
            final = translated
        case .ask:
            onProgress?(0.45, "asking")
            guard let answer = try await withBudget({
                try await llm.ask(
                    corrected, selection: options.askSelection, context: options.context)
            }) else {
                throw ProviderError.latencyBudgetExceeded
            }
            final = answer
        }

        let commandOutput = options.voiceCommandsEnabled ? VoiceCommands.apply(final) : final
        let output = commandOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        onProgress?(1.0, "done")
        let elapsed = start.duration(to: clock.now).asSeconds
        let skipped: Bool
        switch mode {
        case .ask:
            skipped = false
        case .dictation, .translation:
            skipped = output.trimmingCharacters(in: .whitespacesAndNewlines)
                == corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return PipelineResult(
            text: output,
            rawTranscript: raw,
            elapsed: elapsed,
            draftText: insertedDraft,
            polishSkipped: skipped)
    }

    /// Polish under the latency budget: timeout is a hard error, never silently fall back to the
    /// unpolished transcript — the user explicitly wants polished output or a visible failure.
    private func polishWithBudget(_ text: String, context: PolishContext) async throws -> String {
        guard let rawPolished = try await withBudget({ try await llm.polish(text, context: context) }) else {
            throw ProviderError.latencyBudgetExceeded
        }
        let polished = PolishOutput.normalize(rawPolished, source: text)
        if polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PolishOutput.acceptsEmpty(for: text) ? "" : text
        }
        return polished
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
