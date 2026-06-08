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
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        location = try c.decodeIfPresent(ProviderLocation.self, forKey: .location) ?? .local
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID) ?? ""
    }
}

/// Opt-in cloud endpoints (OpenAI-compatible). Keys live in config.json — local dev tool; keep private.
public struct CloudConfig: Codable, Sendable, Equatable {
    public var llmKey: String = ""
    public var llmBaseURL: String = "https://api.openai.com/v1"
    public var llmModel: String = "gpt-4o-mini"
    public var asrKey: String = ""
    public var asrBaseURL: String = "https://api.openai.com/v1"
    public var asrModel: String = "gpt-4o-transcribe"
    /// Optional HTTP proxy for cloud calls (helps when behind a restrictive network). Empty = none.
    public var proxyHost: String = ""
    public var proxyPort: Int = 0
    public init() {}

    /// Lenient decode: missing keys fall back to defaults, so adding fields never breaks an existing
    /// config.json (a strict decode here once silently reset the whole config to the local default).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        llmKey = try c.decodeIfPresent(String.self, forKey: .llmKey) ?? ""
        llmBaseURL = try c.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? "https://api.openai.com/v1"
        llmModel = try c.decodeIfPresent(String.self, forKey: .llmModel) ?? "gpt-4o-mini"
        asrKey = try c.decodeIfPresent(String.self, forKey: .asrKey) ?? ""
        asrBaseURL = try c.decodeIfPresent(String.self, forKey: .asrBaseURL) ?? "https://api.openai.com/v1"
        asrModel = try c.decodeIfPresent(String.self, forKey: .asrModel) ?? "gpt-4o-transcribe"
        proxyHost = try c.decodeIfPresent(String.self, forKey: .proxyHost) ?? ""
        proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? 0
    }
}

/// Persisted app config (Config Store, ARCHITECTURE). Codable -> JSON in Application Support.
/// Defaults encode the zero-key local path (GOALS B4) + the ADR-0003/0004 model picks.
public struct AppConfig: Codable, Sendable {
    public var dictationHotkey: Hotkey
    public var translationHotkey: Hotkey
    public var rewriteHotkey: Hotkey
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
    /// Mute system audio output while recording (so playing media doesn't bleed into the mic).
    public var muteAudioWhileRecording: Bool
    /// Honor spoken editing commands like "换行"/"newline" (off by default — can clash with normal speech).
    public var voiceCommandsEnabled: Bool
    /// Show live transcription text in the overlay while speaking (off by default).
    public var showLivePreview: Bool
    /// Capture from the built-in mic even when a Bluetooth headset is connected, so opening the mic
    /// doesn't force AirPods from hi-fi A2DP down to muffled narrowband HFP. Off by default (uses the
    /// system input you'd expect); opt in to avoid any playback degradation while recording.
    public var preferBuiltInMic: Bool
    /// Opt-in cloud endpoints (used when a provider's location is .cloud and a key is set).
    public var cloud: CloudConfig
    /// Personalization: the user's background/profession/jargon, fed to the Polish LLM (like
    /// ChatGPT custom instructions) so it handles their terminology and code-switching well.
    public var userProfile: String
    /// Whether the first-run onboarding wizard has completed (gates showing it at launch).
    public var onboardingCompleted: Bool
    /// HuggingFace download endpoint override. "" = huggingface.co; "https://hf-mirror.com" for China.
    public var huggingFaceEndpoint: String
    /// UI language override: "" = follow the system; otherwise an lproj code like "en" / "zh-Hans".
    public var appLanguage: String

