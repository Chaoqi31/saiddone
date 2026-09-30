import Foundation
import Observation
import SaidDoneCore

/// The only in-memory copy of the user's preferences. Views bind to `prefs` directly; every change is saved.
@MainActor @Observable
final class SettingsStore {
    var prefs: Preferences {
        didSet { if prefs != oldValue { save() } }
    }

    @ObservationIgnored private let url: URL?

    /// `url` nil keeps everything in memory (tests, previews).
    init(url: URL?) {
        self.url = url
        prefs = url.flatMap { try? Data(contentsOf: $0) }.map(Preferences.decode) ?? Preferences()
    }

    private func save() {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        (try? encoder.encode(prefs))?.writeAtomically(to: url)
    }
}

/// The personal dictionary, saved on every change.
@MainActor @Observable
final class DictionaryStore {
    var lexicon: Lexicon {
        didSet { if lexicon != oldValue { save() } }
    }

    @ObservationIgnored private let url: URL?

    init(url: URL?) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        lexicon = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? decoder.decode(Lexicon.self, from: $0) }
            ?? Lexicon()
    }

    private func save() {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        (try? encoder.encode(lexicon))?.writeAtomically(to: url)
    }
}
