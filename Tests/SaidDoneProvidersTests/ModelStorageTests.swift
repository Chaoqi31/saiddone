import Foundation
import Testing
@testable import SaidDoneProviders

struct ModelStorageTests {
    @Test func whisperResolutionPrefersCanonicalThenFallsBackToLegacy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = root.appendingPathComponent("canonical")
        let legacy = root.appendingPathComponent("legacy")
        let model = "whisper-test"

        let legacyFolder = ModelStorage.whisperFolder(base: legacy, modelID: model)
        try FileManager.default.createDirectory(
            at: legacyFolder.appendingPathComponent("AudioEncoder.mlmodelc"),
            withIntermediateDirectories: true)
        #expect((ModelStorage.resolveWhisperFolder(
                modelID: model, canonicalBase: canonical, legacyBase: legacy)) == legacyFolder)

        let canonicalFolder = ModelStorage.whisperFolder(base: canonical, modelID: model)
        try FileManager.default.createDirectory(
            at: canonicalFolder.appendingPathComponent("AudioEncoder.mlmodelc"),
            withIntermediateDirectories: true)
        #expect((ModelStorage.resolveWhisperFolder(
                modelID: model, canonicalBase: canonical, legacyBase: legacy)) == canonicalFolder)
    }

    @Test func whisperReadinessIsExactForSelectedModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = ModelStorage.whisperFolder(base: root, modelID: "installed")
        try FileManager.default.createDirectory(
            at: installed.appendingPathComponent("AudioEncoder.mlmodelc"),
            withIntermediateDirectories: true)

        #expect((ModelStorage.resolveWhisperFolder(
            modelID: "selected", canonicalBase: root,
            legacyBase: root.appendingPathComponent("legacy"))) == nil)
    }

    @Test func mLXReadinessRequiresConfigFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("mlx-community/Qwen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(!(ModelStorage.isMLXReady(modelID: "mlx-community/Qwen", modelsRoot: root)))

        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        #expect(ModelStorage.isMLXReady(modelID: "mlx-community/Qwen", modelsRoot: root))
    }
}
