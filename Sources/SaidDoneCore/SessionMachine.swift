import Foundation

public struct RecordingID: Hashable, Sendable {
    public let raw: UInt64
    public init(raw: UInt64) { self.raw = raw }
}

/// Also the History entry id: a job is born as a History row.
public typealias JobID = UUID

/// `undecided` until the starting key is released. A hold ends the recording on release, so there is no separate
/// hold state. `toggle` = it was a tap: the recording runs hands-free until the next shortcut press.
public enum RecordingStyle: Equatable, Sendable {
    case undecided
    case toggle
}

public enum SessionEvent: Equatable, Sendable {
    case gesture(Gesture)
    case start(Mode)            // status menu
    case finish                 // voice bar ✓, status menu
    case cancel                 // voice bar ✕, status menu
    case captureFailed(RecordingID)
    case jobReady(JobID)        // the job's History row and audio are durable
    case jobDropped(JobID)      // nothing to process (silence) or it could not be persisted
    case jobEnded(JobID)
    case retry(JobID)           // History "Retry": the row was reopened and is ready to run
}

public enum SessionEffect: Equatable, Sendable {
    case beginRecording(RecordingID, Mode)
    /// Audio is kept; switching into Ask grabs the selection.
    case changeMode(RecordingID, Mode)
    case styleDecided(RecordingID, RecordingStyle)
    /// The job's place in the queue is fixed now, in the order recordings end.
    case endRecording(RecordingID, Mode, JobID)
    case discardRecording(RecordingID)
    case runJob(JobID)
    case cancelJob(JobID)
}

/// The recording lifecycle and the job queue. Pure: `Session` in the app performs the effects.
///
/// A press never waits for processing: recording and processing are separate resources, and jobs run and deliver
/// one at a time in the order their recordings ended.
public struct SessionMachine: Sendable {
    /// Released sooner: it was a tap, keep recording hands-free. Held longer: hold-to-talk, release finishes.
    public static let holdThreshold: Duration = .milliseconds(350)

    public struct Recording: Equatable, Sendable {
        public let id: RecordingID
        public var mode: Mode
        public var style: RecordingStyle
        /// nil when started from the menu.
        public let startedBy: GestureID?
    }

    public struct QueuedJob: Equatable, Sendable {
        public let id: JobID
        public var ready: Bool
    }

    public private(set) var recording: Recording?
    /// FIFO. The head runs once it is ready.
    public private(set) var jobs: [QueuedJob] = []
    private var lastRecordingID: UInt64 = 0
    private let makeJobID: @Sendable () -> JobID

    public init(makeJobID: @escaping @Sendable () -> JobID = { UUID() }) {
        self.makeJobID = makeJobID
    }

    public var isBusy: Bool { recording != nil || !jobs.isEmpty }
    public var runningJob: JobID? { jobs.first.flatMap { $0.ready ? $0.id : nil } }

    public mutating func handle(_ event: SessionEvent) -> [SessionEffect] {
        switch event {
        case let .gesture(gesture):
            return handle(gesture)
        case let .start(mode):
            guard let recording else { return begin(mode, by: nil, style: .toggle) }
            return finish(recording, as: mode)
        case .finish:
            guard let recording else { return [] }
            return finish(recording, as: recording.mode)
        case .cancel:
            return cancel()
        case let .captureFailed(id):
            if recording?.id == id { recording = nil }
            return []
        case let .jobReady(id):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return [] }
            jobs[index].ready = true
            return index == 0 ? [.runJob(id)] : []
        case let .jobDropped(id), let .jobEnded(id):
            let wasHead = jobs.first?.id == id
            jobs.removeAll { $0.id == id }
            guard wasHead, let head = jobs.first, head.ready else { return [] }
            return [.runJob(head.id)]
        case let .retry(id):
            guard !jobs.contains(where: { $0.id == id }) else { return [] }
            jobs.append(QueuedJob(id: id, ready: true))
            return jobs.count == 1 ? [.runJob(id)] : []
        }
    }

    private mutating func handle(_ gesture: Gesture) -> [SessionEffect] {
        switch gesture {
        case let .pressed(mode, gestureID):
            guard var recording else { return begin(mode, by: gestureID, style: .undecided) }
            switch recording.style {
            case .toggle:
                // Hands-free: any shortcut finishes, and the one you finish with picks the mode.
                return finish(recording, as: mode)
            case .undecided:
                // Still holding the starting key. Another mode's shortcut switches; the same mode's finishes.
                guard gestureID != recording.startedBy else { return [] }
                guard mode != recording.mode else { return finish(recording, as: mode) }
                recording.mode = mode
                self.recording = recording
                return [.changeMode(recording.id, mode)]
            }
        case let .retargeted(mode, gestureID):
            guard var recording, recording.startedBy == gestureID, recording.mode != mode else { return [] }
            recording.mode = mode
            self.recording = recording
            return [.changeMode(recording.id, mode)]
        case let .released(_, gestureID, held):
            guard var recording, recording.startedBy == gestureID, recording.style == .undecided else { return [] }
            if held >= Self.holdThreshold { return finish(recording, as: recording.mode) }
            recording.style = .toggle
            self.recording = recording
            return [.styleDecided(recording.id, .toggle)]
        case let .aborted(gestureID):
            guard let recording, recording.startedBy == gestureID, recording.style == .undecided else { return [] }
            self.recording = nil
            return [.discardRecording(recording.id)]
        case .escape:
            return cancel()
        }
    }

    private mutating func begin(_ mode: Mode, by gestureID: GestureID?, style: RecordingStyle) -> [SessionEffect] {
        lastRecordingID += 1
        let recording = Recording(id: RecordingID(raw: lastRecordingID), mode: mode, style: style, startedBy: gestureID)
        self.recording = recording
        return [.beginRecording(recording.id, mode)]
    }

    private mutating func finish(_ recording: Recording, as mode: Mode) -> [SessionEffect] {
        self.recording = nil
        let job = makeJobID()
        jobs.append(QueuedJob(id: job, ready: false))
        var effects: [SessionEffect] = []
        if mode != recording.mode { effects.append(.changeMode(recording.id, mode)) }
        effects.append(.endRecording(recording.id, mode, job))
        return effects
    }

    /// Esc and ✕ cancel the recording first, then the running job.
    private mutating func cancel() -> [SessionEffect] {
        if let recording {
            self.recording = nil
            return [.discardRecording(recording.id)]
        }
        guard let running = runningJob else { return [] }
        return [.cancelJob(running)]
    }
}
