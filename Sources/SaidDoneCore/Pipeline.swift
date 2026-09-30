import Foundation

// MARK: - Engine surface

public struct RecognitionHints: Equatable, Sendable {
    /// nil = let the engine detect the language.
    public var language: Language?
    /// Dictionary terms the engine should expect.
    public var vocabulary: [String]

    public init(language: Language? = nil, vocabulary: [String] = []) {
        self.language = language
        self.vocabulary = vocabulary
    }

    /// What Whisper-style engines read as the conversation so far. They continue its language, script and spelling,
    /// so a plain sentence in the spoken language that uses the terms steers all three: Simplified rather than
    /// Traditional characters, "bug" rather than "Book". A bare word list or a colon-led glossary leaks its
    /// punctuation into the transcript instead.
    public var prompt: String? {
        let terms = vocabulary.filter { !$0.isEmpty }
        func list(_ separator: String, _ last: String) -> String {
            terms.count < 2 ? terms.joined() : terms.dropLast().joined(separator: separator) + last + terms.last!
        }
        switch language?.rawValue {
        case "zh":
            return terms.isEmpty ? "以下是普通话的句子。" : "我们刚才聊到了 \(list("、", " 和 "))。"
        case "en":
            return terms.isEmpty ? nil : "We just talked about \(list(", ", " and "))."
        default:
            return terms.isEmpty ? nil : terms.joined(separator: ", ") + "."
        }
    }
}

/// Speech to text. Adapters own their wire format and map every failure to `EngineError`.
public protocol Transcriber: Sendable {
    func transcribe(_ audio: AudioSamples, hints: RecognitionHints) async throws(EngineError) -> String
}

/// One chat completion. Prompts and reply parsing live in Core, so every engine behaves the same.
public protocol ChatModel: Sendable {
    func reply(to prompt: Prompt) async throws(EngineError) -> String
}

public enum EngineError: Error, Equatable, Sendable {
    case offline
    case unauthorized
    case rateLimited
    case serverBusy
    case timedOut
    /// The service refused the request (4xx), with its message: "model not found", "invalid parameter".
    case rejected(String)
    case badResponse
    case modelMissing
    case missingCredential
    /// This Mac or this build can't run the engine (on-device AI without its Metal shaders).
    case unsupported
    case cancelled
}

// MARK: - Results

public enum Output: Equatable, Sendable {
    public enum Silence: Equatable, Sendable {
        /// The engine heard no speech.
        case noSpeech
        /// Only filler, or the speaker cancelled the whole utterance.
        case nothingSaid
    }

    case insert(String)
    case replaceSelection(String)
    case answer(String)
    case open(URL)
    case nothing(Silence)
}

public enum Stage: String, Codable, Equatable, Sendable {
    case preparing, transcribing, polishing, translating, answering
}

public struct PipelineResult: Equatable, Sendable {
    /// What the engine heard, after cleanup and dictionary correction. Kept in History.
    public var transcript: String
    public var output: Output
    public var elapsed: Duration
}

public struct PipelineFailure: Error, Equatable, Sendable {
    public var reason: Failure
    public var stage: Stage
    /// Set once transcription succeeded, so a failed entry still shows (and can copy) the words.
    public var transcript: String?

    public init(reason: Failure, stage: Stage, transcript: String?) {
        self.reason = reason
        self.stage = stage
        self.transcript = transcript
    }
}

/// Everything user-specific one job needs, snapshotted when the job starts.
public struct JobContext: Equatable, Sendable {
    public var language: Language?
    public var profile: String
    public var tone: String?
    public var lexicon: Lexicon

    public init(language: Language? = nil, profile: String = "", tone: String? = nil, lexicon: Lexicon = Lexicon()) {
        self.language = language
        self.profile = profile
        self.tone = tone
        self.lexicon = lexicon
    }
}

/// How long the AI step may take before the job fails with a timeout. Not a setting.
public enum Budget {
    public static func ai(local: Bool, audio: Duration) -> Duration {
        if local { return .seconds(30) }
        return max(.seconds(8), .seconds(6) + audio * 0.3)
    }
}

// MARK: - Pipeline

/// The whole AI path for one job: transcribe → clean up → dictionary → the mode's operation → output.
public struct Pipeline: Sendable {
    public let transcriber: any Transcriber
    public let chat: any ChatModel

    public init(transcriber: any Transcriber, chat: any ChatModel) {
        self.transcriber = transcriber
        self.chat = chat
    }

