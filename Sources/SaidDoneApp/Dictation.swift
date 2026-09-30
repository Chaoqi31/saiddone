import AppKit
import Observation
import SaidDoneCore
import SaidDoneEngines

/// What the voice bar shows after a job, for a few seconds.
enum Notice: Equatable {
    /// The text is on the clipboard instead: nowhere to paste, the user switched apps, or no Accessibility.
    case copied
    case nothingHeard
    case failed(Failure, entry: JobID, transcript: String?)
    case retryUnavailable
    case setupNeeded(Issue)
    case microphoneFailed(CaptureError)
    /// The chosen microphone isn't connected; the default one was used.
    case microphoneMissing(String)
    case learned([String])

    var lasts: Duration {
        switch self {
        case .failed, .setupNeeded: .seconds(10)
        default: .seconds(3)
        }
    }
}

/// Carries out the session machine's effects: records, runs jobs in order, and delivers each result. Decisions live
/// in Core (`SessionMachine`, `Pipeline`, `Prompts`); this type only does what they say.
@MainActor @Observable
final class Dictation {
    enum Phase: Equatable {
        case idle
        case recording(Mode, RecordingStyle, since: Date)
        case processing(Stage)
    }

    private(set) var phase: Phase = .idle
    /// Recordings waiting behind the job being processed.
    private(set) var waiting = 0
    private(set) var notice: Notice?
    /// Esc means something while a recording or a job is live.
    var isBusy: Bool { machine.isBusy }

    static let longestRecording: Duration = .seconds(600)

    private var machine = SessionMachine(makeJobID: UUID.init)
    private var stage: Stage?
    @ObservationIgnored private var recordingStarted = Date.now
    @ObservationIgnored private var jobs: [JobID: Job] = [:]
    @ObservationIgnored private var cancelled: Set<JobID> = []
    @ObservationIgnored private var running: (id: JobID, task: Task<Void, Never>)?
    @ObservationIgnored private var selection: (recording: RecordingID, task: Task<String, Never>)?
    @ObservationIgnored private var mute: MuteToken?
    @ObservationIgnored private var inbox: [SessionEvent] = []
    @ObservationIgnored private var draining = false
    @ObservationIgnored private var noticeGeneration = 0
    @ObservationIgnored private var corrections: CorrectionWatcher?

    private struct Job {
        let audio: AudioSamples
        let request: Request
        /// The app the recording was made in; the result is pasted only if it is still frontmost.
        let app: String?
    }

    private let settings: SettingsStore
    private let vault: Vault
    private let dictionary: DictionaryStore
    private let history: HistoryStore
    private let engines: Engines
    private let recorder: Recorder
    private let inserter: Inserter
    private let answers: AnswerPanel
    private let setup: SetupStatus

    init(settings: SettingsStore, vault: Vault, dictionary: DictionaryStore, history: HistoryStore, engines: Engines,
         recorder: Recorder, inserter: Inserter, answers: AnswerPanel, setup: SetupStatus) {
        self.settings = settings
        self.vault = vault
        self.dictionary = dictionary
        self.history = history
        self.engines = engines
        self.recorder = recorder
        self.inserter = inserter
        self.answers = answers
        self.setup = setup
        corrections = CorrectionWatcher { [weak self] in self?.learn($0) }
    }

    /// The single consumer of hotkey gestures, in order.
    func run(_ gestures: AsyncStream<Gesture>) async {
        for await gesture in gestures {
            if case .escape = gesture, !machine.isBusy {
                answers.close()
                continue
            }
            raise(.gesture(gesture))
        }
    }

    func start(_ mode: Mode) { raise(.start(mode)) }
    func finish() { raise(.finish) }
    func cancel() { raise(.cancel) }
    func dismissNotice() { notice = nil }

    /// Runs a History entry again with today's engines. The result is pasted only if its app is still frontmost,
    /// otherwise copied.
    func retry(_ id: JobID) {
        Task {
            guard let (entry, audio) = await history.reopen(id) else { return show(.retryUnavailable) }
            jobs[id] = Job(audio: audio, request: entry.request, app: entry.app)
            raise(.retry(id))
        }
    }

    // MARK: - Effects

