import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts text where the user is typing, and reads what they have selected.
@MainActor
final class Inserter {
    enum Result { case pasted, copied }

    private var restoreGeneration = 0

    /// Pastes through the clipboard and puts the user's clipboard back afterwards. Without Accessibility the text
    /// is left on the clipboard instead.
    func paste(_ text: String) -> Result {
        guard AXIsProcessTrusted() else {
            copy(text)
            return .copied
        }
        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Clipboard managers skip transient items, so dictation doesn't flood their history.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        SyntheticKeys.command(CGKeyCode(kVK_ANSI_V))

        restoreGeneration += 1
        let generation = restoreGeneration
        let ours = pasteboard.changeCount
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            // Only if nothing else has touched the clipboard since, including a newer paste of ours.
            guard generation == restoreGeneration, pasteboard.changeCount == ours else { return }
            saved.restore(to: pasteboard)
        }
        return .pasted
    }

    func copy(_ text: String) {
        restoreGeneration += 1
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Accessibility first, which leaves the clipboard alone. Otherwise a ⌘C, accepted only if the clipboard actually
    /// changes: with nothing selected, the previous clipboard must never be mistaken for a selection.
    func selectedText() async -> String {
        guard AXIsProcessTrusted() else { return "" }
        if let focused = Self.focusedElement(), let text = Self.string(focused, kAXSelectedTextAttribute), !text.isEmpty {
            return text
        }
        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)
        let before = pasteboard.changeCount
        SyntheticKeys.command(CGKeyCode(kVK_ANSI_C))
        for _ in 0..<15 where pasteboard.changeCount == before {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard pasteboard.changeCount != before else { return "" }
        let text = pasteboard.string(forType: .string) ?? ""
        saved.restore(to: pasteboard)
        return text
    }

    static func focusedElement() -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString,
                                            &value) == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

/// Every item and type on the clipboard, so a paste can put it back exactly.
struct PasteboardSnapshot {
    private let items: [NSPasteboardItem]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).compactMap { item in
            let copy = NSPasteboardItem()
            var wrote = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    wrote = true
                }
            }
            return wrote ? copy : nil
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
