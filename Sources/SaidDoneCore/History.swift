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

    @discardableResult
    public func append(_ entry: HistoryEntry) -> Bool {
        guard let data = try? Self.encoder.encode(entry) else { return false }
        var line = data
        line.append(0x0A) // newline
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
            return true
        } catch {
            return false
        }
    }

    /// Newest-first, capped at `limit`.
    public func recent(_ limit: Int = 200) -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        let content: Data
        if limit == Int.max {
            guard let all = try? Data(contentsOf: url) else { return [] }
            content = all
        } else {
            guard let tail = Self.tailData(from: url, lineLimit: limit) else { return [] }
            content = tail
        }
        let decoded = content.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { try? Self.decoder.decode(HistoryEntry.self, from: Data($0)) }
        return Array(decoded.suffix(limit).reversed())
    }

    /// Read only enough of the JSONL tail to satisfy `lineLimit`.
    private static func tailData(from url: URL, lineLimit: Int, chunkSize: Int = 64 * 1024) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        var position = end
        var newlineCount = 0
        var chunks: [Data] = []
        var totalBytes = 0

        while position > 0, newlineCount <= lineLimit {
            let count = min(UInt64(chunkSize), position)
            let chunkStart = position - count
            do {
                try handle.seek(toOffset: chunkStart)
                var chunk = Data()
                while chunk.count < Int(count) {
                    let remaining = Int(count) - chunk.count
                    guard let part = try handle.read(upToCount: remaining), !part.isEmpty else {
                        return nil
                    }
                    chunk.append(part)
                }
                newlineCount += chunk.reduce(into: 0) { count, byte in
                    if byte == 0x0A { count += 1 }
                }
                totalBytes += chunk.count
                chunks.append(chunk)
                position = chunkStart
            } catch {
                return nil
            }
        }

        var data = Data(capacity: totalBytes)
        for chunk in chunks.reversed() { data.append(chunk) }
        return data
    }

    @discardableResult
    public func clear() -> Bool {
        var succeeded = true
        for target in [url, audioDirectory]
        where FileManager.default.fileExists(atPath: target.path) {
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }

    /// Replace one entry (rewrites the file).
    @discardableResult
    public func update(_ entry: HistoryEntry) -> Bool {
        let all = recent(Int.max).reversed().map { $0.id == entry.id ? entry : $0 }
        return rewrite(all)
    }

    /// Remove one entry by id (rewrites the file).
    @discardableResult
    public func remove(id: UUID) -> Bool {
        let kept = recent(Int.max).reversed().filter { $0.id != id }   // back to chronological
        return rewrite(kept)
    }

    private func rewrite<S: Sequence>(_ entries: S) -> Bool where S.Element == HistoryEntry {
        var data = Data()
        do {
            for entry in entries {
                data.append(try Self.encoder.encode(entry))
                data.append(0x0A)
            }
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// Serializes History entry/audio persistence away from the MainActor and keeps their lifecycle
/// in one module.
public actor HistoryRepository {
    public nonisolated let directory: URL
    private let store: HistoryStore

    public init(directory: URL) {
        self.directory = directory
        self.store = HistoryStore(directory: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public nonisolated func audioURL(_ entry: HistoryEntry) -> URL? {
        guard let filename = entry.audioFile else { return nil }
        return directory.appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent(filename)
    }

    @discardableResult
    public func append(_ entry: HistoryEntry, audio: AudioSamples?) -> HistoryEntry? {
        var saved = entry
        var savedAudioURL: URL?
        if let audio, !audio.samples.isEmpty {
            let filename = "\(entry.id).wav"
            let audioDirectory = store.audioDirectory
            try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            let url = store.audioURL(filename)
            if (try? audio.wavData().write(to: url, options: .atomic)) != nil {
                saved.audioFile = filename
                savedAudioURL = url
            }
        }
        guard store.append(saved) else {
            if let savedAudioURL { try? FileManager.default.removeItem(at: savedAudioURL) }
            return nil
        }
        return saved
    }

    public func recent(_ limit: Int = 200) -> [HistoryEntry] {
        store.recent(limit)
    }

    @discardableResult
    public func update(_ entry: HistoryEntry) -> Bool {
        store.update(entry)
    }

    @discardableResult
    public func remove(id: UUID) -> Bool {
        let audio = store.recent(Int.max).first(where: { $0.id == id }).flatMap(audioURL)
        guard store.remove(id: id) else { return false }
        if let audio, FileManager.default.fileExists(atPath: audio.path) {
            do {
                try FileManager.default.removeItem(at: audio)
            } catch {
                return false
            }
        }
        return true
    }

    @discardableResult
    public func clear() -> Bool {
        store.clear()
    }
}
