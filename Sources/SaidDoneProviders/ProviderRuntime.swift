import SaidDoneCore

/// Reports which concrete adapters changed after applying a new AppConfig.
public struct ProviderReplacements: Sendable, Equatable {
    public var asr: Bool
    public var llm: Bool

    public init(asr: Bool, llm: Bool) {
        self.asr = asr
        self.llm = llm
    }

    public static let none = ProviderReplacements(asr: false, llm: false)
}

/// Owns the live Provider adapters and preserves their warm state until provider-relevant
/// configuration actually changes.
public struct ProviderRuntime {
    public private(set) var asr: ASRProvider
    public private(set) var llm: LLMProvider

    private var asrFingerprint: ASRFingerprint
    private var llmFingerprint: LLMFingerprint

    public init(config: AppConfig) {
        asr = ProviderFactory.makeASR(config)
        llm = ProviderFactory.makeLLM(config)
        asrFingerprint = ASRFingerprint(config)
        llmFingerprint = LLMFingerprint(config)
    }

    @discardableResult
    public mutating func apply(_ config: AppConfig) -> ProviderReplacements {
        let nextASR = ASRFingerprint(config)
        let nextLLM = LLMFingerprint(config)
        let replacements = ProviderReplacements(
            asr: nextASR != asrFingerprint,
            llm: nextLLM != llmFingerprint)

        if replacements.asr {
            asr = ProviderFactory.makeASR(config)
            asrFingerprint = nextASR
        }
        if replacements.llm {
            llm = ProviderFactory.makeLLM(config)
            llmFingerprint = nextLLM
        }
        return replacements
    }
}

private enum ASRFingerprint: Equatable {
    case local(modelID: String)
    case cloud(baseURL: String, key: String, model: String, proxyHost: String, proxyPort: Int)

    init(_ config: AppConfig) {
        switch config.asr.location {
        case .local:
            self = .local(modelID: config.asr.modelID)
        case .cloud:
            self = .cloud(
                baseURL: config.cloud.asrBaseURL,
                key: config.cloud.asrKey,
                model: config.cloud.asrModel,
                proxyHost: config.cloud.proxyHost,
                proxyPort: config.cloud.proxyPort)
        }
    }
}

private enum LLMFingerprint: Equatable {
    case local(modelID: String)
    case cloud(providerID: String, baseURL: String, key: String, model: String,
               proxyHost: String, proxyPort: Int)

    init(_ config: AppConfig) {
        switch config.llm.location {
        case .local:
            self = .local(modelID: config.llm.modelID)
        case .cloud:
            self = .cloud(
                providerID: config.cloud.llmProviderID,
                baseURL: config.cloud.llmBaseURL,
                key: config.cloud.llmAPIKeys[config.cloud.llmProviderID] ?? "",
                model: config.cloud.llmModel,
                proxyHost: config.cloud.proxyHost,
                proxyPort: config.cloud.proxyPort)
        }
    }
}
