import Foundation

/// A global hotkey: Carbon keycode + modifier flags (raw NSEvent.ModifierFlags rawValue).
public struct Hotkey: Codable, Sendable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt
    public init(keyCode: UInt32, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Which Provider to use for a stage, and (if local) which model id.
public struct ProviderSelection: Codable, Sendable, Equatable {
    public var location: ProviderLocation
    public var modelID: String
    public init(location: ProviderLocation, modelID: String) {
        self.location = location
        self.modelID = modelID
    }
}

/// Opt-in cloud endpoints (OpenAI-compatible). Keys live in config.json — local dev tool; keep private.
public struct CloudConfig: Codable, Sendable, Equatable {
    public var llmKey: String = ""
    public var llmBaseURL: String = "https://api.openai.com/v1"
    public var llmModel: String = "gpt-4o-mini"
    public var asrKey: String = ""
    public var asrBaseURL: String = "https://api.openai.com/v1"
    public var asrModel: String = "whisper-1"
    public init() {}
}

/// Persisted app config (Config Store, ARCHITECTURE). Codable -> JSON in Application Support.
/// Defaults encode the zero-key local path (GOALS B4) + the ADR-0003/0004 model picks.
public struct AppConfig: Codable, Sendable {
    public var dictationHotkey: Hotkey
    public var translationHotkey: Hotkey
    public var targetLanguage: String
    /// Primary spoken language for ASR (e.g. "zh", "en"); nil = auto-detect. Code-switch transcription
    /// works best when this matches your primary language (WhisperKit auto-detect is unreliable for mixing).
    public var asrLanguage: String?
    public var asr: ProviderSelection
    public var llm: ProviderSelection
    public var dictionary: CustomDictionary
    public var appProfiles: AppProfileStore
    /// Start SaidDone at login (SMAppService).
    public var launchAtLogin: Bool
    /// Leave the inserted text on the clipboard afterwards (don't restore the previous clipboard).
    public var autoCopyToClipboard: Bool
    /// Play a subtle sound on record start / result inserted.
    public var soundsEnabled: Bool
    /// Opt-in cloud endpoints (used when a provider's location is .cloud and a key is set).
    public var cloud: CloudConfig
    /// Personalization: the user's background/profession/jargon, fed to the Polish LLM (like
    /// ChatGPT custom instructions) so it handles their terminology and code-switching well.
    public var userProfile: String

    public init(
        dictationHotkey: Hotkey,
        translationHotkey: Hotkey,
        targetLanguage: String = "en",
        asrLanguage: String? = "zh",
        asr: ProviderSelection,
        llm: ProviderSelection,
        dictionary: CustomDictionary = .init(),
        appProfiles: AppProfileStore = .init(),
        launchAtLogin: Bool = false,
        autoCopyToClipboard: Bool = false,
        soundsEnabled: Bool = true,
        cloud: CloudConfig = .init(),
        userProfile: String = ""
    ) {
        self.launchAtLogin = launchAtLogin
        self.autoCopyToClipboard = autoCopyToClipboard
        self.soundsEnabled = soundsEnabled
        self.cloud = cloud
        self.userProfile = userProfile
        self.dictationHotkey = dictationHotkey
        self.translationHotkey = translationHotkey
        self.targetLanguage = targetLanguage
        self.asrLanguage = asrLanguage
        self.asr = asr
        self.llm = llm
        self.dictionary = dictionary
        self.appProfiles = appProfiles
    }

    /// Lenient decode: missing keys fall back to defaults so adding config fields never wipes a
    /// user's existing config.json.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dictationHotkey = try c.decode(Hotkey.self, forKey: .dictationHotkey)
        translationHotkey = try c.decode(Hotkey.self, forKey: .translationHotkey)
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? "en"
        asrLanguage = try c.decodeIfPresent(String.self, forKey: .asrLanguage)
        asr = try c.decode(ProviderSelection.self, forKey: .asr)
        llm = try c.decode(ProviderSelection.self, forKey: .llm)
        dictionary = try c.decodeIfPresent(CustomDictionary.self, forKey: .dictionary) ?? .init()
        appProfiles = try c.decodeIfPresent(AppProfileStore.self, forKey: .appProfiles) ?? .init()
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        autoCopyToClipboard = try c.decodeIfPresent(Bool.self, forKey: .autoCopyToClipboard) ?? false
        soundsEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundsEnabled) ?? true
        cloud = try c.decodeIfPresent(CloudConfig.self, forKey: .cloud) ?? .init()
        userProfile = try c.decodeIfPresent(String.self, forKey: .userProfile) ?? ""
    }

    /// Zero-key local defaults (GOALS B4). Hotkeys: ⌃⌥D (dictation), ⌃⌥T (translation) — avoid
    /// ⌥Space (macOS input-source switch) and other system conflicts.
    public static let `default` = AppConfig(
        dictationHotkey: Hotkey(keyCode: 2, modifiers: 0x040000 | 0x080000),   // ⌃⌥ + D
        translationHotkey: Hotkey(keyCode: 17, modifiers: 0x040000 | 0x080000), // ⌃⌥ + T
        asr: ProviderSelection(location: .local, modelID: "qwen3-asr-1.7b"),
        llm: ProviderSelection(location: .local, modelID: "qwen3.5-0.8b")
    )
}

/// Loads/saves AppConfig as JSON under ~/Library/Application Support/SaidDone/config.json.
public struct ConfigStore: Sendable {
    public let url: URL

    public init(directory: URL) {
        self.url = directory.appendingPathComponent("config.json")
    }

    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("SaidDone", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public func load() -> AppConfig {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return .default
        }
        return cfg
    }

    public func save(_ config: AppConfig) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: url, options: .atomic)
    }
}
