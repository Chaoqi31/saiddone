import Foundation
import Testing
@testable import SaidDoneCore

struct HistoryTests {
    @Test func appendAndRecentNewestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1000)
        store.append(.init(date: t0, mode: "dictation", raw: "a", text: "A"))
        store.append(.init(date: t0.addingTimeInterval(1), mode: "translation", raw: "b", text: "B"))

        let recent = store.recent()
        #expect(recent.count == 2)
        #expect(recent.first?.text == "B")   // newest first
        #expect(recent.last?.text == "A")
    }

    @Test func recentLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(directory: dir)
        for i in 0..<5 { store.append(.init(date: Date(timeIntervalSince1970: Double(i)), mode: "dictation", raw: "\(i)", text: "\(i)")) }
        #expect((store.recent(2).map(\.text)) == (["4", "3"]))
    }

    @Test func empty() {
        let store = HistoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(store.recent() == [])
    }

    @Test func appendReportsFailureWhenHistoryPathIsDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(directory: dir)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)

        #expect(!(store.append(.init(
            date: Date(), mode: "dictation", raw: "raw", text: "text"))))
    }

    @Test func updateReportsRewriteFailure() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)

        #expect(!(store.update(.init(
            date: Date(), mode: "dictation", raw: "raw", text: "edited"))))
    }

    @Test func clearRemovesAudioFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(directory: dir)
        try FileManager.default.createDirectory(at: store.audioDirectory, withIntermediateDirectories: true)
        let audioURL = store.audioURL("sample.wav")
        try Data([1, 2, 3]).write(to: audioURL)
        store.append(.init(date: Date(), mode: "dictation", raw: "raw", text: "text", audioFile: "sample.wav"))

        store.clear()

        #expect(!(FileManager.default.fileExists(atPath: audioURL.path)))
        #expect(!(FileManager.default.fileExists(atPath: store.url.path)))
    }

    @Test func repositoryOwnsEntryAndAudioLifecycle() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = HistoryRepository(directory: dir)
        let entry = HistoryEntry(
            date: Date(), mode: "dictation", raw: "raw", text: "text")

        guard let saved = await repository.append(
            entry, audio: AudioSamples(samples: [0.1, 0.2])) else {
            Issue.record("Expected history entry to persist"); return
        }

        #expect(saved.audioFile != nil)
        let savedAudioURL = repository.audioURL(saved)
        #expect(savedAudioURL != nil)
        #expect(FileManager.default.fileExists(atPath: savedAudioURL!.path))
        let recent = await repository.recent()
        #expect((recent.map(\.id)) == [saved.id])

        await repository.remove(id: saved.id)
        #expect(!(FileManager.default.fileExists(atPath: savedAudioURL!.path)))
        let afterRemove = await repository.recent()
        #expect(afterRemove.isEmpty)
    }

    @Test func repositoryClearRemovesEveryAudioFile() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = HistoryRepository(directory: dir)
        guard let first = await repository.append(
            HistoryEntry(date: Date(), mode: "dictation", raw: "a", text: "A"),
            audio: AudioSamples(samples: [0.1])) else {
            Issue.record("Expected first history entry to persist"); return
        }
        guard let second = await repository.append(
            HistoryEntry(date: Date(), mode: "translation", raw: "b", text: "B"),
            audio: AudioSamples(samples: [0.2])) else {
            Issue.record("Expected second history entry to persist"); return
        }
        let firstAudioURL = repository.audioURL(first)
        let secondAudioURL = repository.audioURL(second)

        await repository.clear()

        #expect(firstAudioURL != nil)
        #expect(secondAudioURL != nil)
        #expect(!(FileManager.default.fileExists(atPath: firstAudioURL!.path)))
        #expect(!(FileManager.default.fileExists(atPath: secondAudioURL!.path)))
        let recent = await repository.recent()
        #expect(recent.isEmpty)
    }

    @Test func repositoryRemovesAudioWhenEntryPersistenceFails() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = HistoryRepository(directory: dir)
        let historyURL = dir.appendingPathComponent("history.jsonl")
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)

        let saved = await repository.append(
            HistoryEntry(date: Date(), mode: "dictation", raw: "raw", text: "text"),
            audio: AudioSamples(samples: [0.1, 0.2]))

        #expect(saved == nil)
        let audioURL = dir.appendingPathComponent("audio", isDirectory: true)
        let audioFiles = (try? FileManager.default.contentsOfDirectory(atPath: audioURL.path)) ?? []
        #expect(audioFiles.isEmpty)
    }

    @Test func repositoryKeepsAudioWhenEntryRemovalFails() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = HistoryRepository(directory: dir)
        guard let saved = await repository.append(
            HistoryEntry(date: Date(), mode: "dictation", raw: "raw", text: "text"),
            audio: AudioSamples(samples: [0.1, 0.2])),
              let audioURL = repository.audioURL(saved) else {
            Issue.record("Expected history entry and audio to persist"); return
        }
        let historyURL = dir.appendingPathComponent("history.jsonl")
        try FileManager.default.removeItem(at: historyURL)
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)

        let removed = await repository.remove(id: saved.id)

        #expect(!removed)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
    }
}
