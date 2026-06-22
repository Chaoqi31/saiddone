import Foundation

/// Where a Provider runs. Local and Cloud are co-equal first-class citizens (ADR-0001).
public enum ProviderLocation: String, Codable, Sendable, CaseIterable {
    case local
    case cloud
}

// MARK: - ASR

/// Turns captured audio into raw text. Implementations: Qwen3-ASR (MLX), WhisperKit, Cloud (ADR-0003).
public protocol ASRProvider: Sendable {
    var id: String { get }
    var location: ProviderLocation { get }
    /// Transcribe one utterance. `languageHint` nil = auto-detect (needed for zh-en code-switching, GOALS A2).
    func transcribe(_ audio: AudioSamples, languageHint: String?) async throws -> String
}

// MARK: - LLM

/// Tone/style context for Polish: per-app tone (App Profile) + the user's personal background
/// (their profession/jargon), so the LLM handles terminology and code-switching the way they do.
public struct PolishContext: Sendable {
    public var tonePrompt: String?
    public var userProfile: String?
    /// Primary spoken language (e.g. "zh") — helps polish fix code-switch ASR errors.
    public var spokenLanguage: String?
    public init(tonePrompt: String? = nil, userProfile: String? = nil, spokenLanguage: String? = nil) {
        self.tonePrompt = tonePrompt
        self.userProfile = userProfile
        self.spokenLanguage = spokenLanguage
    }
    public static let none = PolishContext()
}

/// Cleans up transcribed text and translates. Implementations: MLX-Qwen3.5 (local), Cloud (ADR-0004).
public protocol LLMProvider: Sendable {
    var id: String { get }
    var location: ProviderLocation { get }
    /// Light cleanup: punctuation, remove fillers/repeats, readable, keep terms (GOALS A5).
    func polish(_ text: String, context: PolishContext) async throws -> String
    /// Translate into `targetLanguage` (e.g. "en", "zh"). Used by Translation Mode (GOALS A4).
    func translate(_ text: String, to targetLanguage: String, context: PolishContext) async throws -> String
    /// Ask Anything: edit/query `selection` per a spoken request, or answer when selection is empty.
    func ask(_ question: String, selection: String, context: PolishContext) async throws -> String
}

public extension LLMProvider {
    func ask(_ question: String, selection: String, context: PolishContext) async throws -> String {
        throw ProviderError.notConfigured("Ask Anything needs an MLX or Cloud LLM")
    }
}

// MARK: - Errors

public enum ProviderError: Error, Sendable {
    case modelUnavailable(String)
    case latencyBudgetExceeded
    case notConfigured(String)
}
