import ApplicationServices
import Foundation
import SaidDoneCore

/// Watches the field SaidDone just pasted into for 20 seconds. When the user fixes a word there ("Verso" → "Vercel"),
/// the correction is handed to the dictionary. Reads only that one field, only during the window, and stores only the
/// word pairs, never the field's contents.
@MainActor
final class CorrectionWatcher {
    private struct Watch {
        let element: AXUIElement
        let inserted: String
        let started: Date
        var prefix: String?
        var lastValue: String?
        var lastChange: Date
    }

    private let onLearned: ([Correction]) -> Void
    private var watch: Watch?
    private var timer: Timer?

    private static let window: TimeInterval = 20
    private static let settle: TimeInterval = 2

    init(onLearned: @escaping ([Correction]) -> Void) {
        self.onLearned = onLearned
    }

    /// Call right after pasting `text` into the focused field.
    func watch(inserted text: String) {
        stop()
        guard !text.isEmpty, let element = Inserter.focusedElement() else { return }
        watch = Watch(element: element, inserted: text, started: .now, lastChange: .now)
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        watch = nil
    }

    private func poll() {
        guard var watch else { return stop() }
        let now = Date.now
        guard now.timeIntervalSince(watch.started) <= Self.window else { return finish() }
        // The user moved to another field: learn from what they left, then stop reading.
        if let focused = Inserter.focusedElement(), !CFEqual(focused, watch.element) { return finish() }
        guard let value = Inserter.string(watch.element, kAXValueAttribute) else { return stop() }

        if let prefix = watch.prefix {
            if value == watch.lastValue {
                // Once the user pauses after editing, learn right away.
                if now.timeIntervalSince(watch.lastChange) >= Self.settle, value != prefix + watch.inserted { finish() }
                return
            }
            watch.lastChange = now
        } else {
            // First look after the paste landed: the inserted text must end the field, or edits can't be located.
            guard value.hasSuffix(watch.inserted) else { return stop() }
            watch.prefix = String(value.dropLast(watch.inserted.count))
        }
        watch.lastValue = value
        self.watch = watch
    }

    private func finish() {
        defer { stop() }
        guard let watch, let prefix = watch.prefix, let value = watch.lastValue, value.hasPrefix(prefix) else { return }
        let edited = String(value.dropFirst(prefix.count))
        guard edited != watch.inserted else { return }
        let corrections = Lexicon.corrections(inserted: watch.inserted, edited: edited)
        if !corrections.isEmpty { onLearned(corrections) }
    }
}
