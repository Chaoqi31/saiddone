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

/// Persisted app config (Config Store, ARCHITECTURE). Codable -> JSON in Application Support.
/// Defaults encode the zero-key local path (GOALS B4) + the ADR-0003/0004 model picks.
public struct AppConfig: Codable, Sendable {
    public var dictationHotkey: Hotkey
    public var translationHotkey: Hotkey
    public var targetLanguage: String
    public var asr: ProviderSelection
    public var llm: ProviderSelection
    public var dictionary: CustomDictionary
    public var appProfiles: AppProfileStore

    public init(
        dictationHotkey: Hotkey,
        translationHotkey: Hotkey,
        targetLanguage: String = "en",
        asr: ProviderSelection,
        llm: ProviderSelection,
        dictionary: CustomDictionary = .init(),
        appProfiles: AppProfileStore = .init()
    ) {
        self.dictationHotkey = dictationHotkey
        self.translationHotkey = translationHotkey
        self.targetLanguage = targetLanguage
        self.asr = asr
        self.llm = llm
        self.dictionary = dictionary
        self.appProfiles = appProfiles
    }

    /// Zero-key local defaults (GOALS B4). Hotkeys: ⌥Space (dictation), ⌥⇧Space (translation).
    public static let `default` = AppConfig(
        dictationHotkey: Hotkey(keyCode: 49, modifiers: 0x080000),          // ⌥ + Space
        translationHotkey: Hotkey(keyCode: 49, modifiers: 0x080000 | 0x020000), // ⌥⇧ + Space
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
