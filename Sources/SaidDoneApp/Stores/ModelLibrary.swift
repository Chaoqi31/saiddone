import AppKit
import Foundation
import Observation
import SaidDoneCore
import SaidDoneEngines

/// On-device models: which are installed, which are downloading. Onboarding and Settings share one instance, so a
/// download started in one shows in the other and never runs twice.
@MainActor @Observable
final class ModelLibrary {
    private(set) var installed: Set<LocalModel>
    private(set) var progress: [LocalModel: Double] = [:]
    private(set) var failures: [LocalModel: DownloadError] = [:]

    @ObservationIgnored let files: ModelFiles
    @ObservationIgnored private var downloads: [LocalModel: Task<Void, Never>] = [:]

    init(files: ModelFiles) {
        self.files = files
        installed = files.installed()
    }

    func isDownloading(_ model: LocalModel) -> Bool { downloads[model] != nil }

    func download(_ model: LocalModel, mirror: Bool) {
        guard downloads[model] == nil, !installed.contains(model) else { return }
        failures[model] = nil
        progress[model] = 0
        let files = files
        downloads[model] = Task {
            do throws(DownloadError) {
                try await files.download(model, mirror: mirror) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.progress[model] != nil else { return }
                        self.progress[model] = max(self.progress[model] ?? 0, fraction)
                    }
                }
                installed.insert(model)
            } catch {
                if error != .cancelled { failures[model] = error }
            }
            progress[model] = nil
            downloads[model] = nil
        }
    }

    func cancel(_ model: LocalModel) { downloads[model]?.cancel() }

    func remove(_ model: LocalModel) {
        cancel(model)
        try? files.remove(model)
        installed.remove(model)
    }

    func reveal() {
        try? FileManager.default.createDirectory(at: files.root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([files.root])
    }
}
