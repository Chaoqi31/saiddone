import Foundation
import SaidDoneCore

/// Optional `.env` in Application Support — fills cloud keys/URLs when Keychain is empty (dev-friendly).
enum EnvLoader {
    /// Apply `DEEPSEEK_*` / `OPENAI_*` vars from `~/Library/Application Support/SaidDone/.env`.
    @discardableResult
    static func mergeInto(_ config: inout AppConfig, store: ConfigStore) -> Bool {
        guard let vars = load(), !vars.isEmpty else { return false }
        var changed = false
        if let key = vars["DEEPSEEK_API_KEY"], !key.isEmpty, config.cloud.llmKey.isEmpty {
            config.cloud.llmKey = key
            if let url = vars["DEEPSEEK_BASE_URL"], !url.isEmpty { config.cloud.llmBaseURL = url }
            if let model = vars["DEEPSEEK_MODEL"], !model.isEmpty { config.cloud.llmModel = model }
            changed = true
        }
        if let key = vars["OPENAI_API_KEY"], !key.isEmpty, config.cloud.asrKey.isEmpty {
            config.cloud.asrKey = key
            changed = true
        }
        if changed { try? store.save(config) }
        return changed
    }

    private static func load() -> [String: String]? {
        guard let dir = try? ConfigStore.defaultDirectory() else { return nil }
        let url = dir.appendingPathComponent(".env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var vars: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("#") { continue }
            let parts = s.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            vars[parts[0].trimmingCharacters(in: .whitespaces)] =
                parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return vars.isEmpty ? nil : vars
    }
}
