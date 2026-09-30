import Foundation
import SaidDoneCore
import SaidDoneEngines

/// The durable job log: each recording's row and audio are written before any engine runs, so speech that reached
/// processing survives failures, quits and crashes. Lifetime usage is stored apart, so pruning never resets it.
///
/// Files: `history.sqlite` (rows) and `audio/<id>.m4a`. Audio is written before its row and deleted after it, so a
/// crash in between leaves at most an orphan file, which `recover` sweeps.
actor HistoryStore {
    /// Fires after every change. One consumer: the History view model.
    nonisolated let changes: AsyncStream<Void>
    private let notify: AsyncStream<Void>.Continuation
    private let database: Database?
    private let audio: URL

    init(folder: URL) {
        (changes, notify) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        audio = folder.appending(path: "audio", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        database = Self.open(folder.appending(path: "history.sqlite"))
    }

    nonisolated func audioURL(_ id: JobID) -> URL { audio.appending(path: "\(id.uuidString).m4a") }

    // MARK: - Job log

    func open(_ entry: HistoryEntry, audio samples: AudioSamples) {
        var entry = entry
        entry.hasAudio = (try? AudioCodec.write(samples, to: audioURL(entry.id))) != nil
        save(entry)
    }

    /// Records how a job ended. A missing row (History was cleared mid-job) stays missing.
    func close(_ id: JobID, transcript: String?, outcome: Outcome, retention: Retention, now: Date = .now) {
        guard var entry = entry(id) else { return }
        if let transcript { entry.transcript = transcript }
        entry.outcome = outcome
        if let expiry = retention.expiry(of: entry), expiry <= now {
            delete([id])
        } else {
            save(entry)
        }
    }

    func discard(_ id: JobID) { delete([id]) }

    /// Retry: marks the entry pending again and returns it with its audio, or nil when the audio is gone.
    func reopen(_ id: JobID) -> (entry: HistoryEntry, audio: AudioSamples)? {
        guard var entry = entry(id), entry.hasAudio, let samples = try? AudioCodec.read(audioURL(id)) else { return nil }
        entry.outcome = .pending
        save(entry)
        return (entry, samples)
    }

    func recordUsage(_ transcript: String, spokenSeconds: Double) {
        var stats = usage()
        stats.record(transcript, spokenSeconds: spokenSeconds)
        guard let data = try? JSONEncoder().encode(stats) else { return }
        run("INSERT OR REPLACE INTO usage (id, json) VALUES (1, ?)", [.blob(data)])
        notify.yield()
    }

    // MARK: - Reading

    func page(_ query: HistoryQuery) -> [HistoryEntry] {
        var clauses: [String] = []
        var values: [Database.Value] = []
        if let mode = query.mode {
            clauses.append("mode = ?")
            values.append(.text(mode.rawValue))
        }
        let search = query.search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !search.isEmpty {
            clauses.append("search LIKE ? ESCAPE '\\'")
            let escaped = search.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            values.append(.text("%\(escaped)%"))
        }
        if let before = query.before {
            clauses.append("created < ?")
            values.append(.real(before.timeIntervalSinceReferenceDate))
        }
        let filter = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        values.append(.integer(Int64(query.limit)))
        return entries("SELECT json FROM entry \(filter) ORDER BY created DESC LIMIT ?", values)
    }

    func entry(_ id: JobID) -> HistoryEntry? {
        entries("SELECT json FROM entry WHERE id = ?", [.text(id.uuidString)]).first
    }

    func usage() -> UsageStats {
        let rows = (try? database?.rows("SELECT json FROM usage WHERE id = 1") { $0.blob(0) }) ?? []
        return rows.first.flatMap { try? JSONDecoder().decode(UsageStats.self, from: $0) } ?? UsageStats()
    }

    // MARK: - Deleting

    func delete(_ ids: [JobID]) {
        guard !ids.isEmpty else { return }
        for id in ids { run("DELETE FROM entry WHERE id = ?", [.text(id.uuidString)]) }
        for id in ids { try? FileManager.default.removeItem(at: audioURL(id)) }
        notify.yield()
    }

    /// Deletes every entry and recording. Lifetime usage stays.
    func deleteAll() {
        run("DELETE FROM entry")
        for file in audioFiles() { try? FileManager.default.removeItem(at: file) }
        notify.yield()
    }

    func prune(_ retention: Retention, now: Date = .now) {
        guard retention != .forever else { return }
        let expired = entries("SELECT json FROM entry").filter { entry in
            retention.expiry(of: entry).map { $0 <= now } ?? false
        }
        delete(expired.map(\.id))
    }

    /// At launch: jobs still pending were interrupted by a quit or crash. They are marked failed rather than rerun,
    /// because the text field they were meant for is gone. Then orphan recordings are swept and old entries pruned.
    func recover(retention: Retention, now: Date = .now) {
        for var entry in entries("SELECT json FROM entry WHERE status = 'pending'") {
            entry.outcome = .failed(.interrupted)
            save(entry)
        }
        let known = Set(entries("SELECT json FROM entry").map { $0.id.uuidString })
        for file in audioFiles() where !known.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
        prune(retention, now: now)
        notify.yield()
    }

    // MARK: - Storage

    private func save(_ entry: HistoryEntry) {
        guard let json = try? JSONEncoder().encode(entry) else { return }
        let searchable = [entry.transcript ?? "", entry.outcome.text ?? ""].joined(separator: "\n").lowercased()
        run("""
            INSERT OR REPLACE INTO entry (id, created, mode, status, search, json) VALUES (?, ?, ?, ?, ?, ?)
            """,
            [.text(entry.id.uuidString), .real(entry.created.timeIntervalSinceReferenceDate), .text(entry.mode.rawValue),
             .text(entry.outcome.status), .text(searchable), .blob(json)])
        notify.yield()
    }

    private func entries(_ sql: String, _ values: [Database.Value] = []) -> [HistoryEntry] {
        (try? database?.rows(sql, values) { try? JSONDecoder().decode(HistoryEntry.self, from: $0.blob(0)) }) ?? []
    }

    private func run(_ sql: String, _ values: [Database.Value] = []) {
        do {
            try database?.execute(sql, values)
        } catch {
            log.error("history: \(String(describing: error), privacy: .public)")
        }
    }

    private func audioFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil)) ?? []
    }

    /// A database that can't be opened is set aside (never deleted) and a fresh one started, so dictation keeps
    /// working and the old file stays available for recovery by hand.
    private static func open(_ url: URL) -> Database? {
        for attempt in 0..<2 {
            do {
                let database = try Database(url: url)
                try database.execute("""
                    CREATE TABLE IF NOT EXISTS entry (
                        id TEXT PRIMARY KEY, created REAL NOT NULL, mode TEXT NOT NULL, status TEXT NOT NULL,
                        search TEXT NOT NULL, json BLOB NOT NULL)
                    """)
                try database.execute("CREATE INDEX IF NOT EXISTS entry_created ON entry (created DESC)")
                try database.execute("CREATE TABLE IF NOT EXISTS usage (id INTEGER PRIMARY KEY CHECK (id = 1), json BLOB NOT NULL)")
                return database
            } catch {
                log.error("history: open failed: \(String(describing: error), privacy: .public)")
                guard attempt == 0 else { break }
                let aside = url.deletingLastPathComponent()
                    .appending(path: "history-\(Int(Date().timeIntervalSince1970)).unreadable.sqlite")
                try? FileManager.default.moveItem(at: url, to: aside)
            }
        }
        return nil
    }
}

struct HistoryQuery: Equatable, Sendable {
    /// nil = every mode.
    var mode: Mode?
    /// Matches transcripts and delivered text, over all history.
    var search = ""
    /// Paging cursor: entries created before this date.
    var before: Date?
    var limit = 100
}

private extension Outcome {
    var status: String {
        switch self {
        case .pending: "pending"
        case .delivered: "delivered"
        case .nothingSaid: "nothing"
        case .failed: "failed"
        }
    }
}
