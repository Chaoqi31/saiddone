import Foundation

/// On-device speech models (WhisperKit Core ML builds from argmaxinc/whisperkit-coreml).
public enum WhisperModel: String, Codable, CaseIterable, Sendable {
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_turbo"
    case largeV3TurboCompact = "openai_whisper-large-v3-v20240930_turbo_632MB"
    case largeV3 = "openai_whisper-large-v3"

    public static let recommended = WhisperModel.largeV3Turbo

    public var name: String {
        switch self {
        case .largeV3Turbo: "Whisper large-v3 turbo"
        case .largeV3TurboCompact: "Whisper large-v3 turbo (compact)"
        case .largeV3: "Whisper large-v3"
        }
    }

    public var approximateBytes: Int64 {
        switch self {
        case .largeV3Turbo: 1_638_000_000
        case .largeV3TurboCompact: 646_000_000
        case .largeV3: 3_090_000_000
        }
    }
}

/// On-device AI models (MLX builds from mlx-community).
public enum QwenModel: String, Codable, CaseIterable, Sendable {
    case qwen3_4B = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    case qwen3_1_7B = "mlx-community/Qwen3-1.7B-4bit"
    case qwen3_8B = "mlx-community/Qwen3-8B-4bit"

    public static let recommended = QwenModel.qwen3_4B

    public var name: String {
        switch self {
        case .qwen3_4B: "Qwen3 4B"
        case .qwen3_1_7B: "Qwen3 1.7B"
        case .qwen3_8B: "Qwen3 8B"
        }
    }

    public var approximateBytes: Int64 {
        switch self {
        case .qwen3_4B: 2_279_000_000
        case .qwen3_1_7B: 984_000_000
        case .qwen3_8B: 4_624_000_000
        }
    }
}

public enum LocalModel: Hashable, Sendable {
    case whisper(WhisperModel)
    case qwen(QwenModel)

    public static let all: [LocalModel] = WhisperModel.allCases.map(LocalModel.whisper) + QwenModel.allCases.map(LocalModel.qwen)

    public var name: String {
        switch self {
        case let .whisper(model): model.name
        case let .qwen(model): model.name
        }
    }

    public var approximateBytes: Int64 {
        switch self {
        case let .whisper(model): model.approximateBytes
        case let .qwen(model): model.approximateBytes
        }
    }
}

/// Who a cloud endpoint belongs to. Also the credential key, so one OpenAI key serves speech and AI.
public struct VendorID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let volcengine: VendorID = "volcengine"
    public static let customChat: VendorID = "custom-chat"
    public static let customSpeech: VendorID = "custom-speech"
}

/// An OpenAI-compatible endpoint: `/chat/completions` for AI, `/audio/transcriptions` for speech.
public struct CloudEndpoint: Codable, Hashable, Sendable {
    public var vendor: VendorID
    public var baseURL: URL
    public var model: String

    public init(vendor: VendorID, baseURL: URL, model: String) {
        self.vendor = vendor
        self.baseURL = baseURL
        self.model = model
    }
}

/// The request parameters a vendor's chat endpoint expects. Every dialect asks for deterministic output with bounded
/// length and no reasoning: dictation cleanup needs no chain of thought, and thinking multiplies latency.
public enum ChatDialect: Sendable {
    /// `max_tokens`, `temperature: 0`.
    case standard
    /// Standard plus `"thinking": {"type": "disabled"}` (DeepSeek, Zhipu GLM).
    case thinkingOff
    /// `max_completion_tokens`, `temperature: 0`, `"reasoning_effort": "none"` (OpenAI GPT-5).
    case openAI
}

public struct CloudPreset: Identifiable, Hashable, Sendable {
    public let id: VendorID
    public let name: String
    public let baseURL: URL
    /// Known-good suggestions, the first being the default. Empty = pick from the endpoint's own model list.
    public let models: [String]
    public let requiresKey: Bool
    public let dialect: ChatDialect
    /// Where the user gets a key.
    public let keyURL: URL?

