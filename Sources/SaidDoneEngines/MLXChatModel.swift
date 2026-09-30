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
        guard Self.canRun else { throw .unsupported }
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

    /// MLX needs its compiled Metal shaders, which Xcode builds into mlx-swift_Cmlx.bundle and SwiftPM alone does
    /// not; without them MLX aborts the process on its first GPU call. These are the places MLX looks.
    static let canRun: Bool = {
        let binary = Bundle.main.executableURL?.deletingLastPathComponent()
        let colocated = ["mlx.metallib", "Resources/mlx.metallib"].compactMap { binary?.appending(path: $0) }
        if colocated.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) { return true }
        return ([Bundle.main.bundleURL] + Bundle.allBundles.compactMap(\.resourceURL)).contains { root in
            Bundle(url: root.appending(path: "mlx-swift_Cmlx.bundle"))?.url(forResource: "default",
                                                                          withExtension: "metallib") != nil
        }
    }()

    static func download(_ model: QwenModel, into files: ModelFiles, endpoint: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await HubApi(downloadBase: files.root, endpoint: endpoint)
            .snapshot(from: Hub.Repo(id: model.rawValue), matching: ["*.safetensors", "*.json", "*.jinja"]) {
                progress($0.fractionCompleted)
            }
    }
}
