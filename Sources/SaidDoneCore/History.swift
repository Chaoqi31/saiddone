import Foundation

/// One job: a recording and everything that happened to it. Written before any engine runs, so speech that
/// reached processing is never lost; the outcome is filled in when the job ends.
public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: JobID
    public let created: Date
    public var request: Request
    /// Bundle identifier of the app the user was in when the recording ended. Tone and delivery target.
    public var app: String?
    public var audioSeconds: Double
    /// The recording is stored at audio/<id>.m4a. False only if writing it failed.
    public var hasAudio: Bool
    public var transcript: String?
    public var outcome: Outcome

    public init(id: JobID, created: Date, request: Request, app: String?, audioSeconds: Double, hasAudio: Bool,
                transcript: String? = nil, outcome: Outcome = .pending) {
        self.id = id
        self.created = created
        self.request = request
        self.app = app
        self.audioSeconds = audioSeconds
        self.hasAudio = hasAudio
        self.transcript = transcript
        self.outcome = outcome
    }

    public var mode: Mode { request.mode }
}

public enum Outcome: Codable, Equatable, Sendable {
    /// Still processing. An entry found pending at launch was interrupted by a quit or crash.
    case pending
    case delivered(String, Delivery)
    case nothingSaid
    case failed(Failure)

    public var text: String? {
        if case let .delivered(text, _) = self { text } else { nil }
    }

    /// Failed or interrupted: the user may want to retry it.
    public var isUnfinished: Bool {
        switch self {
        case .pending, .failed: true
        case .delivered, .nothingSaid: false
        }
    }
}

public enum Delivery: String, Codable, Sendable {
    case inserted
    case replacedSelection
    /// Shown in the answer panel.
    case answered
    /// Opened a search in the browser.
    case opened
    /// Nowhere to paste (or the user switched apps before it finished): put on the clipboard instead.
    case copied
}

public enum Failure: Codable, Equatable, Sendable {
    case offline
    case unauthorized
    case rateLimited
    case serverBusy
    case timeout
    case rejected(String)
    case badResponse
    case modelMissing
    case missingCredential
    case emptyReply
    case cancelled
    case interrupted

    public init(_ error: EngineError) {
        self = switch error {
        case .offline: .offline
        case .unauthorized: .unauthorized
        case .rateLimited: .rateLimited
        case .serverBusy: .serverBusy
        case .timedOut: .timeout
        case let .rejected(message): .rejected(message)
        case .badResponse: .badResponse
        case .modelMissing: .modelMissing
        case .missingCredential: .missingCredential
        case .cancelled: .cancelled
        }
    }
}

public enum Retention: String, Codable, CaseIterable, Sendable {
    case forever, month, week, day, never

    /// When an entry may be deleted. nil = keep. Unfinished entries live at least a day whatever the setting, so a
    /// failure is never deleted before the user can retry it.
    public func expiry(of entry: HistoryEntry) -> Date? {
        let age: TimeInterval? = switch self {
        case .forever: nil
        case .month: 30 * 86_400
        case .week: 7 * 86_400
        case .day: 86_400
        case .never: 0
        }
        guard let age else { return nil }
        return entry.created.addingTimeInterval(entry.outcome.isUnfinished ? max(age, 86_400) : age)
    }
}

/// Lifetime totals, stored apart from the entries so pruning History never resets them.
public struct UsageStats: Codable, Equatable, Sendable {
    public var words = 0
    public var dictations = 0
    public var spokenSeconds = 0.0

    public init(words: Int = 0, dictations: Int = 0, spokenSeconds: Double = 0) {
        self.words = words
        self.dictations = dictations
        self.spokenSeconds = spokenSeconds
    }

    public mutating func record(_ text: String, spokenSeconds seconds: Double) {
        words += WordCount.count(text)
        dictations += 1
        spokenSeconds += seconds
    }

    /// Speaking pace across all dictations.
    public var wordsPerMinute: Int {
        spokenSeconds >= 1 ? Int((Double(words) / (spokenSeconds / 60)).rounded()) : 0
    }

    /// Typing the same words at 40 per minute, minus the time spent speaking. Never negative.
    public var timeSaved: Duration {
        .seconds(max(0, Double(words) / 40 * 60 - spokenSeconds))
    }
}

/// CJK characters count one each; any other run of letters or digits counts as one word.
public enum WordCount {
    public static func count(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                count += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord { count += 1 }
                inWord = true
            } else if scalar != "'" && scalar != "’" {
                inWord = false
            }
        }
        return count
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }
}
