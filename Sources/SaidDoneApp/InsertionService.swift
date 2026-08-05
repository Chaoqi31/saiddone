import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Inserts text at the cursor in any app via clipboard paste (ADR-0005):
/// save pasteboard → write text → synthesize ⌘V → restore pasteboard.
/// Requires Accessibility permission (for CGEvent posting).
@MainActor
enum InsertionService {
    private struct FastDraftTarget {
        let element: AXUIElement
        let processID: pid_t
        let draft: String
    }

    private static var fastDraftTarget: FastDraftTarget?
    private static var pendingPasteboardRestore: DispatchWorkItem?
    private static var pasteboardRestoreGeneration = 0

    static func insert(_ text: String, autoCopy: Bool = false) -> Bool {
        guard !text.isEmpty else { return true }
        cancelPendingPasteboardRestore()
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
        schedulePasteboardRestore(saved, pasteboard: pasteboard)
        return true
    }

    /// Insert a draft and retain the exact Accessibility target required for a safe final swap.
    static func insertFastDraft(_ text: String, autoCopy: Bool = false) -> Bool {
        fastDraftTarget = nil
        guard let target = replaceableFastDraftTarget(for: text) else {
            // Some apps (notably terminal and web-based editors) accept ⌘V but do not expose a
            // readable/writable AXValue. Inserting a draft there would leave us with no safe way
            // to swap in the polished result, so let the pipeline insert only the final text.
            slog("fast draft skipped — focused field cannot be safely replaced")
            return false
        }
        guard insert(text, autoCopy: autoCopy) else { return false }
        fastDraftTarget = target
        return true
    }

    /// A fast draft is useful only when the same Accessibility element can later prove that the
    /// exact draft is still present and can replace it. Preflight that contract before inserting.
    private static func replaceableFastDraftTarget(for draft: String) -> FastDraftTarget? {
        guard let element = focusedElement(),
              let processID = processID(of: element),
              axString(element, kAXValueAttribute as CFString) != nil else { return nil }

        let canReplaceSelection = isSettable(element, kAXSelectedTextRangeAttribute as CFString)
            && isSettable(element, kAXSelectedTextAttribute as CFString)
        let canReplaceValue = isSettable(element, kAXValueAttribute as CFString)
        guard canReplaceSelection || canReplaceValue else { return nil }
        return FastDraftTarget(element: element, processID: processID, draft: draft)
    }

    private static func synthesizeCommandV() { synthesizeCmd(CGKeyCode(kVK_ANSI_V)) }

    /// Safely replace a fast-inserted draft after verifying it is still the focused field's suffix.
    /// If the field cannot be verified, leave it untouched and copy the final text for manual paste.
    static func replaceFastDraft(with text: String, replacing previous: String, autoCopy: Bool = false) -> Bool {
        defer { fastDraftTarget = nil }
        guard !text.isEmpty else { return true }
        guard AXIsProcessTrusted() else {
            cancelPendingPasteboardRestore()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            slog("replace: NOT trusted — copied text to clipboard")
            return false
        }
        if let target = fastDraftTarget,
           target.draft == previous,
           let current = focusedElement(),
           processID(of: current) == target.processID,
           CFEqual(current, target.element),
           tryReplaceSuffix(in: current, previous: previous, with: text) {
            slog("replace: AX suffix swap ok")
            if autoCopy {
                cancelPendingPasteboardRestore()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return true
        }
        cancelPendingPasteboardRestore()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        slog("replace: draft suffix unavailable — final text copied without undo")
        return false
    }

    /// Replace a freshly pasted suffix via Accessibility when the focused field exposes `AXValue`.
    /// Uses selection-based replacement (select the old suffix, set selected text) so the caret lands
    /// at the end of the inserted text — setting AXValue directly resets the caret to 0 in many apps.
    private static func tryReplaceSuffix(in element: AXUIElement, previous: String, with text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let value = axString(element, kAXValueAttribute as CFString), value.hasSuffix(previous) else {
            return false
        }
        let previousLength = (previous as NSString).length
        let draftStart = (value as NSString).length - previousLength
        // Preferred: select the previous suffix, then replace just the selection. The caret ends up
        // at the end of the newly inserted text with no whole-value reset.
        var sel = CFRange(location: draftStart, length: previousLength)
        if let axRange = AXValueCreate(.cfRange, &sel),
           AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success,
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
            return true
        }
        // Fallback: rewrite the whole value, then move the caret to the end best-effort.
        var newValue = value
        let draftRange = NSRange(location: draftStart, length: previousLength)
        guard let range = Range(draftRange, in: newValue) else { return false }
        newValue.replaceSubrange(range, with: text)
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue as CFTypeRef) == .success else {
            return false
        }
        var endRange = CFRange(location: (newValue as NSString).length, length: 0)
        if let axEnd = AXValueCreate(.cfRange, &endRange) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axEnd)
        }
        return true
    }

    private static func schedulePasteboardRestore(
        _ saved: PasteboardSnapshot,
        pasteboard: NSPasteboard
    ) {
        pasteboardRestoreGeneration += 1
        let generation = pasteboardRestoreGeneration
        let changeCount = pasteboard.changeCount
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard generation == pasteboardRestoreGeneration else { return }
                pendingPasteboardRestore = nil
                guard pasteboard.changeCount == changeCount else { return }
                saved.restore(to: pasteboard)
            }
        }
        pendingPasteboardRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private static func cancelPendingPasteboardRestore() {
        pasteboardRestoreGeneration += 1
        pendingPasteboardRestore?.cancel()
        pendingPasteboardRestore = nil
    }

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

    private static func isSettable(_ element: AXUIElement, _ attr: CFString) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attr, &settable) == .success
            && settable.boolValue
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
