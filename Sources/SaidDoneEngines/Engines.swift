import Foundation
import SaidDoneCore

/// An engine with weights to load before its first use.
protocol LocalEngine: Sendable {
    func load() async throws(EngineError)
}

/// Everything that decides which transcriber to build. On-device engines ignore the key and the proxy, so editing
/// either never reloads a model.
public struct SpeechSetup: Hashable, Sendable {
    public let engine: SpeechEngine
    public let key: String
    public let proxy: Proxy?

    public init(_ engine: SpeechEngine, key: String, proxy: Proxy?) {
        let local = engine.localModel != nil
        self.engine = engine
        self.key = local ? "" : key
        self.proxy = local ? nil : proxy
    }
}

/// Everything that decides which chat model to build.
public struct AISetup: Hashable, Sendable {
    public let engine: AIEngine
    public let key: String
    public let proxy: Proxy?

    public init(_ engine: AIEngine, key: String, proxy: Proxy?) {
        self.engine = engine
        self.key = engine.isLocal ? "" : key
        self.proxy = engine.isLocal ? nil : proxy
    }
}

public struct EngineSetup: Hashable, Sendable {
    public var speech: SpeechSetup
    public var ai: AISetup

    public init(speech: SpeechSetup, ai: AISetup) {
        self.speech = speech
        self.ai = ai
    }

    /// `key` returns the stored credential for a vendor, "" when there is none.
    public init(_ prefs: Preferences, key: (VendorID) -> String) {
        speech = SpeechSetup(prefs.speech, key: prefs.speech.vendor.map(key) ?? "", proxy: prefs.proxy)
        ai = AISetup(prefs.ai, key: prefs.ai.vendor.map(key) ?? "", proxy: prefs.proxy)
    }
}

/// The only place engines are built. Keeps one warm instance per half, so switching the AI model keeps the loaded
/// speech model, and the same setup always gets the same instances.
public actor Engines {
    public nonisolated let files: ModelFiles
    private let makeSession: @Sendable (Proxy?) -> URLSession
    private var speech: (setup: SpeechSetup, engine: any Transcriber)?
    private var ai: (setup: AISetup, engine: any ChatModel)?
    private var sessions: [Proxy?: URLSession] = [:]
    private var primed: [URL: ContinuousClock.Instant] = [:]

    public init(files: ModelFiles = .standard) {
        self.init(files: files, makeSession: HTTP.session(proxy:))
    }

    init(files: ModelFiles, makeSession: @escaping @Sendable (Proxy?) -> URLSession) {
        self.files = files
        self.makeSession = makeSession
    }

    public func pipeline(for setup: EngineSetup) -> Pipeline {
        Pipeline(transcriber: transcriber(setup.speech), chat: chatModel(setup.ai))
    }

    /// Loads on-device models. Awaited before a job runs, so loading never counts against the AI time budget.
    public func prepare(_ setup: EngineSetup) async throws(EngineError) {
        if let local = transcriber(setup.speech) as? any LocalEngine { try await local.load() }
        if let local = chatModel(setup.ai) as? any LocalEngine { try await local.load() }
    }

    /// Loads on-device models and opens the connections to cloud endpoints, so a job that follows soon pays for
    /// neither. Called at launch and whenever a recording starts; failures surface when the job runs.
    public func prewarm(_ setup: EngineSetup) async {
        try? await prepare(setup)
        if case let .cloud(endpoint) = setup.speech.engine {
            await prime(endpoint, key: setup.speech.key, proxy: setup.speech.proxy)
        }
        if case let .cloud(endpoint) = setup.ai.engine {
            await prime(endpoint, key: setup.ai.key, proxy: setup.ai.proxy)
        }
    }

    /// Proves the speech half works end to end: loads the model, or sends a second of silence to the service.
    public func test(_ setup: SpeechSetup) async throws(EngineError) {
        let engine = transcriber(setup)
        if let local = engine as? any LocalEngine { return try await local.load() }
        _ = try await engine.transcribe(AudioSamples(samples: [Float](repeating: 0, count: 16_000)), hints: RecognitionHints())
    }

    /// Proves the AI half works end to end: loads the model, or asks the service for a one-word reply.
    public func test(_ setup: AISetup) async throws(EngineError) {
        let engine = chatModel(setup)
        if let local = engine as? any LocalEngine { return try await local.load() }
        _ = try await engine.reply(to: Prompt(system: "Reply with the single word OK.", user: "ping", maxOutputTokens: 16))
    }

    /// The model names an OpenAI-compatible endpoint offers.
    public func models(at endpoint: CloudEndpoint, key: String, proxy: Proxy?) async throws(EngineError) -> [String] {
        try await OpenAICompatible(baseURL: endpoint.baseURL, key: key, session: session(proxy)).models()
    }

    // MARK: - Building

    private func transcriber(_ setup: SpeechSetup) -> any Transcriber {
        if let speech, speech.setup == setup { return speech.engine }
        let engine: any Transcriber = switch setup.engine {
        case let .whisper(model):
            WhisperKitTranscriber(model: model, files: files)
        case let .cloud(endpoint):
            CloudTranscriber(transport: transport(endpoint, key: setup.key, proxy: setup.proxy), model: endpoint.model)
        case let .volcengine(appID):
            VolcengineTranscriber(appID: appID, key: setup.key, session: session(setup.proxy))
        }
        speech = (setup, engine)
        return engine
    }

    private func chatModel(_ setup: AISetup) -> any ChatModel {
        if let ai, ai.setup == setup { return ai.engine }
        let engine: any ChatModel = switch setup.engine {
        case let .qwen(model):
            MLXChatModel(model: model, files: files)
        case let .cloud(endpoint):
            CloudChatModel(transport: transport(endpoint, key: setup.key, proxy: setup.proxy), model: endpoint.model,
                           dialect: CloudPreset.chat(endpoint.vendor)?.dialect ?? .standard)
        }
        ai = (setup, engine)
        return engine
    }

    private func transport(_ endpoint: CloudEndpoint, key: String, proxy: Proxy?) -> OpenAICompatible {
        OpenAICompatible(baseURL: endpoint.baseURL, key: key, session: session(proxy))
    }

    private func session(_ proxy: Proxy?) -> URLSession {
        if let session = sessions[proxy] { return session }
        let session = makeSession(proxy)
        sessions[proxy] = session
        return session
    }

    /// At most once a minute per endpoint: an idle connection stays open about that long.
    private func prime(_ endpoint: CloudEndpoint, key: String, proxy: Proxy?) async {
        let now = ContinuousClock.now
        if let last = primed[endpoint.baseURL], last.duration(to: now) < .seconds(60) { return }
        primed[endpoint.baseURL] = now
        _ = try? await transport(endpoint, key: key, proxy: proxy).models()
    }
}