    public func run(_ audio: AudioSamples, _ request: Request, _ context: JobContext, budget: Duration?,
                    stage report: @escaping @Sendable (Stage) -> Void = { _ in })
    async throws(PipelineFailure) -> PipelineResult {
        let clock = ContinuousClock()
        let start = clock.now

        report(.transcribing)
        let raw: String
        do {
            raw = try await transcriber.transcribe(
                audio.trimmedSilence(),
                hints: RecognitionHints(language: context.language,
                                        vocabulary: context.lexicon.recognitionHints()))
        } catch {
            throw PipelineFailure(reason: Failure(error), stage: .transcribing, transcript: nil)
        }
        if Task.isCancelled { throw PipelineFailure(reason: .cancelled, stage: .transcribing, transcript: nil) }

        let transcript = context.lexicon.correct(ASRCleanup.strip(raw))
        func result(_ output: Output) -> PipelineResult {
            PipelineResult(transcript: transcript, output: output, elapsed: start.duration(to: clock.now))
        }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return result(.nothing(.noSpeech)) }
        if Transcript.isFillerOnly(transcript) { return result(.nothing(.nothingSaid)) }

        let prompts = PromptContext(spokenLanguage: context.language, profile: context.profile,
                                    tone: context.tone, terms: context.lexicon.promptTerms())
        let stage: Stage
        let prompt: Prompt
        let parse: @Sendable (String) -> Output?
        switch request {
        case .dictate:
            stage = .polishing
            prompt = Polish.prompt(transcript, prompts)
            parse = { Self.output(Polish.parse($0, source: transcript)) }
        case let .translate(target):
            stage = .translating
            prompt = Translate.prompt(transcript, to: target, prompts)
            parse = { Self.output(Translate.parse($0, source: transcript)) }
        case let .ask(selection):
            if selection.isEmpty, let intent = AskIntent.parse(transcript) { return result(.open(intent.url)) }
            stage = .answering
            prompt = Ask.prompt(request: transcript, selection: selection, prompts)
            parse = { Ask.parse($0, selection: selection) }
        }

        report(stage)
        // One retry on an empty reply: some cloud models occasionally return nothing for real speech.
        for _ in 0..<2 {
            let reply = await self.reply(to: prompt, budget: budget)
            if Task.isCancelled { throw PipelineFailure(reason: .cancelled, stage: stage, transcript: transcript) }
            switch reply {
            case nil:
                throw PipelineFailure(reason: .timeout, stage: stage, transcript: transcript)
            case let .failure(error):
                throw PipelineFailure(reason: Failure(error), stage: stage, transcript: transcript)
            case let .success(text):
                if let output = parse(text) { return result(output) }
            }
        }
        throw PipelineFailure(reason: .emptyReply, stage: stage, transcript: transcript)
    }

    /// nil = empty reply for real speech (retry).
    private static func output(_ parsed: Parsed) -> Output? {
        switch parsed {
        case let .text(text): .insert(text)
        case .nothingSaid: .nothing(.nothingSaid)
        case .empty: nil
        }
    }

    /// nil = the budget ran out first. The losing side is cancelled; engine work that ignores cancellation
    /// (MLX generation) finishes in the background, so the user is never held hostage by it.
    private func reply(to prompt: Prompt, budget: Duration?) async -> Result<String, EngineError>? {
        let chat = self.chat
        let operation: @Sendable () async -> Result<String, EngineError> = {
            do throws(EngineError) { return .success(try await chat.reply(to: prompt)) } catch { return .failure(error) }
        }
        guard let budget else { return await operation() }
        return await Deadline.race(budget, operation)
    }
}

enum Deadline {
    /// Returns `operation`'s value, or nil if `budget` passes (or the calling task is cancelled) first.
    static func race<T: Sendable>(_ budget: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
        let gate = RaceGate<T?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.arm(continuation)
                let work = Task { gate.finish(await operation()) }
                let timer = Task {
                    try? await Task.sleep(for: budget)
                    gate.finish(nil)
                }
                gate.track([work, timer])
            }
        } onCancel: {
            gate.finish(nil)
        }
    }
}

/// Resumes a continuation exactly once, whichever racer finishes first, and cancels the others.
final class RaceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var early: T?
    private var finished = false
    private var tasks: [Task<Void, Never>] = []

    func arm(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        if finished, let early {
            lock.unlock()
            continuation.resume(returning: early)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func track(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        if finished {
            lock.unlock()
            tasks.forEach { $0.cancel() }
        } else {
            self.tasks = tasks
            lock.unlock()
        }
    }

    func finish(_ value: T) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { early = value }
        let tasks = self.tasks
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(returning: value)
    }
}
