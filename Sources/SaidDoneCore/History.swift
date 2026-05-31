import Foundation

/// One saved dictation (kept on device so the user can recover text that didn't land,
/// e.g. when no text field was focused). Stored as JSON Lines for cheap appends.
public struct HistoryEntry: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var date: Date
    public var mode: String       // "dictation" | "translation"
    public var raw: String        // ASR output
    public var text: String       // final inserted text

    public init(id: UUID = UUID(), date: Date, mode: String, raw: String, text: String) {
        self.id = id
        self.date = date
        self.mode = mode
        self.raw = raw
        self.text = text
    }
}

/// Append-only history at ~/Library/Application Support/SaidDone/history.jsonl.
public struct HistoryStore: Sendable {
    public let url: URL
    public init(directory: URL) { self.url = directory.appendingPathComponent("history.jsonl") }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public func append(_ entry: HistoryEntry) {
        guard let data = try? Self.encoder.encode(entry) else { return }
        var line = data
        line.append(0x0A) // newline
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
        } else {
            try? line.write(to: url)
        }
    }

    /// Newest-first, capped at `limit`.
    public func recent(_ limit: Int = 200) -> [HistoryEntry] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let entries = content.split(separator: "\n").compactMap { line -> HistoryEntry? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? Self.decoder.decode(HistoryEntry.self, from: data)
        }
        return Array(entries.reversed().prefix(limit))
    }

    public func clear() { try? FileManager.default.removeItem(at: url) }

    /// Remove one entry by id (rewrites the file).
    public func remove(id: UUID) {
        let kept = recent(Int.max).reversed().filter { $0.id != id }   // back to chronological
        let lines = kept.compactMap { try? Self.encoder.encode($0) }
        var data = Data()
        for line in lines { data.append(line); data.append(0x0A) }
        try? data.write(to: url)
    }
}
