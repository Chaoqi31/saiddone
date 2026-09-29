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
        case .largeV3Turbo: 1_600_000_000
        case .largeV3TurboCompact: 632_000_000
        case .largeV3: 3_100_000_000
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
        case .qwen3_4B: 2_300_000_000
        case .qwen3_1_7B: 1_000_000_000
        case .qwen3_8B: 4_600_000_000
        }
    }

    /// Hybrid Qwen3 builds think unless the chat template is told not to; the 2507 Instruct build never thinks.
    public var isHybridThinking: Bool { self != .qwen3_4B }
}

public enum LocalModel: Hashable, Sendable {
    case whisper(WhisperModel)
    case qwen(QwenModel)

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

/// How a vendor lets a request turn reasoning off. Dictation cleanup needs no chain of thought, and thinking
/// multiplies latency; vendors that don't know the parameter reject the request, so it is sent only where accepted.
public enum ThinkingSwitch: Sendable {
    case unsupported
    /// `"thinking": {"type": "disabled"}` (DeepSeek, Zhipu GLM).
    case thinkingType
}

public struct CloudPreset: Identifiable, Hashable, Sendable {
    public let id: VendorID
    public let name: String
    public let baseURL: URL
    /// Suggestions; the first is the default. Any model name can be typed.
    public let models: [String]
    public let requiresKey: Bool
    public let thinking: ThinkingSwitch
    /// Where the user gets a key.
    public let keyURL: URL?

    public var defaultEndpoint: CloudEndpoint { CloudEndpoint(vendor: id, baseURL: baseURL, model: models.first ?? "") }

    public static func == (a: CloudPreset, b: CloudPreset) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public static let deepseek = CloudPreset(
        "deepseek", "DeepSeek", "https://api.deepseek.com/v1", ["deepseek-chat"],
        thinking: .thinkingType, keyURL: "https://platform.deepseek.com/api_keys")

    public static let chat: [CloudPreset] = [
        deepseek,
        CloudPreset("openai", "OpenAI", "https://api.openai.com/v1", ["gpt-4.1-mini", "gpt-4o-mini", "gpt-4.1"],
                    keyURL: "https://platform.openai.com/api-keys"),
        CloudPreset("zhipu", "Zhipu GLM", "https://open.bigmodel.cn/api/paas/v4", ["glm-4.5-air", "glm-4.6", "glm-4.5"],
                    thinking: .thinkingType, keyURL: "https://open.bigmodel.cn/usercenter/apikeys"),
        CloudPreset("moonshot", "Moonshot Kimi", "https://api.moonshot.cn/v1", ["kimi-k2-turbo-preview", "kimi-k2-0905-preview"],
                    keyURL: "https://platform.moonshot.cn/console/api-keys"),
        CloudPreset("siliconflow", "SiliconFlow", "https://api.siliconflow.cn/v1",
                    ["Qwen/Qwen3-235B-A22B-Instruct-2507", "deepseek-ai/DeepSeek-V3"],
                    keyURL: "https://cloud.siliconflow.cn/account/ak"),
        CloudPreset("openrouter", "OpenRouter", "https://openrouter.ai/api/v1",
                    ["openai/gpt-4.1-mini", "google/gemini-2.5-flash", "anthropic/claude-sonnet-4.5"],
                    keyURL: "https://openrouter.ai/settings/keys"),
        CloudPreset("groq", "Groq", "https://api.groq.com/openai/v1", ["llama-3.3-70b-versatile", "openai/gpt-oss-120b"],
                    keyURL: "https://console.groq.com/keys"),
        CloudPreset("xai", "xAI", "https://api.x.ai/v1", ["grok-4-fast-non-reasoning", "grok-4"],
                    keyURL: "https://console.x.ai"),
        CloudPreset("cerebras", "Cerebras", "https://api.cerebras.ai/v1", ["llama-3.3-70b", "gpt-oss-120b"],
                    keyURL: "https://cloud.cerebras.ai"),
        CloudPreset("ollama", "Ollama", "http://localhost:11434/v1", ["qwen3:4b", "llama3.2"], requiresKey: false),
        CloudPreset("lmstudio", "LM Studio", "http://localhost:1234/v1", ["local-model"], requiresKey: false),
        CloudPreset(VendorID.customChat.rawValue, "Custom", "https://api.example.com/v1", ["model-name"], requiresKey: false),
    ]

    public static let speech: [CloudPreset] = [
        CloudPreset("openai", "OpenAI", "https://api.openai.com/v1",
                    ["gpt-4o-mini-transcribe", "gpt-4o-transcribe", "whisper-1"],
                    keyURL: "https://platform.openai.com/api-keys"),
        CloudPreset("groq", "Groq", "https://api.groq.com/openai/v1", ["whisper-large-v3-turbo", "whisper-large-v3"],
                    keyURL: "https://console.groq.com/keys"),
        CloudPreset("siliconflow", "SiliconFlow", "https://api.siliconflow.cn/v1", ["FunAudioLLM/SenseVoiceSmall"],
                    keyURL: "https://cloud.siliconflow.cn/account/ak"),
        CloudPreset(VendorID.customSpeech.rawValue, "Custom", "https://api.example.com/v1", ["model-name"], requiresKey: false),
    ]

    public static func chat(_ vendor: VendorID) -> CloudPreset? { chat.first { $0.id == vendor } }
    public static func speech(_ vendor: VendorID) -> CloudPreset? { speech.first { $0.id == vendor } }

    /// Display name for any vendor, including ones only reachable through a preset of the other half.
    public static func name(_ vendor: VendorID) -> String {
        if vendor == .volcengine { return "Volcengine" }
        return (chat(vendor) ?? speech(vendor))?.name ?? vendor.rawValue
    }

    private init(_ id: String, _ name: String, _ baseURL: String, _ models: [String], requiresKey: Bool = true,
                 thinking: ThinkingSwitch = .unsupported, keyURL: String? = nil) {
        self.id = VendorID(rawValue: id)
        self.name = name
        self.baseURL = URL(string: baseURL)!
        self.models = models
        self.requiresKey = requiresKey
        self.thinking = thinking
        self.keyURL = keyURL.flatMap(URL.init(string:))
    }
}

/// Volcengine (Doubao) file recognition. Its own protocol, not OpenAI-compatible.
public enum VolcengineResource: String, Codable, CaseIterable, Sendable {
    case turbo = "volc.bigasr.auc_turbo"
}