    public var defaultEndpoint: CloudEndpoint { CloudEndpoint(vendor: id, baseURL: baseURL, model: models.first ?? "") }

    public static func == (a: CloudPreset, b: CloudPreset) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public static let deepseek = CloudPreset(
        "deepseek", "DeepSeek", "https://api.deepseek.com", ["deepseek-flash", "deepseek-v4-pro"],
        dialect: .thinkingOff, keyURL: "https://platform.deepseek.com/api_keys")

    public static let chat: [CloudPreset] = [
        deepseek,
        CloudPreset("openai", "OpenAI", "https://api.openai.com/v1", ["gpt-5.6-luna", "gpt-5.6-terra"],
                    dialect: .openAI, keyURL: "https://platform.openai.com/api-keys"),
        CloudPreset("zhipu", "Zhipu GLM", "https://open.bigmodel.cn/api/paas/v4", ["glm-5.2"],
                    dialect: .thinkingOff, keyURL: "https://open.bigmodel.cn/usercenter/apikeys"),
        CloudPreset("moonshot", "Moonshot Kimi", "https://api.moonshot.cn/v1", [],
                    keyURL: "https://platform.moonshot.cn/console/api-keys"),
        CloudPreset("siliconflow", "SiliconFlow", "https://api.siliconflow.cn/v1", [],
                    keyURL: "https://cloud.siliconflow.cn/account/ak"),
        CloudPreset("openrouter", "OpenRouter", "https://openrouter.ai/api/v1", [],
                    keyURL: "https://openrouter.ai/settings/keys"),
        CloudPreset("groq", "Groq", "https://api.groq.com/openai/v1", [], keyURL: "https://console.groq.com/keys"),
        CloudPreset("ollama", "Ollama", "http://localhost:11434/v1", [], requiresKey: false),
        CloudPreset("lmstudio", "LM Studio", "http://localhost:1234/v1", [], requiresKey: false),
        CloudPreset(VendorID.customChat.rawValue, "Custom", "https://api.example.com/v1", [], requiresKey: false),
    ]

    public static let speech: [CloudPreset] = [
        CloudPreset("openai", "OpenAI", "https://api.openai.com/v1", ["gpt-transcribe", "gpt-4o-mini-transcribe"],
                    keyURL: "https://platform.openai.com/api-keys"),
        CloudPreset("groq", "Groq", "https://api.groq.com/openai/v1", ["whisper-large-v3-turbo"],
                    keyURL: "https://console.groq.com/keys"),
        CloudPreset("siliconflow", "SiliconFlow", "https://api.siliconflow.cn/v1", ["FunAudioLLM/SenseVoiceSmall"],
                    keyURL: "https://cloud.siliconflow.cn/account/ak"),
        CloudPreset(VendorID.customSpeech.rawValue, "Custom", "https://api.example.com/v1", [], requiresKey: false),
    ]

    public static func chat(_ vendor: VendorID) -> CloudPreset? { chat.first { $0.id == vendor } }
    public static func speech(_ vendor: VendorID) -> CloudPreset? { speech.first { $0.id == vendor } }

    /// Display name for any vendor.
    public static func name(_ vendor: VendorID) -> String {
        if vendor == .volcengine { return "Volcengine" }
        return (chat(vendor) ?? speech(vendor))?.name ?? vendor.rawValue
    }

    private init(_ id: String, _ name: String, _ baseURL: String, _ models: [String], requiresKey: Bool = true,
                 dialect: ChatDialect = .standard, keyURL: String? = nil) {
        self.id = VendorID(rawValue: id)
        self.name = name
        self.baseURL = URL(string: baseURL)!
        self.models = models
        self.requiresKey = requiresKey
        self.dialect = dialect
        self.keyURL = keyURL.flatMap(URL.init(string:))
    }
}
