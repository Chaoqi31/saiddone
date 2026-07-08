import Foundation

/// A cloud LLM preset: an OpenAI-compatible Chat Completions endpoint plus model suggestions.
public struct CloudProvider: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var displayName: String
    public var baseURL: String
    public var defaultModels: [String]
    public var needsAPIKey: Bool

    public init(id: String, displayName: String, baseURL: String,
                defaultModels: [String], needsAPIKey: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.defaultModels = defaultModels
        self.needsAPIKey = needsAPIKey
    }
}

public enum CloudProviderRegistry {
    public static let builtIn: [CloudProvider] = [
        .init(id: "openai", displayName: "OpenAI",
              baseURL: "https://api.openai.com/v1",
              defaultModels: ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "o4-mini"]),
        .init(id: "xai", displayName: "xAI",
              baseURL: "https://api.x.ai/v1",
              defaultModels: ["grok-4", "grok-4-fast"]),
        .init(id: "groq", displayName: "Groq",
              baseURL: "https://api.groq.com/openai/v1",
              defaultModels: ["llama-3.3-70b-versatile", "openai/gpt-oss-20b"]),
        .init(id: "cerebras", displayName: "Cerebras",
              baseURL: "https://api.cerebras.ai/v1",
              defaultModels: ["llama-3.3-70b"]),
        .init(id: "openrouter", displayName: "OpenRouter",
              baseURL: "https://openrouter.ai/api/v1",
              defaultModels: ["anthropic/claude-sonnet-4.5", "google/gemini-2.5-pro", "openai/gpt-4o-mini"]),
        .init(id: "ollama", displayName: "Ollama (local)",
              baseURL: "http://localhost:11434/v1",
              defaultModels: ["llama3.2", "qwen3"],
              needsAPIKey: false),
        .init(id: "lmstudio", displayName: "LM Studio (local)",
              baseURL: "http://localhost:1234/v1",
              defaultModels: [],
              needsAPIKey: false),
        .init(id: "deepseek", displayName: "DeepSeek",
              baseURL: "https://api.deepseek.com/v1",
              defaultModels: ["deepseek-chat", "deepseek-reasoner"]),
        .init(id: "moonshot", displayName: "Moonshot (Kimi)",
              baseURL: "https://api.moonshot.cn/v1",
              defaultModels: ["kimi-k2-0905-preview", "moonshot-v1-8k"]),
        .init(id: "zhipu", displayName: "Zhipu (GLM)",
              baseURL: "https://open.bigmodel.cn/api/paas/v4",
              defaultModels: ["glm-4.5", "glm-4.5-air"]),
        .init(id: "siliconflow", displayName: "SiliconFlow",
              baseURL: "https://api.siliconflow.cn/v1",
              defaultModels: ["Qwen/Qwen3-235B-A22B", "deepseek-ai/DeepSeek-V3"]),
    ]

}
