import Foundation
import SaidDoneCore

/// Where on-device models live, which are complete, and how they get there. Everything sits under Application
/// Support: a model under ~/Documents would trigger the Documents privacy prompt on every load.
public struct ModelFiles: Sendable {
    /// Hugging Face snapshot layout: `<root>/models/<repo id>/…`.
    public let root: URL

    public init(root: URL) { self.root = root }

    public static let standard = ModelFiles(
        root: URL.applicationSupportDirectory.appending(path: "SaidDone/Models", directoryHint: .isDirectory))

    /// Every large-v3 variant uses this tokenizer.
    static let whisperTokenizer = "openai/whisper-large-v3"

    public func isInstalled(_ model: LocalModel) -> Bool {
        FileManager.default.fileExists(atPath: marker(model).path)
    }

    public func installed() -> Set<LocalModel> { Set(LocalModel.all.filter(isInstalled)) }

    /// Idempotent: finished files are not downloaded again. A model counts as installed only once every file is in.
    public func download(_ model: LocalModel, mirror: Bool,
                         progress: @escaping @Sendable (Double) -> Void) async throws(DownloadError) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage ?? .max
            if free < model.approximateBytes + 500_000_000 { throw DownloadError.notEnoughSpace(needed: model.approximateBytes) }

            let endpoint = mirror ? "https://hf-mirror.com" : "https://huggingface.co"
            switch model {
            case let .whisper(whisper):
                try await WhisperKitTranscriber.download(whisper, into: self, endpoint: endpoint, progress: progress)
            case let .qwen(qwen):
                try await MLXChatModel.download(qwen, into: self, endpoint: endpoint, progress: progress)
            }
            try Task.checkCancellation()
            try Data().write(to: marker(model))
            progress(1)
        } catch let error as DownloadError {
            throw error
        } catch is CancellationError {
            throw .cancelled
        } catch let error as URLError {
            throw error.code == .cancelled ? .cancelled : .offline
        } catch {
            throw Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
        }
    }

    public func remove(_ model: LocalModel) throws {
        let folder = folder(model)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    func folder(_ model: LocalModel) -> URL {
        switch model {
        case let .whisper(whisper):
            root.appending(path: "models/argmaxinc/whisperkit-coreml/\(whisper.rawValue)", directoryHint: .isDirectory)
        case let .qwen(qwen):
            root.appending(path: "models/\(qwen.rawValue)", directoryHint: .isDirectory)
        }
    }

    private func marker(_ model: LocalModel) -> URL { folder(model).appending(path: ".saiddone-complete") }
}

public enum DownloadError: Error, Equatable, Sendable {
    case offline
    case notEnoughSpace(needed: Int64)
    case cancelled
    case failed(String)
}
