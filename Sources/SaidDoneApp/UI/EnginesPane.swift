import SaidDoneCore
import SaidDoneEngines
import SwiftUI

/// Which engine hears you and which one writes. Each half is chosen, keyed and tested on its own.
struct EnginesPane: View {
    let root: AppRoot

    var body: some View {
        @Bindable var settings = root.settings
        Form {
            Section(tr("Languages")) {
                Picker(tr("I speak"), selection: $settings.prefs.spokenLanguage) {
                    Text(tr("Detect automatically")).tag(SpokenLanguage.detect)
                    ForEach(Language.spoken) { Text(verbatim: $0.endonym).tag(SpokenLanguage.fixed($0)) }
                }
                Picker(tr("Translate into"), selection: $settings.prefs.translationTarget) {
                    ForEach(Language.translationTargets) { Text(verbatim: $0.endonym).tag($0) }
                }
            }
            SpeechSection(root: root)
            AISection(root: root)
            NetworkSection(settings: settings)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Speech

struct SpeechSection: View {
    let root: AppRoot

    private enum Kind: Hashable { case local, cloud, volcengine }

    var body: some View {
        let prefs = root.settings.prefs
        Section {
            Picker(tr("Engine"), selection: kind) {
                Text(tr("On this Mac")).tag(Kind.local)
                Text(tr("Cloud service")).tag(Kind.cloud)
                Text(tr("Volcengine (Doubao)")).tag(Kind.volcengine)
            }
            switch prefs.speech {
            case let .whisper(chosen):
                ForEach(WhisperModel.allCases, id: \.self) { model in
                    ModelRow(model: .whisper(model), selected: model == chosen, recommended: model == .recommended,
                             note: model == .largeV3TurboCompact ? tr("Smaller and a little less accurate.") : nil,
                             root: root) { root.settings.prefs.speech = .whisper(model) }
                }
            case .cloud:
                CloudFields(presets: CloudPreset.speech, endpoint: endpoint, root: root)
            case let .volcengine(appID):
                KeyField(vault: root.vault, vendor: .volcengine, required: true,
                         keyURL: URL(string: "https://console.volcengine.com/speech/app"))
                TextField(tr("App ID"), text: Binding(get: { appID },
                                                      set: { root.settings.prefs.speech = .volcengine(appID: $0) }),
                          prompt: Text(tr("Only for consoles that issue an App ID and a token")))
            }
            TestButton { () async throws(EngineError) in
                try await root.engines.test(SpeechSetup(prefs.speech, key: prefs.speech.vendor.map(root.vault.key) ?? "",
                                                        proxy: prefs.proxy))
            }
            .id(prefs.speech)
        } header: {
            Text(tr("Speech recognition"))
        } footer: {
            Text(tr("On this Mac is private and free, and works offline. Cloud services need a key and send your audio to them."))
        }
    }

    private var kind: Binding<Kind> {
        Binding {
            switch root.settings.prefs.speech {
            case .whisper: .local
            case .cloud: .cloud
            case .volcengine: .volcengine
            }
        } set: { kind in
            guard kind != self.kind.wrappedValue else { return }
            root.settings.prefs.speech = switch kind {
            case .local: .whisper(WhisperModel.allCases.first { root.library.installed.contains(.whisper($0)) } ?? .recommended)
            case .cloud: .cloud(CloudPreset.speech[0].defaultEndpoint)
            case .volcengine: .volcengine(appID: "")
            }
        }
    }

    private var endpoint: Binding<CloudEndpoint> {
        Binding {
            if case let .cloud(endpoint) = root.settings.prefs.speech { endpoint } else { CloudPreset.speech[0].defaultEndpoint }
        } set: {
            root.settings.prefs.speech = .cloud($0)
        }
    }
}

// MARK: - AI

struct AISection: View {
    let root: AppRoot

    private enum Kind: Hashable { case local, cloud }

    var body: some View {
        let prefs = root.settings.prefs
        Section {
            Picker(tr("Engine"), selection: kind) {
                Text(tr("Cloud service")).tag(Kind.cloud)
                // A build without MLX's shaders offers it only when it is already chosen, and then says why it fails.
                if Engines.canRunOnDeviceAI || prefs.ai.isLocal {
                    Text(tr("On this Mac")).tag(Kind.local)
                }
            }
            if prefs.ai.isLocal, !Engines.canRunOnDeviceAI {
                IssueRow(issue: .onDeviceAIUnavailable, library: root.library) { _ in
                    root.settings.prefs.ai = .cloud(CloudPreset.deepseek.defaultEndpoint)
                }
            }
            switch prefs.ai {
            case let .qwen(chosen):
                ForEach(QwenModel.allCases, id: \.self) { model in
                    ModelRow(model: .qwen(model), selected: model == chosen, recommended: model == .recommended,
                             note: note(model), root: root) { root.settings.prefs.ai = .qwen(model) }
                }
            case .cloud:
                CloudFields(presets: CloudPreset.chat, endpoint: endpoint, root: root)
            }
            TestButton { () async throws(EngineError) in
                try await root.engines.test(AISetup(prefs.ai, key: prefs.ai.vendor.map(root.vault.key) ?? "",
                                                    proxy: prefs.proxy))
            }
            .id(prefs.ai)
        } header: {
            Text(tr("AI"))
        } footer: {
            Text(tr("The AI removes filler words and false starts, fixes punctuation, translates and answers. On this Mac needs Apple silicon and about 3 GB of memory."))
        }
    }

    private func note(_ model: QwenModel) -> String? {
        switch model {
        case .qwen3_4B: nil
        case .qwen3_1_7B: tr("Faster, for Macs with 8 GB of memory. Makes more mistakes.")
        case .qwen3_8B: tr("Most accurate. Needs 16 GB of memory.")
        }
    }

    private var kind: Binding<Kind> {
        Binding {
            root.settings.prefs.ai.isLocal ? .local : .cloud
        } set: { kind in
            guard kind != self.kind.wrappedValue else { return }
            root.settings.prefs.ai = switch kind {
            case .local: .qwen(QwenModel.allCases.first { root.library.installed.contains(.qwen($0)) } ?? .recommended)
            case .cloud: .cloud(CloudPreset.deepseek.defaultEndpoint)
            }
        }
    }

    private var endpoint: Binding<CloudEndpoint> {
        Binding {
            if case let .cloud(endpoint) = root.settings.prefs.ai { endpoint } else { CloudPreset.deepseek.defaultEndpoint }
        } set: {
            root.settings.prefs.ai = .cloud($0)
        }
    }
}

// MARK: - Network

private struct NetworkSection: View {
    @Bindable var settings: SettingsStore
    @State private var host = ""
    @State private var port = ""

    var body: some View {
        Section {
            Toggle(isOn: $settings.prefs.downloadMirror) {
                Text(tr("Download models through hf-mirror.com"))
                Text(tr("Use this where Hugging Face is slow or blocked."))
            }
            Toggle(tr("Use a proxy for cloud services"), isOn: Binding(
                get: { settings.prefs.proxy != nil },
                set: { settings.prefs.proxy = $0 ? Proxy(host: "127.0.0.1", port: 7890) : nil }))
            if let proxy = settings.prefs.proxy {
                HStack {
                    TextField(tr("Host"), text: $host)
                    TextField(tr("Port"), text: $port).frame(width: 110)
                }
                .onAppear {
                    host = proxy.host
                    port = String(proxy.port)
                }
                .onChange(of: host) { commit() }
                .onChange(of: port) { commit() }
            }
        } header: {
            Text(tr("Network"))
        } footer: {
            Text(tr("An HTTP proxy, such as the one your VPN app runs on this Mac."))
        }
    }

    private func commit() {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let number = Int(port), (1...65_535).contains(number) else { return }
        settings.prefs.proxy = Proxy(host: trimmed, port: number)
    }
}

// MARK: - Shared rows

/// An on-device model: choose it, download it, remove it.
private struct ModelRow: View {
    let model: LocalModel
    let selected: Bool
    let recommended: Bool
    let note: String?
    let root: AppRoot
    let select: () -> Void

    private var library: ModelLibrary { root.library }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: model.name)
                    if recommended {
                        Text(tr("Recommended"))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Text(verbatim: [model.approximateBytes.fileSize, note].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let failure = library.failures[model] {
                    Text(verbatim: failure.message).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            status
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .controlSize(.small)
    }

    @ViewBuilder private var status: some View {
        if library.installed.contains(model) {
            Label(tr("Downloaded"), systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.green)
            if !selected {
                Button(tr("Remove")) { library.remove(model) }
            }
        } else if let progress = library.progress[model] {
            ProgressView(value: progress).frame(width: 90)
            Text(verbatim: progress.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
            Button(tr("Cancel")) { library.cancel(model) }
        } else {
            Button(tr("Download")) {
                library.download(model, mirror: root.settings.prefs.downloadMirror)
                select()
            }
        }
    }
}

/// An OpenAI-compatible service: which one, its key, and the model to use.
private struct CloudFields: View {
    let presets: [CloudPreset]
    @Binding var endpoint: CloudEndpoint
    let root: AppRoot
    @State private var baseURL = ""
    @State private var fetched: [String] = []
    @State private var fetchFailure: String?
    @State private var fetching = false

    private var preset: CloudPreset? { presets.first { $0.id == endpoint.vendor } }
    private var isCustom: Bool { endpoint.vendor == .customChat || endpoint.vendor == .customSpeech }
    private var suggestions: [String] {
        var seen: Set<String> = []
        return ((preset?.models ?? []) + fetched).filter { seen.insert($0).inserted }
    }

    var body: some View {
        Picker(tr("Service"), selection: Binding(get: { endpoint.vendor }, set: { vendor in
            guard vendor != endpoint.vendor, let preset = presets.first(where: { $0.id == vendor }) else { return }
            endpoint = preset.defaultEndpoint
            baseURL = preset.baseURL.absoluteString
            fetched = []
            fetchFailure = nil
        })) {
            ForEach(presets) { Text(verbatim: $0.name).tag($0.id) }
        }
        if isCustom {
            TextField(tr("Base URL"), text: $baseURL, prompt: Text(verbatim: "https://api.example.com/v1"))
                .onAppear { baseURL = endpoint.baseURL.absoluteString }
                .onChange(of: baseURL) { _, text in
                    if let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.host != nil,
                       ["http", "https"].contains(url.scheme) {
                        endpoint.baseURL = url
                    }
                }
        }
        KeyField(vault: root.vault, vendor: endpoint.vendor, required: preset?.requiresKey ?? true, keyURL: preset?.keyURL)
        LabeledContent(tr("Model")) {
            HStack(spacing: 6) {
                TextField(tr("Model"), text: $endpoint.model, prompt: Text(tr("Model name")))
                    .labelsHidden()
                Menu {
                    ForEach(suggestions, id: \.self) { name in Button(name) { endpoint.model = name } }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(suggestions.isEmpty)
                .help(tr("Suggested models"))
                Button(fetching ? tr("Loading…") : tr("Load List"), action: fetch)
                    .disabled(fetching)
            }
        }
        if let fetchFailure {
            Text(verbatim: fetchFailure).font(.caption).foregroundStyle(.orange)
        }
    }

    private func fetch() {
        fetching = true
        fetchFailure = nil
        let endpoint = endpoint
        let key = root.vault.key(endpoint.vendor)
        let proxy = root.settings.prefs.proxy
        Task {
            defer { fetching = false }
            do throws(EngineError) {
                fetched = try await root.engines.models(at: endpoint, key: key, proxy: proxy)
                if fetched.isEmpty { fetchFailure = tr("The service listed no models.") }
            } catch {
                fetchFailure = Failure(error).message
            }
        }
    }
}

/// A vendor's API key, kept in the Keychain. One key per vendor serves both speech and AI.
private struct KeyField: View {
    let vault: Vault
    let vendor: VendorID
    let required: Bool
    let keyURL: URL?

    var body: some View {
        LabeledContent(required ? tr("API key") : tr("API key (optional)")) {
            HStack(spacing: 8) {
                SecureField(tr("API key"), text: Binding(get: { vault.key(vendor) }, set: { vault.setKey($0, for: vendor) }),
                            prompt: Text(tr("Paste your key")))
                    .labelsHidden()
                    .disabled(vault.state == .loading)
                if let keyURL {
                    Link(tr("Get a Key"), destination: keyURL).font(.callout)
                }
            }
        }
        if case .unavailable = vault.state {
            Text(tr("The Keychain can’t be read. Keys you enter are kept until SaidDone quits."))
                .font(.caption).foregroundStyle(.orange)
        } else if vault.saveFailure != nil {
            Text(tr("The key couldn’t be saved to the Keychain."))
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

/// Runs the engine once for real and says whether it worked.
private struct TestButton: View {
    let test: () async throws(EngineError) -> Void
    @State private var state = TestState.idle

    private enum TestState: Equatable {
        case idle, running, passed
        case failed(String)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(tr("Test")) {
                state = .running
                Task {
                    do throws(EngineError) {
                        try await test()
                        state = .passed
                    } catch {
                        state = .failed(Failure(error).message)
                    }
                }
            }
            .disabled(state == .running)
            switch state {
            case .idle:
                EmptyView()
            case .running:
                ProgressView().controlSize(.small)
                Text(tr("Testing…")).foregroundStyle(.secondary)
            case .passed:
                Label(tr("Works"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case let .failed(message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
        .font(.callout)
    }
}