    /// Events raised while effects run are queued and handled after the current batch, so an effect never sees a
    /// machine state newer than the one that produced it.
    private func raise(_ event: SessionEvent) {
        inbox.append(event)
        guard !draining else { return }
        draining = true
        while !inbox.isEmpty {
            for effect in machine.handle(inbox.removeFirst()) { perform(effect) }
        }
        draining = false
        updatePhase()
    }

    private func perform(_ effect: SessionEffect) {
        switch effect {
        case let .beginRecording(id, mode):
            begin(id, mode)
        case let .changeMode(id, mode):
            if mode == .ask, selection?.recording != id { captureSelection(for: id) }
        case .styleDecided:
            break
        case let .endRecording(id, mode, job):
            end(id, mode, job)
        case let .discardRecording(id):
            recorder.discard()
            restoreOutput()
            if selection?.recording == id { selection?.task.cancel() }
            selection = nil
        case let .runJob(id):
            running = (id, Task { await execute(id) })
        case let .cancelJob(id):
            if running?.id == id { running?.task.cancel() } else { cancelled.insert(id) }
        }
    }

    private func begin(_ id: RecordingID, _ mode: Mode) {
        if let issue = setup.recordingBlocker {
            raise(.captureFailed(id))
            return show(.setupNeeded(issue))
        }
        notice = nil
        answers.close()
        corrections?.stop()
        do {
            if try recorder.start(settings.prefs.microphone), case let .device(_, name) = settings.prefs.microphone {
                show(.microphoneMissing(name))
            }
        } catch {
            raise(.captureFailed(id))
            return show(.microphoneFailed(error))
        }
        recordingStarted = .now
        if mode == .ask { captureSelection(for: id) }
        if settings.prefs.sounds { Sounds.start.play() }
        // A hands-free recording the user forgot about ends by itself.
        Task {
            try? await Task.sleep(for: Self.longestRecording)
            if machine.recording?.id == id { raise(.finish) }
        }
        if settings.prefs.muteWhileRecording {
            // After the start chime, which plays through the output being muted.
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                if machine.recording?.id == id, mute == nil { mute = MuteToken.muteOutput() }
            }
        }
        let setup = EngineSetup(settings.prefs, key: vault.key)
        Task { await engines.prewarm(setup) }
    }

    private func end(_ id: RecordingID, _ mode: Mode, _ job: JobID) {
        let audio = recorder.stop()
        restoreOutput()
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let pendingSelection = selection?.recording == id ? selection?.task : nil
        selection = nil
        guard !audio.isEffectivelySilent else {
            raise(.jobDropped(job))
            return show(.nothingHeard)
        }
        let target = settings.prefs.translationTarget
        Task {
            let request: Request = switch mode {
            case .dictation: .dictate
            case .translation: .translate(to: target)
            case .ask: .ask(selection: await pendingSelection?.value ?? "")
            }
            // Durable before any engine runs: from here on, a failure or a crash cannot lose this speech.
            await history.open(HistoryEntry(id: job, created: .now, request: request, app: app,
                                            audioSeconds: audio.duration, hasAudio: false), audio: audio)
            if cancelled.remove(job) != nil {
                await history.close(job, transcript: nil, outcome: .failed(.cancelled),
                                    retention: settings.prefs.historyRetention)
                return raise(.jobDropped(job))
            }
            jobs[job] = Job(audio: audio, request: request, app: app)
            raise(.jobReady(job))
        }
    }

    private func execute(_ id: JobID) async {
        defer {
            jobs[id] = nil
            running = nil
            stage = nil
            raise(.jobEnded(id))
        }
        guard let job = jobs[id] else { return }
        let prefs = settings.prefs
        setStage(.preparing, for: id)
        await vault.loaded()
        let setup = EngineSetup(prefs, key: vault.key)
        let context = JobContext(language: prefs.spokenLanguage.language, profile: prefs.personalization.profile,
                                 tone: prefs.personalization.tone(for: job.app), lexicon: dictionary.lexicon)
        var transcript: String?
        let outcome: Outcome
        do throws(PipelineFailure) {
            do {
                try await engines.prepare(setup)
            } catch {
                throw PipelineFailure(reason: Failure(error), stage: .preparing, transcript: nil)
            }
            let pipeline = await engines.pipeline(for: setup)
            let result = try await pipeline.run(job.audio, job.request, context,
                                                budget: Budget.ai(local: setup.ai.engine.isLocal, audio: job.audio.length)) { stage in
                Task { @MainActor [weak self] in self?.setStage(stage, for: id) }
            }
            transcript = result.transcript
            outcome = deliver(result.output, question: result.transcript, for: job)
            if outcome.text != nil {
                await history.recordUsage(result.transcript, spokenSeconds: job.audio.duration)
            }
        } catch {
            transcript = error.transcript
            outcome = .failed(error.reason)
            if error.reason != .cancelled {
                if prefs.sounds { Sounds.failed.play() }
                show(.failed(error.reason, entry: id, transcript: error.transcript))
            }
        }
        await history.close(id, transcript: transcript, outcome: outcome, retention: prefs.historyRetention)
    }

    private func deliver(_ output: Output, question: String, for job: Job) -> Outcome {
        switch output {
        case let .insert(text), let .replaceSelection(text):
            let kind: Delivery = if case .replaceSelection = output { .replacedSelection } else { .inserted }
            let sameApp = job.app == nil || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == job.app
            if sameApp, Inserter.focusedElement() != nil, inserter.paste(text) == .pasted {
                if settings.prefs.learnFromCorrections { corrections?.watch(inserted: text) }
                if settings.prefs.sounds { Sounds.done.play() }
                return .delivered(text, kind)
            }
            inserter.copy(text)
            show(.copied)
            return .delivered(text, .copied)
        case let .answer(text):
            answers.show(question: question, answer: text)
            return .delivered(text, .answered)
        case let .open(url):
            NSWorkspace.shared.open(url)
            return .delivered(url.absoluteString, .opened)
        case .nothing(.noSpeech):
            show(.nothingHeard)
            return .nothingSaid
        case .nothing(.nothingSaid):
            return .nothingSaid
        }
    }

    // MARK: - Helpers

    private func captureSelection(for id: RecordingID) {
        selection?.task.cancel()
        selection = (id, Task { await inserter.selectedText() })
    }

    private func restoreOutput() {
        mute?.restore()
        mute = nil
    }

    /// Stage reports hop to the main actor, so one can arrive after its job ended; only the running job's count.
    private func setStage(_ stage: Stage, for id: JobID) {
        guard running?.id == id else { return }
        self.stage = stage
        updatePhase()
    }

    /// A finished recording shows as processing from the moment it ends, while it is still being saved, so the bar
    /// doesn't blink out between the two.
    private func updatePhase() {
        if let recording = machine.recording {
            phase = .recording(recording.mode, recording.style, since: recordingStarted)
        } else if !machine.jobs.isEmpty {
            phase = .processing(stage ?? .preparing)
        } else {
            phase = .idle
        }
        waiting = max(0, machine.jobs.count - 1)
    }

    private func learn(_ corrections: [Correction]) {
        let learned = dictionary.lexicon.learn(corrections, at: .now)
        if !learned.isEmpty { show(.learned(learned.map(\.text))) }
    }

    private func show(_ notice: Notice) {
        self.notice = notice
        noticeGeneration += 1
        let generation = noticeGeneration
        Task {
            try? await Task.sleep(for: notice.lasts)
            if generation == noticeGeneration { self.notice = nil }
        }
    }
}

/// The Ask Anything answer, shown in a floating panel that never takes focus from the user's app.
@MainActor @Observable
final class AnswerPanel {
    struct Answer: Equatable {
        let question: String
        let text: String
    }

    private(set) var current: Answer?
    var isVisible: Bool { current != nil }

    @ObservationIgnored private let inserter: Inserter

    init(inserter: Inserter) { self.inserter = inserter }

    func show(question: String, answer: String) { current = Answer(question: question, text: answer) }
    func close() { current = nil }

    func copy() {
        guard let current else { return }
        inserter.copy(current.text)
    }

    /// Pastes into the frontmost app. The panel doesn't activate SaidDone, so that is still the user's app.
    func insert() {
        guard let current else { return }
        _ = inserter.paste(current.text)
        close()
    }
}
