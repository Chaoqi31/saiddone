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
/// multiplies latency. Support varies by model even within a vendor, so the transport drops the switch for a model
/// that rejects it.
public enum ThinkingSwitch: Sendable {
    case unsupported
    /// `"thinking": {"type": "disabled"}` (DeepSeek, Zhipu GLM).
    case thinkingType
    /// `"reasoning_effort": "none"` (OpenAI).
    case reasoningEffort
}

public struct CloudPreset: Identifiable, Hashable, Sendable {
    public let id: VendorID
    public let name: String
    public let baseURL: URL
    /// Known-good suggestions, the first being the default. Empty = pick from the endpoint's own model list.
    public let models: [String]
    public let requiresKey: Bool
    public let thinking: ThinkingSwitch
    /// Where the user gets a key.
    public let keyURL: URL?

    public var defaultEndpoint: CloudEndpoint { CloudEndpoint(vendor: id, baseURL: baseURL, model: models.first ?? "") }

    public static func == (a: CloudPreset, b: CloudPreset) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public static let deepseek = CloudPreset(
        "deepseek", "DeepSeek", "https://api.deepseek.com", ["deepseek-flash", "deepseek-v4-pro"],
        thinking: .thinkingType, keyURL: "https://platform.deepseek.com/api_keys")

    public static let chat: [CloudPreset] = [
        deepseek,
        CloudPreset("openai", "OpenAI", "https://api.openai.com/v1", ["gpt-5.6-luna", "gpt-5.6-terra"],
                    thinking: .reasoningEffort, keyURL: "https://platform.openai.com/api-keys"),
        CloudPreset("zhipu", "Zhipu GLM", "https://open.bigmodel.cn/api/paas/v4", ["glm-5.2"],
                    thinking: .thinkingType, keyURL: "https://open.bigmodel.cn/usercenter/apikeys"),
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
