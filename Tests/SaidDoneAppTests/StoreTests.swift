import Foundation
import SaidDoneCore
import Testing
@testable import SaidDoneApp

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "SaidDoneAppTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func speech(seconds: Double = 1) -> AudioSamples {
    AudioSamples(samples: (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.05) * 0.4) })
}

private func entry(_ created: Date = .now, request: Request = .dictate) -> HistoryEntry {
    HistoryEntry(id: UUID(), created: created, request: request, app: "com.apple.TextEdit", audioSeconds: 1,
                 hasAudio: false)
}

struct HistoryStoreTests {
    @Test func aJobIsDurableBeforeItRunsAndClosesWithItsOutcome() async throws {
        let store = HistoryStore(folder: try temporaryDirectory())
        let job = entry()
        await store.open(job, audio: speech())
        let pending = try #require(await store.entry(job.id))
        #expect(pending.outcome == .pending)
        #expect(pending.hasAudio)
        #expect(FileManager.default.fileExists(atPath: store.audioURL(job.id).path))

        await store.close(job.id, transcript: "hello", outcome: .delivered("Hello.", .inserted), retention: .forever)
        let closed = try #require(await store.entry(job.id))
        #expect(closed.transcript == "hello")
        #expect(closed.outcome == .delivered("Hello.", .inserted))
    }

    @Test func retryReopensWithTheRecording() async throws {
        let store = HistoryStore(folder: try temporaryDirectory())
        let job = entry()
        await store.open(job, audio: speech(seconds: 2))
        await store.close(job.id, transcript: nil, outcome: .failed(.offline), retention: .forever)
        let (reopened, audio) = try #require(await store.reopen(job.id))
        #expect(reopened.outcome == .pending)
        #expect(abs(audio.duration - 2) < 0.1)
    }

    @Test func launchMarksInterruptedJobsAndSweepsOrphanRecordings() async throws {
        let folder = try temporaryDirectory()
        let store = HistoryStore(folder: folder)
        let job = entry()
        await store.open(job, audio: speech())
        let orphan = store.audioURL(UUID())
        try Data("x".utf8).write(to: orphan)

        let relaunched = HistoryStore(folder: folder)
        await relaunched.recover(retention: .forever)
        #expect(await relaunched.entry(job.id)?.outcome == .failed(.interrupted))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: relaunched.audioURL(job.id).path))
    }

    @Test func retentionDeletesOldFinishedEntriesButKeepsFailuresADay() async throws {
        let store = HistoryStore(folder: try temporaryDirectory())
        let now = Date.now
        let old = entry(now.addingTimeInterval(-2 * 86_400))
        let failed = entry(now.addingTimeInterval(-3_600))
        await store.open(old, audio: speech())
        await store.close(old.id, transcript: "a", outcome: .delivered("A", .inserted), retention: .forever)
        await store.open(failed, audio: speech())
        await store.close(failed.id, transcript: nil, outcome: .failed(.timeout), retention: .never, now: now)

        await store.prune(.day, now: now)
        #expect(await store.entry(old.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(old.id).path))
        #expect(await store.entry(failed.id) != nil)
    }

    @Test func searchFiltersAndPagesNewestFirst() async throws {
        let store = HistoryStore(folder: try temporaryDirectory())
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var ids: [JobID] = []
        for index in 0..<5 {
            let job = entry(start.addingTimeInterval(Double(index)), request: index == 4 ? .ask(selection: "") : .dictate)
            ids.append(job.id)
            await store.open(job, audio: speech(seconds: 0.2))
            await store.close(job.id, transcript: "note \(index) 100%_done", outcome: .delivered("Note \(index)", .inserted),
                              retention: .forever)
        }
        #expect(await store.page(HistoryQuery(limit: 2)).map(\.id) == [ids[4], ids[3]])
        #expect(await store.page(HistoryQuery(before: start.addingTimeInterval(3), limit: 2)).map(\.id) == [ids[2], ids[1]])
        #expect(await store.page(HistoryQuery(mode: .ask)).map(\.id) == [ids[4]])
        #expect(await store.page(HistoryQuery(search: "NOTE 2")).map(\.id) == [ids[2]])
        #expect(await store.page(HistoryQuery(search: "100%_")).count == 5)
        #expect(await store.page(HistoryQuery(search: "0%x")).isEmpty)
    }

    @Test func deletingEverythingKeepsLifetimeStats() async throws {
        let store = HistoryStore(folder: try temporaryDirectory())
        let job = entry()
        await store.open(job, audio: speech())
        await store.recordUsage("hello world", spokenSeconds: 3)
        await store.deleteAll()
        #expect(await store.page(HistoryQuery()).isEmpty)
        #expect(await store.usage() == UsageStats(words: 2, dictations: 1, spokenSeconds: 3))
    }

    @Test func anUnreadableDatabaseIsSetAsideNotDeleted() async throws {
        let folder = try temporaryDirectory()
        try Data("not a database".utf8).write(to: folder.appending(path: "history.sqlite"))
        let store = HistoryStore(folder: folder)
        let job = entry()
        await store.open(job, audio: speech())
        #expect(await store.entry(job.id) != nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.contains { $0.hasSuffix(".unreadable.sqlite") })
    }
}

@MainActor
struct SettingsStoreTests {
    @Test func changesAreSavedAndReloaded() throws {
        let url = try temporaryDirectory().appending(path: "settings.json")
        let store = SettingsStore(url: url)
        store.prefs.sounds = false
        store.prefs.shortcuts.bind(.fn, to: .ask)
        let reloaded = SettingsStore(url: url)
        #expect(reloaded.prefs.sounds == false)
        #expect(reloaded.prefs.shortcuts.mode(for: .fn) == .ask)
    }

    @Test func dictionaryIsSavedAndReloaded() throws {
        let url = try temporaryDirectory().appending(path: "dictionary.json")
        let store = DictionaryStore(url: url)
        store.lexicon.add("Vercel", misheard: ["Verso"], at: .now)
        #expect(DictionaryStore(url: url).lexicon.terms.map(\.text) == ["Vercel"])
    }

    @Test func keysAreTrimmedAndEmptyKeysRemoved() {
        let vault = Vault(item: nil)
        vault.setKey("  sk-1 \n", for: "deepseek")
        #expect(vault.key("deepseek") == "sk-1")
        #expect(vault.present == ["deepseek"])
        vault.setKey(" ", for: "deepseek")
        #expect(vault.present.isEmpty)
    }
}
