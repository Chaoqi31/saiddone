import Foundation
import SaidDoneCore

/// Single source of truth for local model locations and readiness.
/// New Whisper downloads live in Application Support; the historical Documents location remains
/// a read-only fallback so existing installations never have to download the model again.
public enum ModelStorage {
    public static var whisperCanonicalBase: URL {
        let support = (try? ConfigStore.defaultDirectory()) ?? URL(fileURLWithPath: NSHomeDirectory())
        return support.appending(path: "huggingface", directoryHint: .isDirectory)
    }

    public static var whisperLegacyBase: URL {
        URL.documentsDirectory.appending(path: "huggingface", directoryHint: .isDirectory)
    }

    public static var mlxDownloadBase: URL {
        URL.documentsDirectory.appending(path: "huggingface", directoryHint: .isDirectory)
    }

    public static var mlxModelsRoot: URL {
        mlxDownloadBase.appending(path: "models", directoryHint: .isDirectory)
    }

    static func whisperFolder(base: URL, modelID: String) -> URL {
        base.appending(path: "models/argmaxinc/whisperkit-coreml", directoryHint: .isDirectory)
            .appending(path: modelID, directoryHint: .isDirectory)
    }

    static func resolveWhisperFolder(
        modelID: String,
        canonicalBase: URL,
        legacyBase: URL
    ) -> URL? {
        [canonicalBase, legacyBase]
            .map { whisperFolder(base: $0, modelID: modelID) }
            .first { folder in
                FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent("AudioEncoder.mlmodelc").path)
            }
    }

    public static func resolvedWhisperFolder(modelID: String) -> URL? {
        resolveWhisperFolder(
            modelID: modelID,
            canonicalBase: whisperCanonicalBase,
            legacyBase: whisperLegacyBase)
    }

    public static func isWhisperReady(modelID: String) -> Bool {
        resolvedWhisperFolder(modelID: modelID) != nil
    }

    public static func mlxFolder(modelID: String) -> URL {
        mlxFolder(modelID: modelID, modelsRoot: mlxModelsRoot)
    }

    static func mlxFolder(modelID: String, modelsRoot: URL) -> URL {
        modelsRoot.appending(path: modelID, directoryHint: .isDirectory)
    }

    public static func isMLXReady(modelID: String) -> Bool {
        isMLXReady(modelID: modelID, modelsRoot: mlxModelsRoot)
    }

    static func isMLXReady(modelID: String, modelsRoot: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: mlxFolder(modelID: modelID, modelsRoot: modelsRoot)
                .appendingPathComponent("config.json").path)
    }
}
