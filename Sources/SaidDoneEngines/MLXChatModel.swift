import Foundation
import Hub
import MLXLLM
import MLXLMCommon
import SaidDoneCore

/// On-device chat via MLX. Loads once, however many callers ask at the same time.
actor MLXChatModel: ChatModel, LocalEngine {
    private let model: QwenModel
    private let files: ModelFiles
    private var loading: Task<ModelContainer, any Error>?

    init(model: QwenModel, files: ModelFiles) {
        self.model = model
        self.files = files
    }

    func load() async throws(EngineError) { _ = try await container() }

    func reply(to prompt: Prompt) async throws(EngineError) -> String {
        let container = try await container()
        let parameters = GenerateParameters(maxTokens: prompt.maxOutputTokens, temperature: 0)
        do {
            return try await container.perform { context in
                // Hybrid Qwen3 builds think unless the chat template is told not to; other templates ignore the flag.
                let input = try await context.processor.prepare(input: UserInput(
                    chat: [.system(prompt.system), .user(prompt.user)],
                    additionalContext: ["enable_thinking": false]))
                return try MLXLMCommon.generate(input: input, parameters: parameters, context: context) { _ in
                    Task.isCancelled ? .stop : .more
                }.output
            }
        } catch {
            throw Task.isCancelled ? .cancelled : .badResponse
        }
    }

    private func container() async throws(EngineError) -> ModelContainer {
        guard files.isInstalled(.qwen(model)) else { throw .modelMissing }
        let task = loading ?? Task { [model, files] in
            try await LLMModelFactory.shared.loadContainer(
                hub: HubApi(downloadBase: files.root, useOfflineMode: true),
                configuration: ModelConfiguration(directory: files.folder(.qwen(model))))
        }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil
            throw .modelMissing
        }
    }

    static func download(_ model: QwenModel, into files: ModelFiles, endpoint: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await HubApi(downloadBase: files.root, endpoint: endpoint)
            .snapshot(from: Hub.Repo(id: model.rawValue), matching: ["*.safetensors", "*.json", "*.jinja"]) {
                progress($0.fractionCompleted)
            }
    }
}
