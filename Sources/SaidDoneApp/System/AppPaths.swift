import Foundation
import os
import SaidDoneEngines

/// Where SaidDone keeps its files: everything under ~/Library/Application Support/SaidDone.
struct AppPaths: Sendable {
    let root: URL

    static let standard = AppPaths(root: ModelFiles.standard.root.deletingLastPathComponent())

    var settings: URL { root.appending(path: "settings.json") }
    var dictionary: URL { root.appending(path: "dictionary.json") }
    var history: URL { root.appending(path: "History", directoryHint: .isDirectory) }
    var models: ModelFiles { ModelFiles(root: root.appending(path: "Models", directoryHint: .isDirectory)) }
}

/// Never logs dictated text or transcripts.
let log = Logger(subsystem: "com.saiddone.app", category: "app")

extension Data {
    /// Atomic, so a crash mid-write never leaves a torn file.
    func writeAtomically(to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(to: url, options: .atomic)
        } catch {
            log.error("write \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
