import Foundation

/// One saved dictation (kept on device so the user can recover text that didn't land,
/// e.g. when no text field was focused). Stored as JSON Lines for cheap appends.
public struct HistoryEntry: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var date: Date
    public var mode: String       // "dictation" | "translation"
    public var raw: String        // ASR output
    public var text: String       // final inserted text
    public var audioFile: String? // saved WAV filename in the history audio dir (nil = not saved)

    public var elapsed: Double?
    /// True when the final text equals the post-ASR draft (polish skipped or timed out).
    public var polishSkipped: Bool?

    public init(id: UUID = UUID(), date: Date, mode: String, raw: String, text: String,
                audioFile: String? = nil, elapsed: Double? = nil, polishSkipped: Bool? = nil) {
        self.id = id
        self.date = date
        self.mode = mode
        self.raw = raw
        self.text = text
        self.audioFile = audioFile
        self.elapsed = elapsed
        self.polishSkipped = polishSkipped
    }

    enum CodingKeys: String, CodingKey {
        case id, date, mode, raw, text, audioFile, elapsed, polishSkipped
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        mode = try c.decode(String.self, forKey: .mode)
        raw = try c.decode(String.self, forKey: .raw)
        text = try c.decode(String.self, forKey: .text)
        audioFile = try c.decodeIfPresent(String.self, forKey: .audioFile)
        elapsed = try c.decodeIfPresent(Double.self, forKey: .elapsed)
        polishSkipped = try c.decodeIfPresent(Bool.self, forKey: .polishSkipped)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(date, forKey: .date)
        try c.encode(mode, forKey: .mode)
        try c.encode(raw, forKey: .raw)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(audioFile, forKey: .audioFile)
        try c.encodeIfPresent(elapsed, forKey: .elapsed)
        try c.encodeIfPresent(polishSkipped, forKey: .polishSkipped)
    }
}

/// Append-only history at ~/Library/Application Support/SaidDone/history.jsonl.
public struct HistoryStore: Sendable {
    public let url: URL
    public let directory: URL
    public init(directory: URL) {
        self.directory = directory
        self.url = directory.appendingPathComponent("history.jsonl")
    }

    /// Directory holding saved per-entry WAV files.
    public var audioDirectory: URL { directory.appendingPathComponent("audio", isDirectory: true) }
    public func audioURL(_ filename: String) -> URL { audioDirectory.appendingPathComponent(filename) }

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

    public func clear() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: audioDirectory)
    }

    /// Replace one entry (rewrites the file).
    public func update(_ entry: HistoryEntry) {
        let all = recent(Int.max).reversed().map { $0.id == entry.id ? entry : $0 }
        var data = Data()
        for e in all { if let d = try? Self.encoder.encode(e) { data.append(d); data.append(0x0A) } }
        try? data.write(to: url)
    }

    /// Remove one entry by id (rewrites the file).
    public func remove(id: UUID) {
        let kept = recent(Int.max).reversed().filter { $0.id != id }   // back to chronological
        let lines = kept.compactMap { try? Self.encoder.encode($0) }
        var data = Data()
        for line in lines { data.append(line); data.append(0x0A) }
        try? data.write(to: url)
    }
}
