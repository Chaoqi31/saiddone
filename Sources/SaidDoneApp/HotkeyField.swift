import SwiftUI
import AppKit
import SaidDoneCore

/// Click to record a new global shortcut (captures the next key-with-modifier).
struct HotkeyRecorder: View {
    let label: LocalizedStringKey
    @Binding var hotkey: Hotkey
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Button(recording ? NSLocalizedString("Press shortcut…", comment: "hotkey recorder") : hotkeyDisplay(hotkey)) { toggle() }
                .frame(minWidth: 120)
        }
        .onDisappear { stop() }
    }

    private func toggle() {
        if recording { stop(); return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue
            if mods != 0 {  // require at least one modifier to avoid trapping plain keys
                hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: mods)
                stop()
                return nil
            }
            return event
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

/// "⌃⌥D" style display for a Hotkey.
func hotkeyDisplay(_ h: Hotkey) -> String {
    let f = NSEvent.ModifierFlags(rawValue: h.modifiers)
    var s = ""
    if f.contains(.control) { s += "⌃" }
    if f.contains(.option) { s += "⌥" }
    if f.contains(.shift) { s += "⇧" }
    if f.contains(.command) { s += "⌘" }
    return s + keyName(h.keyCode)
}

private func keyName(_ code: UInt32) -> String {
    let map: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        49: "Space", 36: "Return", 53: "Esc", 48: "Tab",
    ]
    return map[code] ?? "key\(code)"
}
