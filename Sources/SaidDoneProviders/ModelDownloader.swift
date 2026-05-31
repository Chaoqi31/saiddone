import Foundation
import WhisperKit

/// Download the local speech model with progress (for the Setup tab's download button).
/// Requires access to huggingface.co (won't work on networks that block it).
public enum ModelDownloader {
    public static func downloadWhisper(
        model: String = "openai_whisper-large-v3-v20240930_turbo",
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        _ = try await WhisperKit.download(variant: model, progressCallback: { p in
            progress(p.fractionCompleted)
        })
    }
}
