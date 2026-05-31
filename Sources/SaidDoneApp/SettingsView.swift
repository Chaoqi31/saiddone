import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SaidDoneCore

/// Editable view-model over AppConfig. `onSave` persists + lets the controller rebuild providers.
@MainActor
final class ConfigModel: ObservableObject {
    @Published var config: AppConfig
    let onSave: (AppConfig) -> Void

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        self.config = config
        self.onSave = onSave
    }

    func save() { onSave(config) }

    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "saiddone-config.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(config).write(to: url)
    }

    func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else { return }
        config = cfg
        save()
    }

    func exportDictionary() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "saiddone-dictionary.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(config.dictionary.entries).write(to: url)
    }

    func importDictionary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([DictionaryEntry].self, from: data) else { return }
        // Merge, de-duplicating by `wrong`.
        var byKey = Dictionary(config.dictionary.entries.map { ($0.wrong, $0) }) { a, _ in a }
        for e in entries { byKey[e.wrong] = e }
        config.dictionary.entries = byKey.values.sorted { $0.wrong < $1.wrong }
        save()
    }
}

/// Minimal v1 Settings: target language, provider location/model, Custom Dictionary, App Profiles.
struct SettingsView: View {
    @ObservedObject var model: ConfigModel
    @ObservedObject var setup: SetupModel

    var body: some View {
        TabView {
            general.tabItem { Text("General") }
            providers.tabItem { Text("Providers") }
            cloud.tabItem { Text("Cloud") }
            profiles.tabItem { Text("App Profiles") }
            SetupView(model: setup).tabItem { Text("Setup") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 4)
        .onDisappear { model.save() }
    }

    private var general: some View {
        Form {
            Picker("Primary spoken language", selection: Binding(
                get: { model.config.asrLanguage ?? "auto" },
                set: { model.config.asrLanguage = ($0 == "auto") ? nil : $0 }
            )) {
                Text("Chinese (中文)").tag("zh")
                Text("English").tag("en")
                Text("Auto-detect").tag("auto")
            }
            Text("Match your main language. Auto-detect is unreliable for zh-en code-switching.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            TextField("Translation target language", text: $model.config.targetLanguage)
            Divider()
            HotkeyRecorder(label: "Dictation shortcut", hotkey: $model.config.dictationHotkey)
            HotkeyRecorder(label: "Translation shortcut", hotkey: $model.config.translationHotkey)
            HotkeyRecorder(label: "Rewrite shortcut", hotkey: $model.config.rewriteHotkey)
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text("Personalization").font(.subheadline.weight(.medium))
                Text("Tell the AI who you are — it tailors polishing to your jargon & code-switching (like ChatGPT custom instructions).")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.config.userProfile).font(.callout).frame(height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            }
            Divider()
            Toggle("Launch at login", isOn: $model.config.launchAtLogin)
            Toggle("Keep result on clipboard (auto-copy)", isOn: $model.config.autoCopyToClipboard)
            Toggle("Recording sounds", isOn: $model.config.soundsEnabled)
            Toggle("Mute system audio while recording", isOn: $model.config.muteAudioWhileRecording)
            Toggle("Voice commands (say \"换行\"/\"new line\" to break lines)", isOn: $model.config.voiceCommandsEnabled)
            Toggle("Show live transcription preview while recording", isOn: $model.config.showLivePreview)
            Divider()
            HStack {
                Button("Export Settings…") { model.export() }
                Button("Import Settings…") { model.importConfig() }
            }
        }.padding()
    }

    private var providers: some View {
        Form {
            Picker("ASR location", selection: $model.config.asr.location) {
                ForEach(ProviderLocation.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            TextField("ASR model", text: $model.config.asr.modelID)
            Divider()
            Picker("LLM location", selection: $model.config.llm.location) {
                ForEach(ProviderLocation.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Picker("Local LLM model", selection: $model.config.llm.modelID) {
                Text("Qwen3 0.6B — fastest").tag("mlx-community/Qwen3-0.6B-4bit")
                Text("Qwen3 1.7B — default").tag("mlx-community/Qwen3-1.7B-4bit")
                Text("Qwen3 4B — better punctuation").tag("mlx-community/Qwen3-4B-4bit")
                Text("Qwen3 8B — best, heavy").tag("mlx-community/Qwen3-8B-4bit")
                Text("Rule-based only — no model").tag("rule-based")
            }
            Text("Bigger = better polish/punctuation, more RAM. New model must be downloaded first (Setup tab / get-models.sh). Local = private/offline/zero-key; Cloud = opt-in, data leaves device.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }

    private var cloud: some View {
        Form {
            Text("Opt-in. Keys saved in config.json; audio/text leaves the device. Set a provider's location to Cloud (Providers tab) to use these.")
                .font(.caption).foregroundStyle(.secondary)
            Section("LLM — polish / translate") {
                SecureField("API key", text: $model.config.cloud.llmKey)
                TextField("Base URL", text: $model.config.cloud.llmBaseURL)
                TextField("Model", text: $model.config.cloud.llmModel)
            }
            Section("ASR — speech (OpenAI-compatible)") {
                SecureField("API key", text: $model.config.cloud.asrKey)
                TextField("Base URL", text: $model.config.cloud.asrBaseURL)
                TextField("Model", text: $model.config.cloud.asrModel)
            }
            Section("Proxy (optional, for cloud calls)") {
                TextField("Host", text: $model.config.cloud.proxyHost)
                TextField("Port", value: $model.config.cloud.proxyPort, format: .number)
            }
        }.padding()
    }


    private var profiles: some View {
        VStack(alignment: .leading) {
            List {
                ForEach($model.config.appProfiles.profiles) { $p in
                    VStack(alignment: .leading) {
                        TextField("bundle id (blank = any)", text: Binding(
                            get: { p.bundleID ?? "" },
                            set: { p.bundleID = $0.isEmpty ? nil : $0 }
                        ))
                        TextField("tone prompt", text: $p.tonePrompt)
                    }
                }
                .onDelete { model.config.appProfiles.profiles.remove(atOffsets: $0) }
            }
            Button("Add profile") {
                model.config.appProfiles.profiles.append(.init(bundleID: nil, tonePrompt: ""))
            }
        }.padding()
    }
}
