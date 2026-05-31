import SwiftUI
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
}

/// Minimal v1 Settings: target language, provider location/model, Custom Dictionary, App Profiles.
struct SettingsView: View {
    @ObservedObject var model: ConfigModel

    var body: some View {
        TabView {
            general.tabItem { Text("General") }
            providers.tabItem { Text("Providers") }
            dictionary.tabItem { Text("Dictionary") }
            profiles.tabItem { Text("App Profiles") }
        }
        .frame(width: 460, height: 380)
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
            Text("Dictation: ⌥Space · Translation: ⌥⇧Space")
                .font(.caption).foregroundStyle(.secondary)
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
            TextField("LLM model", text: $model.config.llm.modelID)
            Text("Local = private/offline/zero-key. Cloud = opt-in, data leaves device.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }

    private var dictionary: some View {
        VStack(alignment: .leading) {
            List {
                ForEach($model.config.dictionary.entries, id: \.wrong) { $entry in
                    HStack {
                        TextField("heard", text: $entry.wrong)
                        Image(systemName: "arrow.right")
                        TextField("correct", text: $entry.right)
                    }
                }
                .onDelete { model.config.dictionary.entries.remove(atOffsets: $0) }
            }
            Button("Add term") {
                model.config.dictionary.entries.append(.init(wrong: "", right: ""))
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
