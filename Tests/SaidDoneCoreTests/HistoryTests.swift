import XCTest
@testable import SaidDoneCore

final class HistoryTests: XCTestCase {
    func testAppendAndRecentNewestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1000)
        store.append(.init(date: t0, mode: "dictation", raw: "a", text: "A"))
        store.append(.init(date: t0.addingTimeInterval(1), mode: "translation", raw: "b", text: "B"))

        let recent = store.recent()
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent.first?.text, "B")   // newest first
        XCTAssertEqual(recent.last?.text, "A")
    }

    func testRecentLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(directory: dir)
        for i in 0..<5 { store.append(.init(date: Date(timeIntervalSince1970: Double(i)), mode: "dictation", raw: "\(i)", text: "\(i)")) }
        XCTAssertEqual(store.recent(2).map(\.text), ["4", "3"])
    }

    func testEmpty() {
        let store = HistoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertEqual(store.recent(), [])
    }

    func testAppendReportsFailureWhenHistoryPathIsDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(directory: dir)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)

        XCTAssertFalse(store.append(.init(
            date: Date(), mode: "dictation", raw: "raw", text: "text")))
    }

    func testUpdateReportsRewriteFailure() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)

        XCTAssertFalse(store.update(.init(
            date: Date(), mode: "dictation", raw: "raw", text: "edited")))
    }

    func testClearRemovesAudioFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(directory: dir)
        try FileManager.default.createDirectory(at: store.audioDirectory, withIntermediateDirectories: true)
        let audioURL = store.audioURL("sample.wav")
        try Data([1, 2, 3]).write(to: audioURL)
        store.append(.init(date: Date(), mode: "dictation", raw: "raw", text: "text", audioFile: "sample.wav"))

        store.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testRepositoryOwnsEntryAndAudioLifecycle() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = HistoryRepository(directory: dir)
        let entry = HistoryEntry(
            date: Date(), mode: "dictation", raw: "raw", text: "text")

        guard let saved = await repository.append(
            entry, audio: AudioSamples(samples: [0.1, 0.2])) else {
            return XCTFail("Expected history entry to persist")
        }

        XCTAssertNotNil(saved.audioFile)
        let savedAudioURL = repository.audioURL(saved)
        XCTAssertNotNil(savedAudioURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedAudioURL!.path))
        let recent = await repository.recent()
        XCTAssertEqual(recent.map(\.id), [saved.id])

        await repository.remove(id: saved.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedAudioURL!.path))
        let afterRemove = await repository.recent()
        XCTAssertTrue(afterRemove.isEmpty)
    }

    func testRepositoryClearRemovesEveryAudioFile() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = HistoryRepository(directory: dir)
        guard let first = await repository.append(
            HistoryEntry(date: Date(), mode: "dictation", raw: "a", text: "A"),
            audio: AudioSamples(samples: [0.1])) else {
            return XCTFail("Expected first history entry to persist")
        }
        guard let second = await repository.append(
            HistoryEntry(date: Date(), mode: "translation", raw: "b", text: "B"),
            audio: AudioSamples(samples: [0.2])) else {
            return XCTFail("Expected second history entry to persist")
        }
        let firstAudioURL = repository.audioURL(first)
        let secondAudioURL = repository.audioURL(second)

        await repository.clear()

        XCTAssertNotNil(firstAudioURL)
        XCTAssertNotNil(secondAudioURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstAudioURL!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondAudioURL!.path))
        let recent = await repository.recent()
        XCTAssertTrue(recent.isEmpty)
    }

    func testRepositoryRemovesAudioWhenEntryPersistenceFails() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = HistoryRepository(directory: dir)
        let historyURL = dir.appendingPathComponent("history.jsonl")
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)

        let saved = await repository.append(
            HistoryEntry(date: Date(), mode: "dictation", raw: "raw", text: "text"),
            audio: AudioSamples(samples: [0.1, 0.2]))

        XCTAssertNil(saved)
        let audioURL = dir.appendingPathComponent("audio", isDirectory: true)
        let audioFiles = (try? FileManager.default.contentsOfDirectory(atPath: audioURL.path)) ?? []
        XCTAssertTrue(audioFiles.isEmpty)
    }

    func testRepositoryKeepsAudioWhenEntryRemovalFails() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = HistoryRepository(directory: dir)
        guard let saved = await repository.append(
            HistoryEntry(date: Date(), mode: "dictation", raw: "raw", text: "text"),
            audio: AudioSamples(samples: [0.1, 0.2])),
              let audioURL = repository.audioURL(saved) else {
            return XCTFail("Expected history entry and audio to persist")
        }
        let historyURL = dir.appendingPathComponent("history.jsonl")
        try FileManager.default.removeItem(at: historyURL)
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)

        let removed = await repository.remove(id: saved.id)

        XCTAssertFalse(removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }
}