    public init(
        dictationHotkey: Hotkey,
        translationHotkey: Hotkey,
        rewriteHotkey: Hotkey,
        targetLanguage: String = "en",
        asrLanguage: String? = "zh",
        asr: ProviderSelection,
        llm: ProviderSelection,
        dictionary: CustomDictionary = .init(),
        appProfiles: AppProfileStore = .init(),
        launchAtLogin: Bool = false,
        autoCopyToClipboard: Bool = false,
        soundsEnabled: Bool = true,
        muteAudioWhileRecording: Bool = false,
        voiceCommandsEnabled: Bool = false,
        showLivePreview: Bool = false,
        preferBuiltInMic: Bool = false,
        cloud: CloudConfig = .init(),
        userProfile: String = "",
        onboardingCompleted: Bool = false,
        huggingFaceEndpoint: String = "",
        appLanguage: String = ""
    ) {
        self.onboardingCompleted = onboardingCompleted
        self.huggingFaceEndpoint = huggingFaceEndpoint
        self.appLanguage = appLanguage
        self.launchAtLogin = launchAtLogin
        self.autoCopyToClipboard = autoCopyToClipboard
        self.soundsEnabled = soundsEnabled
        self.muteAudioWhileRecording = muteAudioWhileRecording
        self.voiceCommandsEnabled = voiceCommandsEnabled
        self.showLivePreview = showLivePreview
        self.preferBuiltInMic = preferBuiltInMic
        self.cloud = cloud
        self.userProfile = userProfile
        self.dictationHotkey = dictationHotkey
        self.translationHotkey = translationHotkey
        self.rewriteHotkey = rewriteHotkey
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
        rewriteHotkey = try c.decodeIfPresent(Hotkey.self, forKey: .rewriteHotkey)
            ?? Hotkey(keyCode: 15, modifiers: 0x040000 | 0x080000)
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? "en"
        asrLanguage = try c.decodeIfPresent(String.self, forKey: .asrLanguage)
        asr = try c.decode(ProviderSelection.self, forKey: .asr)
        llm = try c.decode(ProviderSelection.self, forKey: .llm)
        dictionary = try c.decodeIfPresent(CustomDictionary.self, forKey: .dictionary) ?? .init()
        appProfiles = try c.decodeIfPresent(AppProfileStore.self, forKey: .appProfiles) ?? .init()
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        autoCopyToClipboard = try c.decodeIfPresent(Bool.self, forKey: .autoCopyToClipboard) ?? false
        soundsEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundsEnabled) ?? true
        muteAudioWhileRecording = try c.decodeIfPresent(Bool.self, forKey: .muteAudioWhileRecording) ?? false
        voiceCommandsEnabled = try c.decodeIfPresent(Bool.self, forKey: .voiceCommandsEnabled) ?? false
        showLivePreview = try c.decodeIfPresent(Bool.self, forKey: .showLivePreview) ?? false
        preferBuiltInMic = try c.decodeIfPresent(Bool.self, forKey: .preferBuiltInMic) ?? false
        cloud = try c.decodeIfPresent(CloudConfig.self, forKey: .cloud) ?? .init()
        userProfile = try c.decodeIfPresent(String.self, forKey: .userProfile) ?? ""
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        huggingFaceEndpoint = try c.decodeIfPresent(String.self, forKey: .huggingFaceEndpoint) ?? ""
        appLanguage = try c.decodeIfPresent(String.self, forKey: .appLanguage) ?? ""
    }

    /// Zero-key local defaults (GOALS B4). Hotkeys: ⌃⌥D (dictation), ⌃⌥T (translation) — avoid
    /// ⌥Space (macOS input-source switch) and other system conflicts.
    public static let `default` = AppConfig(
        dictationHotkey: Hotkey(keyCode: 2, modifiers: 0x040000 | 0x080000),   // ⌃⌥ + D
        translationHotkey: Hotkey(keyCode: 17, modifiers: 0x040000 | 0x080000), // ⌃⌥ + T
        rewriteHotkey: Hotkey(keyCode: 15, modifiers: 0x040000 | 0x080000),    // ⌃⌥ + R
        asr: ProviderSelection(location: .local, modelID: "openai_whisper-large-v3-v20240930_turbo"),
        llm: ProviderSelection(location: .local, modelID: "mlx-community/Qwen3-4B-4bit")
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
        guard let data = try? Data(contentsOf: url) else { return .default }   // no file = fresh install
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            // A real config existed but couldn't be read — never silently use defaults without a trace.
            // Preserve the file (so the user's settings aren't lost) and log loudly.
            NSLog("SaidDone: CONFIG DECODE FAILED — using defaults this launch, original kept. Error: %@", "\(error)")
            try? data.write(to: url.appendingPathExtension("bad"))
            return .default
        }
    }

    public func save(_ config: AppConfig) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: url, options: .atomic)
    }
}
