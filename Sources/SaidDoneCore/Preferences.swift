import Foundation

/// Every user setting except secrets (Vault), dictionary terms (DictionaryStore) and launch at login (the system
/// owns that). Loaded leniently: a missing or unreadable key falls back to its default without touching the others.
public struct Preferences: Codable, Equatable, Sendable {
    public var shortcuts: Shortcuts = .default
    public var spokenLanguage: SpokenLanguage = .fixed(.chinese)
    public var translationTarget: Language = .english
    public var speech: SpeechEngine = .whisper(.recommended)
    public var ai: AIEngine = .cloud(CloudPreset.deepseek.defaultEndpoint)
    public var proxy: Proxy?
    /// Download models through hf-mirror.com (Hugging Face is slow or blocked in some regions).
    public var downloadMirror = false
    public var microphone: MicrophoneChoice = .automatic
    public var muteWhileRecording = false
    public var sounds = true
    public var showInDock = false
    public var appearance: Appearance = .system
    public var interfaceLanguage: InterfaceLanguage = .system
    public var historyRetention: Retention = .forever
    public var learnFromCorrections = true
    public var personalization = Personalization()
    public var onboardingCompleted = false

    public init() {}

    /// Decodes each top-level key on its own, so a setting written by another version (or damaged by hand) resets
    /// only itself. Unparseable data yields the defaults.
    public static func decode(_ data: Data) -> Preferences {
        let defaults = Preferences()
        guard let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var merged = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults))) as? [String: Any]
        else { return defaults }
        for (key, value) in file {
            var candidate = merged
            candidate[key] = value
            if decodes(candidate) { merged = candidate }
        }
        return (try? JSONSerialization.data(withJSONObject: merged))
            .flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? defaults
    }

    private static func decodes(_ object: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        return (try? JSONDecoder().decode(Preferences.self, from: data)) != nil
    }
}

/// The language the user speaks. Auto-detect is a value, not `nil`, so it survives the lenient decode.
public enum SpokenLanguage: Codable, Hashable, Sendable {
    case detect
    case fixed(Language)

    public var language: Language? {
        if case let .fixed(language) = self { language } else { nil }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw == "auto" ? .detect : .fixed(Language(rawValue: raw))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(language?.rawValue ?? "auto")
    }
}

public enum SpeechEngine: Codable, Hashable, Sendable {
    case whisper(WhisperModel)
    case cloud(CloudEndpoint)
    case volcengine(appID: String, resource: VolcengineResource)

    /// Whose credential it needs. nil = on device.
    public var vendor: VendorID? {
        switch self {
        case .whisper: nil
        case let .cloud(endpoint): endpoint.vendor
        case .volcengine: .volcengine
        }
    }

    public var localModel: LocalModel? {
        if case let .whisper(model) = self { .whisper(model) } else { nil }
    }
}

public enum AIEngine: Codable, Hashable, Sendable {
    case qwen(QwenModel)
    case cloud(CloudEndpoint)

    public var vendor: VendorID? {
        if case let .cloud(endpoint) = self { endpoint.vendor } else { nil }
    }

    public var localModel: LocalModel? {
        if case let .qwen(model) = self { .qwen(model) } else { nil }
    }

    public var isLocal: Bool { localModel != nil }
}

public struct Proxy: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

public enum Appearance: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

public enum InterfaceLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
}

public struct Personalization: Codable, Equatable, Sendable {
    /// Who the user is, for terminology: "iOS engineer; mixes English tech terms into Chinese".
    public var profile = ""
    public var defaultTone = ""
    /// Bundle identifier → tone.
    public var toneByApp: [String: String] = [:]

    public init(profile: String = "", defaultTone: String = "", toneByApp: [String: String] = [:]) {
        self.profile = profile
        self.defaultTone = defaultTone
        self.toneByApp = toneByApp
    }

    public func tone(for app: String?) -> String? {
        let tone = app.flatMap { toneByApp[$0] } ?? defaultTone
        let trimmed = tone.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Microphone

public struct InputDevice: Identifiable, Hashable, Sendable {
    public enum Transport: Hashable, Sendable { case builtIn, bluetooth, usb, other }

    /// CoreAudio device UID: stable across reconnects, unlike AudioDeviceID.
    public let id: String
    public let name: String
    public let transport: Transport

    public init(id: String, name: String, transport: Transport) {
        self.id = id
        self.name = name
        self.transport = transport
    }
}

public enum MicrophoneChoice: Codable, Hashable, Sendable {
    /// The system default, except that a Bluetooth default is skipped for the built-in mic: opening a headset
    /// mic drops its playback to low-quality call audio, and headset mics transcribe worse.
    case automatic
    /// The name is kept to say "Blue Yeti isn't connected".
    case device(uid: String, name: String)

    public struct Resolution: Equatable, Sendable {
        /// nil = let the audio engine open the system default.
        public var uid: String?
        /// The chosen device is not connected, so automatic was used instead.
        public var substituted: Bool
    }

    public func resolve(_ devices: [InputDevice], systemDefault: String?) -> Resolution {
        switch self {
        case let .device(uid, _):
            if devices.contains(where: { $0.id == uid }) { return Resolution(uid: uid, substituted: false) }
            return Resolution(uid: Self.automatic.resolve(devices, systemDefault: systemDefault).uid, substituted: true)
        case .automatic:
            guard let systemDefault,
                  devices.first(where: { $0.id == systemDefault })?.transport == .bluetooth,
                  let builtIn = devices.first(where: { $0.transport == .builtIn })
            else { return Resolution(uid: nil, substituted: false) }
            return Resolution(uid: builtIn.id, substituted: false)
        }
    }
}
