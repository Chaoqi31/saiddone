import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Inserts text at the cursor in any app via clipboard paste (ADR-0005):
/// save pasteboard → write text → synthesize ⌘V → restore pasteboard.
/// Requires Accessibility permission (for CGEvent posting).
@MainActor
enum InsertionService {
    static func insert(_ text: String, autoCopy: Bool = false) {
        guard !text.isEmpty else { return }
        let trusted = AXIsProcessTrusted()
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        slog("insert: trusted=\(trusted), front=\(front), len=\(text.count)")
        guard trusted else {
            slog("insert: NOT trusted — paste will be dropped. Grant Accessibility to this build.")
            // Leave the text on the clipboard so the user can ⌘V manually as a fallback.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }

        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        synthesizeCommandV()
        slog("insert: ⌘V posted")

        // Restore after the paste is delivered (longer delay avoids racing the paste).
        // autoCopy = leave the inserted text on the clipboard instead of restoring.
        guard !autoCopy else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            saved.restore(to: pasteboard)
        }
    }

    private static func synthesizeCommandV() { synthesizeCmd(CGKeyCode(kVK_ANSI_V)) }

    private static func synthesizeCmd(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = .maskCommand
        let loc = CGEventTapLocation.cghidEventTap
        down?.post(tap: loc)
        up?.post(tap: loc)
    }

    /// Copy the current selection (⌘C) and return it — for Rewrite Mode. Requires Accessibility.
    static func grabSelection() -> String {
        guard AXIsProcessTrusted() else { return "" }
        let pb = NSPasteboard.general
        let saved = PasteboardSnapshot(pb)
        synthesizeCmd(CGKeyCode(kVK_ANSI_C))
        RunLoop.current.run(until: Date().addingTimeInterval(0.18))   // let the copy land
        let selection = pb.string(forType: .string) ?? ""
        saved.restore(to: pb)
        return selection
    }
}

struct PasteboardSnapshot {
    private let items: [NSPasteboardItem]

    init(_ pasteboard: NSPasteboard) {
        items = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            var wroteAny = false
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type); wroteAny = true }
            }
            return wroteAny ? copy : nil
        } ?? []
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
