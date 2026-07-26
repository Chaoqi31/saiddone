import Foundation
import WhisperKit
import Hub
import MLXLMCommon

/// Downloads local ASR models into Application Support so macOS Documents privacy does not block
/// WhisperKit at runtime. MLX keeps using Hub's default cache path.
///
/// `endpoint` empty = `huggingface.co`; pass `"https://hf-mirror.com"` to route downloads through the
/// China mirror (the #1 first-run failure point on mainland networks).
public enum ModelDownloader {
    /// A Hub client whose download base defaults to `~/Documents/huggingface`, optionally via a mirror.
    private static func hub(_ endpoint: String) -> HubApi {
        HubApi(endpoint: endpoint.isEmpty ? nil : endpoint)
    }

    /// Download the WhisperKit speech model (e.g. "openai_whisper-large-v3-v20240930_turbo").
    public static func downloadWhisper(
        model: String = "openai_whisper-large-v3-v20240930_turbo",
        endpoint: String = "",
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        let base = ModelStorage.whisperCanonicalBase
        if endpoint.isEmpty {
            _ = try await WhisperKit.download(variant: model,
                                              downloadBase: base,
                                              progressCallback: { progress($0.fractionCompleted) })
        } else {
            _ = try await WhisperKit.download(variant: model, downloadBase: base, endpoint: endpoint,
                                              progressCallback: { progress($0.fractionCompleted) })
        }
    }

    /// Download an MLX LLM (e.g. "mlx-community/Qwen3-4B-4bit") into the app's model dir. This also
    /// loads the weights once (warming them), so the first real polish isn't a cold load.
    public static func downloadMLX(
        repoID: String,
        endpoint: String = "",
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        _ = try await loadModelContainer(hub: hub(endpoint), id: repoID) { progress($0.fractionCompleted) }
    }
}
