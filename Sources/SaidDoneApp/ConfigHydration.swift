import SaidDoneCore

/// Merge credentials loaded after launch into the newest in-memory preferences. Non-secret fields
/// always come from `current`, so a slow Keychain read cannot undo settings edited in the meantime.
enum ConfigHydration {
    static func mergeSecrets(from hydrated: AppConfig, into current: AppConfig) -> AppConfig {
        var merged = current
        for (providerID, key) in hydrated.cloud.llmAPIKeys
        where !key.isEmpty && merged.cloud.llmAPIKeys[providerID, default: ""].isEmpty {
            merged.cloud.llmAPIKeys[providerID] = key
        }
        if merged.cloud.asrKey.isEmpty {
            merged.cloud.asrKey = hydrated.cloud.asrKey
        }
        return merged
    }
}
