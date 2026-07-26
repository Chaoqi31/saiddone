import XCTest
@testable import SaidDoneApp
import SaidDoneCore

final class HistoryModelTests: XCTestCase {
    @MainActor
    func testClearWinsOverPendingPersistence() async throws {
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

        XCTAssertTrue(model.entries.isEmpty)
        let persisted = await repository.recent()
        XCTAssertTrue(persisted.isEmpty)
    }
}
