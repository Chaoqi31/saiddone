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
        .onDisappear { model.save() }
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                Picker("Primary spoken language", selection: Binding(
                    get: { model.config.asrLanguage ?? "" },
                    set: { model.config.asrLanguage = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(Languages.spokenLanguages, id: \.code) { Text($0.name).tag($0.code) }
                }
                Picker("Translation target", selection: $model.config.targetLanguage) {
                    ForEach(Languages.translationTargets, id: \.code) { Text($0.name).tag($0.code) }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Match your main spoken language — auto-detect is unreliable for zh-en code-switching.")
            }

            Section("Shortcuts") {
                HotkeyRecorder(label: "Dictation", hotkey: $model.config.dictationHotkey)
                HotkeyRecorder(label: "Translation", hotkey: $model.config.translationHotkey)
                HotkeyRecorder(label: "Rewrite", hotkey: $model.config.rewriteHotkey)
            }

            Section {
                TextEditor(text: $model.config.userProfile)
                    .font(.callout).frame(height: 72)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            } header: {
                Text("Personalization")
            } footer: {
                Text("Tell the AI who you are — it tailors polishing to your role, jargon, and code-switching (like ChatGPT custom instructions).")
            }

            Section("Behavior") {
                Toggle("Launch at login", isOn: $model.config.launchAtLogin)
                Toggle("Keep result on clipboard after inserting", isOn: $model.config.autoCopyToClipboard)
                Toggle("Play recording sounds", isOn: $model.config.soundsEnabled)
                Toggle("Mute system audio while recording", isOn: $model.config.muteAudioWhileRecording)
                Toggle("Record from built-in mic (keep Bluetooth audio in hi-fi)", isOn: $model.config.preferBuiltInMic)
                Toggle("Voice commands (say “换行” / “new line” to break lines)", isOn: $model.config.voiceCommandsEnabled)
                Toggle("Show live transcription preview while recording", isOn: $model.config.showLivePreview)
                HStack {
                    Text("AI step timeout")
                    Spacer()
                    Stepper(value: $model.config.llmTimeoutSeconds, in: 0...60, step: 1) {
                        Text(model.config.llmTimeoutSeconds <= 0
                             ? NSLocalizedString("Off", comment: "timeout off")
                             : String(format: NSLocalizedString("%.0fs", comment: "timeout seconds"),
                                      model.config.llmTimeoutSeconds))
                            .monospacedDigit().frame(minWidth: 32, alignment: .trailing)
                    }
                }
                .help("If polishing takes longer than this, insert the raw transcript instead of waiting. 0 = wait forever.")
            }

            Section {
                HStack {
                    Button("Export Settings…") { model.export() }
                    Button("Import Settings…") { model.importConfig() }
                    Spacer()
                }
            } footer: {
                Text("Export / import your configuration as JSON. Cloud API keys stay in Keychain and are omitted from exports.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Providers

    private var providers: some View {
        Form {
            Section {
                Picker("Run on", selection: $model.config.asr.location) {
                    ForEach(ProviderLocation.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue.capitalized)).tag($0) }
                }
                if model.config.asr.location == .local {
                    Picker("Local model", selection: Binding(
                        get: { model.config.asr.modelID.lowercased().contains("whisper")
                               ? model.config.asr.modelID : "openai_whisper-large-v3" },
                        set: { model.config.asr.modelID = $0 }
                    )) {
                        Text("Whisper large-v3 — recommended, most accurate").tag("openai_whisper-large-v3")
                        Text("Whisper large-v3 turbo — faster, lighter").tag("openai_whisper-large-v3-v20240930_turbo")
                    }
                    readinessRow(present: asrPresent(), progress: setup.downloadProgress) {
                        model.save(); setup.downloadASR()
                    }
                } else {
                    LabeledContent("Model", value: cloudOrDash(model.config.cloud.asrModel))
                }
            } header: {
                Text("Speech recognition (ASR)")
            } footer: {
                Text(model.config.asr.location == .local
                     ? "Runs fully offline on-device. large-v3 is more accurate but slower and heavier; a newly-picked model downloads on first use (Setup tab)."
                     : "Uses the OpenAI-compatible endpoint and key from the Cloud tab — audio leaves your device. Good Chinese engines: SiliconFlow SenseVoice or OpenAI gpt-4o-transcribe.")
            }

            Section {
                Picker("Run on", selection: $model.config.llm.location) {
                    ForEach(ProviderLocation.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue.capitalized)).tag($0) }
                }
                if model.config.llm.location == .local {
                    Picker("Local model", selection: $model.config.llm.modelID) {
                        Text("Qwen3 0.6B — fastest").tag("mlx-community/Qwen3-0.6B-4bit")
                        Text("Qwen3 1.7B — faster").tag("mlx-community/Qwen3-1.7B-4bit")
                        Text("Qwen3 4B — default, best Chinese").tag("mlx-community/Qwen3-4B-4bit")
                        Text("Qwen3 8B — best, heavy").tag("mlx-community/Qwen3-8B-4bit")
                    }
                    readinessRow(present: llmPresent(), progress: setup.llmDownloadProgress) {
                        model.save(); setup.downloadLLM()
                    }
                } else {
                    LabeledContent("Model", value: cloudOrDash(model.config.cloud.llmModel))
                }
            } header: {
                Text("Language model — polish · translate · rewrite")
            } footer: {
                Text(model.config.llm.location == .local
                     ? "Bigger model → better punctuation & structuring, more RAM. Download in the Setup tab. Fully offline, zero-key."
                     : "Uses the OpenAI-compatible endpoint and key from the Cloud tab — text leaves your device.")
            }
        }
        .formStyle(.grouped)
    }

    /// Cloud value, or a hint pointing at the Cloud tab when unset.
    private func cloudOrDash(_ s: String) -> String {
        s.isEmpty ? NSLocalizedString("— set in Cloud tab", comment: "providers cloud model unset") : s
    }

    /// Whether the currently-selected local models are present on disk (checked live, per exact model).
    private func asrPresent() -> Bool {
        let dir = SetupModel.modelsRoot.appendingPathComponent("argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model.config.asr.modelID)
        return SetupModel.dirNonEmpty(dir)
    }
    private func llmPresent() -> Bool {
        let cfg = SetupModel.modelsRoot.appendingPathComponent(model.config.llm.modelID)
            .appendingPathComponent("config.json")
        return FileManager.default.fileExists(atPath: cfg.path)
    }

    /// Inline download status for a local model: ready ✓, in-progress, or a Download button.
    @ViewBuilder
    private func readinessRow(present: Bool, progress: Double?, download: @escaping () -> Void) -> some View {
        if present {
            Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        } else if let progress {
            HStack {
                ProgressView(value: progress).frame(width: 160)
                Text("Downloading…").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack {
                Label("Not downloaded", systemImage: "arrow.down.circle").foregroundStyle(.orange).font(.callout)
                Spacer()
                Button("Download", action: download)
            }
        }
    }

    // MARK: Cloud

    private var cloud: some View {
        Form {
            Section {
                Label("Keys are saved in config.json and audio/text leaves your device. Pick Cloud for a stage in the Providers tab to use these.",
                      systemImage: "lock.open")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("LLM — polish / translate / rewrite") {
                SecureField("API key", text: $model.config.cloud.llmKey)
                TextField("Base URL", text: $model.config.cloud.llmBaseURL)
                TextField("Model", text: $model.config.cloud.llmModel)
            }
            Section("ASR — speech (OpenAI-compatible)") {
                SecureField("API key", text: $model.config.cloud.asrKey)
                TextField("Base URL", text: $model.config.cloud.asrBaseURL)
                TextField("Model", text: $model.config.cloud.asrModel)
            }
            Section {
                TextField("Host", text: $model.config.cloud.proxyHost)
                TextField("Port", value: $model.config.cloud.proxyPort, format: .number)
            } header: {
                Text("Proxy (optional)")
            } footer: {
                Text("Route cloud calls through an HTTP proxy. Leave blank for none.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: App Profiles

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("App profiles").font(.title3.bold())
                Text("Give the AI a per-app tone — e.g. formal in Mail, terse in Slack. A profile with a matching bundle id wins; a blank bundle id applies everywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach($model.config.appProfiles.profiles) { $p in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Bundle id (blank = any app)", text: Binding(
                            get: { p.bundleID ?? "" },
                            set: { p.bundleID = $0.isEmpty ? nil : $0 }
                        )).font(.callout)
                        TextField("Tone prompt — e.g. “formal, no emoji”", text: $p.tonePrompt).font(.callout)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { model.config.appProfiles.profiles.remove(atOffsets: $0) }
            }
            .overlay { if model.config.appProfiles.profiles.isEmpty {
                ContentUnavailableView("No profiles", systemImage: "macwindow",
                                       description: Text("Add one to tune the tone per app."))
            } }
            Button { model.config.appProfiles.profiles.append(.init(bundleID: nil, tonePrompt: "")) }
                label: { Label("Add profile", systemImage: "plus") }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
