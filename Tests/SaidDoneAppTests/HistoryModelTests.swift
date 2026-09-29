import Foundation
import Testing
@testable import SaidDoneApp
import SaidDoneCore

@MainActor
struct HistoryModelTests {
    @Test @MainActor
    func clearWinsOverPendingPersistence() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = HistoryRepository(directory: dir)
        let model = HistoryModel(repository: repository)
        let entry = HistoryEntry(
            date: Date(), mode: "dictation", raw: "raw", text: "text")
        let audio = AudioSamples(samples: [Float](repeating: 0.1, count: 160_000))

        model.persist(entry, audio: audio)
        model.clear()
        try await Task.sleep(for: .milliseconds(300))

        #expect(model.entries.isEmpty)
        let persisted = await repository.recent()
        #expect(persisted.isEmpty)
    }
}
