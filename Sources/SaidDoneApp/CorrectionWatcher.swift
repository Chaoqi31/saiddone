import ApplicationServices
import Foundation
import SaidDoneCore

/// Watches the field SaidDone just inserted into for ~20s: when the user fixes a word right after
/// insertion (the Typeless behavior), diff the inserted text against the edited field value and
/// auto-learn the correction into the Custom Dictionary via `DictionaryLearning.diffTerms`.
///
/// Privacy: reads only the same AX element, only within the window, and only Latin token pairs
/// are persisted — the field's full contents are never stored.
@MainActor
final class CorrectionWatcher {
    static let shared = CorrectionWatcher()

    /// Set by AppController; receives learned pairs (already deduped into the dictionary by caller).
    var onLearned: (([DictionaryEntry]) -> Void)?

    private struct Watch {
        let element: AXUIElement
        let pid: pid_t
        let insertedText: String
        let startedAt: Date
        /// Field content before the inserted suffix — the diff is restricted to what followed it.
        var prefix: String
        var lastValue: String?
        var lastChangeAt: Date
    }

    private var watch: Watch?
    private var timer: Timer?
    private var baselineTaken = false

    private static let window: TimeInterval = 20
    private static let pollInterval: TimeInterval = 1.5
    private static let settle: TimeInterval = 2

    func watch(element: AXUIElement, pid: pid_t, insertedText: String) {
        guard !insertedText.isEmpty else { return }
        stop()
        guard CorrectionWatcher.enabled else { return }
        // Prefix starts empty; the first poll fills it once the paste has landed.
        self.watch = Watch(element: element, pid: pid, insertedText: insertedText,
                           startedAt: Date(), prefix: "", lastValue: nil, lastChangeAt: Date())
        baselineTaken = false
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
        slog("watch: started (\(insertedText.count) chars)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        watch = nil
    }

    /// Kill switch — set from config in beginCapture (MainActor); read here on the same actor.
    static var enabled = true

    // MARK: - Internals

    private func poll() {
        guard let w = watch else { return stop() }
        let now = Date()
        // Hard window from watch start — continued typing must not extend it.
        guard now.timeIntervalSince(w.startedAt) <= Self.window else {
            slog("watch: window closed")
            return stop()
        }

        // Focus moved on — the user left the field; stop reading it.
        if let focused = Self.focusedElement() {
            let focusedPID = Self.processID(of: focused)
            if !(focusedPID == w.pid && CFEqual(focused, w.element)) {
                // Still learn from the last stable value before bailing, if it changed.
                finishIfEdited()
                return stop()
            }
        }
        guard let value = Self.axString(w.element, kAXValueAttribute as CFString) else {
            slog("watch: value unreadable — done")
            return stop()
        }

        if !baselineTaken {
            baselineTaken = true
            // The paste must have landed as a suffix of the field; otherwise we can't reason about edits.
            guard value.hasSuffix(w.insertedText) else {
                slog("watch: inserted text not found as suffix — abort")
                return stop()
            }
            watch?.lastValue = value
            watch?.prefix = String(value.dropLast(w.insertedText.count))
            return
        }

        if value != w.lastValue {
            watch?.lastValue = value
            watch?.lastChangeAt = now
            return
        }
        // Value stable — after the settle delay, diff and finish.
        if now.timeIntervalSince(w.lastChangeAt) >= Self.settle {
            finishIfEdited()
            stop()
        }
    }

    private func finishIfEdited() {
        guard let w = watch, let value = w.lastValue else { return }
        // Compare only the region at/after the original prefix, so pre-existing field text and
        // anything the user typed after the insert region don't pollute the diff.
        guard value.hasPrefix(w.prefix) else { return }
        let edited = String(value.dropFirst(w.prefix.count))
        guard edited != w.insertedText else { return }
        let terms = DictionaryLearning.diffTerms(old: w.insertedText, new: edited)
        // ponytail: 1:1 token pairing misses fixes followed by more typing (counts then differ);
        // upgrade to LCS token alignment if that false negative matters in practice.
        guard !terms.isEmpty else {
            slog("watch: edited but no confident term pairs")
            return
        }
        slog("watch: learned \(terms.count) term(s): "
             + terms.map { "\($0.wrong)→\($0.right)" }.joined(separator: ", "))
        onLearned?(terms)
    }

    // MARK: - AX helpers (same queries InsertionService uses, kept local to avoid widening its API)

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var obj: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &obj) == .success else {
            return nil
        }
        return (obj as! AXUIElement)
    }

    private static func processID(of element: AXUIElement) -> pid_t? {
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success else { return nil }
        return processID
    }

    private static func axString(_ element: AXUIElement, _ attr: CFString) -> String? {
        var obj: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr, &obj) == .success else { return nil }
        return obj as? String
    }
}
