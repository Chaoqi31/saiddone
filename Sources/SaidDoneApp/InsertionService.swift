import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Inserts text at the cursor in any app via clipboard paste (ADR-0005):
/// save pasteboard → write text → synthesize ⌘V → restore pasteboard.
/// Requires Accessibility permission (for CGEvent posting).
@MainActor
enum InsertionService {
    static func insert(_ text: String, autoCopy: Bool = false) -> Bool {
        guard !text.isEmpty else { return true }
        let trusted = AXIsProcessTrustedWithOptions([
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary)
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        slog("insert: trusted=\(trusted), front=\(front), len=\(text.count)")
        guard trusted else {
            slog("insert: NOT trusted — copied text to clipboard. Grant Accessibility to this build.")
            // Leave the text on the clipboard so the user can ⌘V manually as a fallback.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return false
        }

        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        synthesizeCommandV()
        slog("insert: ⌘V posted")

        // Restore after the paste is delivered (longer delay avoids racing the paste).
        // autoCopy = leave the inserted text on the clipboard instead of restoring.
        guard !autoCopy else { return true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            saved.restore(to: pasteboard)
        }
        return true
    }

    private static func synthesizeCommandV() { synthesizeCmd(CGKeyCode(kVK_ANSI_V)) }
    private static func synthesizeCommandZ() { synthesizeCmd(CGKeyCode(kVK_ANSI_Z)) }

    /// Undo the last paste (⌘Z) and insert polished text — used after fast-insert draft.
    /// When `replacing` is set, tries AX value suffix swap first (more reliable in some editors).
    static func replaceViaUndo(with text: String, replacing previous: String? = nil, autoCopy: Bool = false) -> Bool {
        guard !text.isEmpty else { return true }
        guard AXIsProcessTrusted() else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            slog("replace: NOT trusted — copied text to clipboard")
            return false
        }
        if let previous, !previous.isEmpty, tryReplaceSuffix(previous: previous, with: text) {
            slog("replace: AX suffix swap ok")
            if autoCopy {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return true
        }
        synthesizeCommandZ()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            _ = insert(text, autoCopy: autoCopy)
        }
        return true
    }

    /// Replace a freshly pasted suffix via Accessibility when the focused field exposes `AXValue`.
    /// Uses selection-based replacement (select the old suffix, set selected text) so the caret lands
    /// at the end of the inserted text — setting AXValue directly resets the caret to 0 in many apps.
    private static func tryReplaceSuffix(previous: String, with text: String) -> Bool {
        guard AXIsProcessTrusted(), let element = focusedElement() else { return false }
        guard let value = axString(element, kAXValueAttribute as CFString), value.hasSuffix(previous) else {
            return false
        }
        let draftStart = value.count - previous.count
        // Preferred: select the previous suffix, then replace just the selection. The caret ends up
        // at the end of the newly inserted text with no whole-value reset.
        var sel = CFRange(location: draftStart, length: previous.count)
        if let axRange = AXValueCreate(.cfRange, &sel),
           AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success,
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
            return true
        }
        // Fallback: rewrite the whole value, then move the caret to the end best-effort.
        var newValue = value
        newValue.replaceSubrange(newValue.index(newValue.endIndex, offsetBy: -previous.count)..., with: text)
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue as CFTypeRef) == .success else {
            return false
        }
        var endRange = CFRange(location: newValue.count, length: 0)
        if let axEnd = AXValueCreate(.cfRange, &endRange) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axEnd)
        }
        return true
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var obj: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &obj) == .success else {
            return nil
        }
        return (obj as! AXUIElement)
    }

    private static func axString(_ element: AXUIElement, _ attr: CFString) -> String? {
        var obj: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr, &obj) == .success else { return nil }
        return obj as? String
    }

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

    /// Copy the current selection (⌘C) and return it — for Ask Anything mode. Requires Accessibility.
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
