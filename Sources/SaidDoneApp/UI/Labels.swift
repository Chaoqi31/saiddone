import AppKit
import Carbon.HIToolbox
import SaidDoneCore
import SaidDoneEngines

// Display text for Core's types. Every user-visible name for a domain value is here, so views never switch on them.

extension Mode {
    var title: String {
        switch self {
        case .dictation: tr("Voice Input")
        case .translation: tr("Translation")
        case .ask: tr("Ask Anything")
        }
    }

    var summary: String {
        switch self {
        case .dictation: tr("Speak, and polished text appears where you type.")
        case .translation: tr("Speak in any language, and the translation appears where you type.")
        case .ask: tr("Ask a question, or select text first and say what to do with it.")
        }
    }

    var symbol: String {
        switch self {
        case .dictation: "mic.fill"
        case .translation: "globe"
        case .ask: "sparkles"
        }
    }
}

extension Stage {
    var label: String {
        switch self {
        case .preparing: tr("Loading model…")
        case .transcribing: tr("Transcribing…")
        case .polishing: tr("Polishing…")
        case .translating: tr("Translating…")
        case .answering: tr("Thinking…")
        }
    }
}

extension Issue {
    var title: String {
        switch self {
        case .microphoneNotAllowed: tr("Allow microphone access")
        case .accessibilityNotAllowed: tr("Allow Accessibility access")
        case .globeKeyAssigned: tr("Free up the 🌐 key")
        case let .modelNotInstalled(model): tr("Download %@", model.name)
        case .onDeviceAIUnavailable: tr("On-device AI doesn’t work in this build")
        case let .credentialMissing(vendor): tr("Add your %@ API key", CloudPreset.name(vendor))
        case .speechModelNotChosen: tr("Choose a speech model")
        case .aiModelNotChosen: tr("Choose an AI model")
        }
    }

    var detail: String {
        switch self {
        case .microphoneNotAllowed: tr("SaidDone needs the microphone to hear you.")
        case .accessibilityNotAllowed: tr("Needed for the shortcuts and to type into other apps.")
        case .globeKeyAssigned:
            tr("In Keyboard settings, set “Press 🌐 key to” to “Do Nothing”, so fn only starts SaidDone.")
        case let .modelNotInstalled(model): tr("%@ download, runs on this Mac.", model.approximateBytes.fileSize)
        case .onDeviceAIUnavailable: tr("It was built without Xcode’s Metal shaders. Choose a cloud AI in Speech & AI.")
        case .credentialMissing: tr("The cloud engine you chose needs a key.")
        case .speechModelNotChosen, .aiModelNotChosen: tr("Pick one of the service’s models in Speech & AI.")
        }
    }
}

extension Failure {
    var message: String {
        switch self {
        case .offline: tr("You’re offline.")
        case .unauthorized: tr("The API key was rejected.")
        case .rateLimited: tr("The service is rate limiting you. Try again in a moment.")
        case .serverBusy: tr("The service is busy. Try again.")
        case .timeout: tr("The AI took too long to answer.")
        case let .rejected(reason): tr("The service refused the request: %@", reason)
        case .badResponse: tr("The service sent an answer SaidDone can’t read.")
        case .modelMissing: tr("The model isn’t downloaded.")
        case .missingCredential: tr("No API key.")
        case .unsupported: tr("This build of SaidDone can’t run that engine.")
        case .emptyReply: tr("The AI returned nothing.")
        case .cancelled: tr("Cancelled.")
        case .interrupted: tr("SaidDone quit before this finished.")
        }
    }
}

extension CaptureError {
    var message: String {
        switch self {
        case .notAuthorized: tr("SaidDone isn’t allowed to use the microphone.")
        case .noInputDevice: tr("No microphone is connected.")
        case .engineFailed: tr("The microphone couldn’t start.")
        }
    }
}

extension DownloadError {
    var message: String {
        switch self {
        case .offline: tr("You’re offline.")
        case let .notEnoughSpace(needed): tr("Not enough disk space. The model needs %@.", needed.fileSize)
        case .cancelled: tr("Cancelled.")
        case .failed: tr("The download failed. Try again, or turn on the download mirror.")
        }
    }
}

extension Delivery {
    var label: String {
        switch self {
        case .inserted: tr("Inserted")
        case .replacedSelection: tr("Replaced selection")
        case .answered: tr("Answered")
        case .opened: tr("Opened in browser")
        case .copied: tr("Copied")
        }
    }
}

extension Retention {
    var label: String {
        switch self {
        case .forever: tr("Forever")
        case .month: tr("30 days")
        case .week: tr("7 days")
        case .day: tr("24 hours")
        case .never: tr("Don’t keep")
        }
    }
}

extension Appearance {
    var label: String {
        switch self {
        case .system: tr("System")
        case .light: tr("Light")
        case .dark: tr("Dark")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension InterfaceLanguage {
    /// Language names are shown in the language itself.
    var label: String {
        switch self {
        case .system: tr("System")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }
}

extension SpokenLanguage {
    var label: String { language?.endonym ?? tr("Detect automatically") }
}

extension Int64 {
    var fileSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

// MARK: - Shortcuts

extension Trigger {
    /// One keycap per key, in the order they are pressed: fn first, then the modifiers held with it.
    var keycaps: [String] {
        switch self {
        case let .modifierKey(key, with):
            return [key.label] + with.symbols
        case let .keyCombo(code, modifiers):
            return modifiers.symbols + [code.label]
        case let .mouse(button):
            return [button.number == 2 ? tr("Middle mouse button") : tr("Mouse button %lld", button.number + 1)]
        }
    }

    var label: String { keycaps.joined(separator: " ") }
}

extension ModifierKey {
    var label: String {
        switch self {
        case .fn: "fn"
        case .rightCommand: tr("Right ⌘")
        case .rightOption: tr("Right ⌥")
        case .rightControl: tr("Right ⌃")
        case .rightShift: tr("Right ⇧")
        }
    }
}

extension ModifierFlags {
    /// In the order macOS menus show them.
    var symbols: [String] {
        let order: [(ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return order.compactMap { contains($0.0) ? $0.1 : nil }
    }
}

extension KeyCode {
    /// What the key's cap says on the user's keyboard layout.
    var label: String {
        if let name = Self.names[rawValue] { return name }
        if let index = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
            .firstIndex(of: Int(rawValue)) {
            return "F\(index + 1)"
        }
        return Self.character(rawValue) ?? "#\(rawValue)"
    }

    private static var names: [UInt16: String] {
        [49: tr("Space"), 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
         123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟"]
    }

    /// The unshifted character from the current ASCII-capable layout, so Pinyin users see their Latin letters.
    private static func character(_ code: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count,
                                        &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length).uppercased()
        }
    }
}
