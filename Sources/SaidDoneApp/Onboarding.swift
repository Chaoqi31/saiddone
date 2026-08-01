import SwiftUI
import AppKit
import SaidDoneCore
import SaidDoneProviders

/// First-run wizard model. Owns the *draft* engine choice and provisioning state; the actual IO
/// (permissions, downloads, cloud test, applying config, try-it capture) is injected by AppController.
@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case language, welcome, permissions, engines, provision, tryIt, done
    }

    @Published var step: Step = .language

    // UI language ("en" / "zh-Hans"); applied live via onSetLanguage.
    @Published var appLanguage = "en"
    private(set) var languageWasChosen = false

    // Permissions
    @Published var micGranted = false
    @Published var micDenied = false
    @Published var micRestricted = false
    @Published var axGranted = false

    // Engine choice (draft). Defaults = cloud for both stages — better accuracy and much stronger
    // ASR-mishearing / term-correction quality than the on-device models (see ADR-0007). The
    // all-local, zero-key path is still fully supported; users pick it explicitly on this step.
    @Published var asrLocal = false
    @Published var asrModelID = "openai_whisper-large-v3-v20240930_turbo"
    @Published var llmLocal = false
    @Published var llmModelID = "mlx-community/Qwen3-4B-4bit"
    @Published var cloud = CloudConfig()
    @Published var hfMirror = false
    @Published var launchAtLogin = false

    // Shortcuts (rebindable on the final step).
    @Published var dictationHotkey = AppConfig.default.dictationHotkey
    @Published var translationHotkey = AppConfig.default.translationHotkey
    @Published var askHotkey = AppConfig.default.askHotkey

    // Provisioning
    @Published var asrReady = false
    @Published var llmReady = false
    @Published var asrProgress: Double?
    @Published var llmProgress: Double?
    @Published var cloudLLMOK: Bool?
    @Published var cloudASROK: Bool?
    @Published var cloudTesting = false
    @Published var warming = false       // first-run model load (a 4B model can take a minute)
    @Published var tryBusy = false       // try-it transcription in flight
    @Published var status = ""

    // Try-it
    @Published var tryMode = 0          // 0 = dictation, 1 = translation → English
    @Published var tryRecording = false
    @Published var tryResult = ""

    /// "" = huggingface.co; the China mirror when the user opts in.
    var endpoint: String { hfMirror ? "https://hf-mirror.com" : "" }

    // Injected by AppController:
    var requestMic: (() async -> Bool)?
    var downloadWhisper: ((String, String, @escaping @Sendable (Double) -> Void) async throws -> Void)?
    var downloadLLM: ((String, String, @escaping @Sendable (Double) -> Void) async throws -> Void)?
    var testCloud: ((_ baseURL: String, _ key: String) async -> Bool)?
    var applyDraft: (() -> Void)?       // write the draft engine choice into the live config + rebuild providers
    var onSetLanguage: ((String) -> Void)?  // switch the UI language live
    var warmUp: (() async -> Void)?     // load the chosen models into memory (first-run cold load)
    var tryToggle: (() async -> Void)?  // start / stop a test capture; writes tryRecording + tryResult
    var finishWizard: (() -> Void)?     // mark complete, persist, close wizard, open main window

    static let asrModels: [(LocalizedStringKey, String)] = [
        ("Whisper large-v3-turbo — recommended (fast, ~1.5 GB)", "openai_whisper-large-v3-v20240930_turbo"),
        ("Whisper large-v3 — most accurate, slower (~3 GB)", "openai_whisper-large-v3"),
    ]
    static let llmModels: [(LocalizedStringKey, String)] = [
        ("Qwen3 0.6B — fastest", "mlx-community/Qwen3-0.6B-4bit"),
        ("Qwen3 1.7B — faster", "mlx-community/Qwen3-1.7B-4bit"),
        ("Qwen3 4B — recommended, best Chinese (~2.3 GB)", "mlx-community/Qwen3-4B-4bit"),
        ("Qwen3 8B — best, heavy", "mlx-community/Qwen3-8B-4bit"),
    ]

    // MARK: derived gates

    var canLeavePermissions: Bool { micGranted }   // AX is optional (text still saved to History without it)
    var canFinishProvision: Bool {
        let asrOK = asrLocal ? asrReady : (cloudASROK == true)
        let llmOK = llmLocal ? llmReady : (cloudLLMOK == true)
        return asrOK && llmOK
    }
    var isDownloading: Bool { asrProgress != nil || llmProgress != nil }
    var working: Bool { isDownloading || cloudTesting || warming }
    var anyLocal: Bool { asrLocal || llmLocal }
    var modelsPath: String {
        "Speech: \(ModelStorage.whisperCanonicalBase.path(percentEncoded: false)) · "
            + "AI: \(ModelStorage.mlxModelsRoot.path(percentEncoded: false))"
    }

    func refreshPermissions() {
        micGranted = Permissions.microphoneAuthorized()
        micDenied = Permissions.microphoneDenied()
        micRestricted = Permissions.microphoneRestricted()
        axGranted = Permissions.accessibilityTrusted(prompt: false)
    }

    func refreshModelReadiness() {
        asrReady = ModelStorage.isWhisperReady(modelID: asrModelID)
        llmReady = ModelStorage.isMLXReady(modelID: llmModelID)
    }

    /// Seed a reopened assistant from the live config so finishing it cannot overwrite Settings
    /// with stale wizard defaults. The effective language remains selected visually while the raw
    /// empty override ("follow system") is preserved unless the user chooses a language here.
    func loadDraft(from config: AppConfig, effectiveLanguage: String) {
        appLanguage = config.appLanguage.isEmpty ? effectiveLanguage : config.appLanguage
        languageWasChosen = false
        asrLocal = config.asr.location == .local
        asrModelID = config.asr.modelID
        llmLocal = config.llm.location == .local
        llmModelID = config.llm.modelID
        cloud = config.cloud
        hfMirror = !config.huggingFaceEndpoint.isEmpty
        launchAtLogin = config.launchAtLogin
        dictationHotkey = config.dictationHotkey
        translationHotkey = config.translationHotkey
        askHotkey = config.askHotkey
        cloudLLMOK = nil
        cloudASROK = nil
        status = ""
    }

    // MARK: actions (called by the view)

    func chooseLanguage(_ code: String) {
        appLanguage = code
        languageWasChosen = true
        onSetLanguage?(code)
    }

    func appLanguageOverride(preserving current: String, onboardingCompleted: Bool) -> String {
        (!onboardingCompleted || languageWasChosen) ? appLanguage : current
    }

    func grantMic() {
        if micRestricted {
            return
        } else if micDenied {
            openMicSettings()
        } else {
            Task { _ = await requestMic?(); refreshPermissions() }
        }
    }
    func openMicSettings() { Self.openPrivacy("Privacy_Microphone") }
    func openAXSettings() {
        _ = Permissions.accessibilityTrusted(prompt: true)   // also nudges the system prompt
        Self.openPrivacy("Privacy_Accessibility")
    }

    // Downloads are independent (progress != nil means in-flight), so ASR and LLM run in parallel.
    func downloadASRModel() {
        guard let downloadWhisper, asrProgress == nil else { return }
        asrProgress = 0; status = ""
        Task {
            do { try await downloadWhisper(asrModelID, endpoint) { p in Task { @MainActor in self.asrProgress = p } } }
            catch { status = Self.downloadError }
            asrProgress = nil; refreshModelReadiness()
        }
    }

    func downloadLLMModel() {
        guard let downloadLLM, llmProgress == nil else { return }
        llmProgress = 0; status = ""
        Task {
            do { try await downloadLLM(llmModelID, endpoint) { p in Task { @MainActor in self.llmProgress = p } } }
            catch { status = Self.downloadError }
            llmProgress = nil; refreshModelReadiness()
        }
    }

    func testCloudLLM() {
        guard let testCloud, !cloudTesting else { return }
        cloudTesting = true; cloudLLMOK = nil
        let key = cloud.llmAPIKeys[cloud.llmProviderID] ?? ""
        Task { cloudLLMOK = await testCloud(cloud.llmBaseURL, key); cloudTesting = false }
    }
    func testCloudASR() {
        guard let testCloud, !cloudTesting else { return }
        cloudTesting = true; cloudASROK = nil
        Task { cloudASROK = await testCloud(cloud.asrBaseURL, cloud.asrKey); cloudTesting = false }
    }

    func prefillDeepSeek() {
        cloud.llmProviderID = "deepseek"
        cloud.llmBaseURL = "https://api.deepseek.com/v1"
        cloud.llmModel = "deepseek-chat"
        cloudLLMOK = nil
    }

    func revealModelsFolder() {
        for root in [ModelStorage.whisperCanonicalBase, ModelStorage.mlxModelsRoot] {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(root)
        }
    }

    func toggleTry() { guard !warming else { return }; Task { await tryToggle?() } }

    func next() {
        guard let nextStep = Step(rawValue: step.rawValue + 1) else { return }
        // Entering provision: re-check what's already on disk so finished items show as ready.
        if nextStep == .provision { refreshModelReadiness() }
        // Leaving provision into try-it: commit the engine choice, then warm the models so the Try-it
        // step (and the first real use) isn't a silent multi-second/​minute cold-load that looks frozen.
        if step == .provision {
            applyDraft?()
            if anyLocal, let warmUp {
                warming = true
                Task { await warmUp(); warming = false }
            }
        }
        step = nextStep
    }
    func back() {
        guard let prevStep = Step(rawValue: step.rawValue - 1) else { return }
        step = prevStep
    }

    static let downloadError = NSLocalizedString(
        "Download failed — check your network. On a mainland China network, enable the mirror below.",
        comment: "onboarding download error")

    private static func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - View

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            ProgressDots(current: model.step.rawValue, total: OnboardingModel.Step.allCases.count)
                .padding(.top, 18)
            Divider().padding(.top, 14)
            ScrollView {
                content
                    .padding(28).frame(maxWidth: .infinity, alignment: .leading)
                    .id(model.step)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity))
            }
            .animation(.smooth(duration: 0.3), value: model.step)
            Divider()
            footer.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 720, height: 560)
        .onAppear { model.refreshPermissions(); model.refreshModelReadiness() }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .language: LanguageStep(model: model)
        case .welcome: WelcomeStep()
        case .permissions: PermissionsStep(model: model)
        case .engines: EnginesStep(model: model)
        case .provision: ProvisionStep(model: model)
        case .tryIt: TryItStep(model: model)
        case .done: DoneStep(model: model)
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if model.step != .language {
                Button("Back") { model.back() }.disabled(model.working)
            }
            Spacer()
            if model.working { ProgressView().controlSize(.small).padding(.trailing, 6) }
            switch model.step {
            case .language:
                Button("Continue") { model.next() }.keyboardShortcut(.defaultAction)
            case .welcome:
                Button("Get Started") { model.next() }.keyboardShortcut(.defaultAction)
            case .permissions:
                Button("Continue") { model.next() }
                    .keyboardShortcut(.defaultAction).disabled(!model.canLeavePermissions)
            case .engines:
                Button("Continue") { model.next() }.keyboardShortcut(.defaultAction)
            case .provision:
                Button("Continue") { model.next() }
                    .keyboardShortcut(.defaultAction).disabled(!model.canFinishProvision || model.working)
            case .tryIt:
                Button("Skip") { model.next() }
                Button("Continue") { model.next() }.keyboardShortcut(.defaultAction)
            case .done:
                Button("Start Using SaidDone") { model.finishWizard?() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct ProgressDots: View {
    let current: Int; let total: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: i == current ? 22 : 8, height: 8)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup progress")
        .accessibilityValue(String(
            format: NSLocalizedString("Step %lld of %lld", comment: "onboarding progress"),
            Int64(current + 1), Int64(total)))
    }
}

private struct LanguageStep: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BrandMark(size: 56)
            Text("Choose your language").font(.largeTitle.bold())
            Text("You can change this later in Settings.").foregroundStyle(.secondary)
            HStack(spacing: 14) {
                ForEach(Languages.ui, id: \.code) { lang in
                    languageCard(code: lang.code, name: lang.name)
                }
            }
            Spacer()
        }
    }
    private func languageCard(code: String, name: String) -> some View {
        let selected = model.appLanguage == code
        return Button { model.chooseLanguage(code) } label: {
            HStack {
                Text(name).font(.title3.weight(.medium))
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BrandMark(size: 64)
            Text("Welcome to SaidDone").font(.largeTitle.bold())
            Text("Speak. AI polishes what you said. It lands at your cursor — in any app.")
                .font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                bullet("mic.fill", "Press a hotkey once to start, speak, then press it again to stop and insert.")
                bullet("sparkles", "Cloud models by default for the best accuracy — or fully on-device, zero-key and private, if you prefer.")
                bullet("desktopcomputer", "Requires Apple Silicon · macOS 14+.")
            }.padding(.top, 6)
            Text("This quick setup grants permissions, picks your engines, and downloads what's needed.")
                .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
        }
    }
    private func bullet(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(.tint) }
    }
}

private struct PermissionsStep: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader("Grant permissions", "SaidDone needs two macOS permissions to work.")
            permRow(
                title: "Microphone", granted: model.micGranted,
                why: "To hear your speech. Audio is processed for transcription only.",
                action: { model.grantMic() },
                actionLabel: microphoneActionLabel)
            permRow(
                title: "Accessibility", granted: model.axGranted,
                why: "To paste the result into the app you're typing in. Without it, results are still saved to History — they just won't auto-insert.",
                action: { model.openAXSettings() }, actionLabel: "Open Settings…")
            if !model.micGranted {
                if model.micRestricted {
                    Text("Microphone access is restricted by system policy. Contact your administrator to allow SaidDone.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.micDenied {
                    Text("Microphone access was denied. Enable SaidDone in System Settings → Privacy & Security → Microphone, then click Re-check.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Microphone is required to continue. Click Allow Microphone to grant access.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Re-check") { model.refreshPermissions() }.controlSize(.small)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }
    private var microphoneActionLabel: LocalizedStringKey? {
        if model.micRestricted { return nil }
        return model.micDenied ? "Open Microphone Settings…" : "Allow Microphone"
    }
    private func permRow(title: LocalizedStringKey, granted: Bool, why: LocalizedStringKey,
                         action: @escaping () -> Void, actionLabel: LocalizedStringKey?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2).foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted, let actionLabel { Button(actionLabel, action: action) }
        }
        .padding(12).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct EnginesStep: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader("Choose your engines", "Cloud is recommended for best quality. No API keys? Switch both stages to Local for a fully offline setup.")
            engineCard(
                title: "Speech → text", symbol: "waveform",
                isLocal: $model.asrLocal, modelID: $model.asrModelID, models: OnboardingModel.asrModels)
            engineCard(
                title: "AI polish", symbol: "sparkles",
                isLocal: $model.llmLocal, modelID: $model.llmModelID, models: OnboardingModel.llmModels)
            Label("On-device models are smaller and can mishear technical terms or mixed-language speech more often. Cloud gives the most reliable results.",
                  systemImage: "lightbulb")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func engineCard(title: LocalizedStringKey, symbol: String,
                            isLocal: Binding<Bool>, modelID: Binding<String>,
                            models: [(LocalizedStringKey, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            Picker("", selection: isLocal) {
                Text("Cloud (API key)").tag(false)
                Text("Local (on-device)").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if isLocal.wrappedValue {
                Picker("Model", selection: modelID) {
                    ForEach(models, id: \.1) { Text($0.0).tag($0.1) }
                }
            } else {
                Text("You'll enter your API key on the next step.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct ProvisionStep: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader("Set up your engines", "Download local models or connect your cloud account.")

            // ASR
            if model.asrLocal {
                localBlock(title: "Speech model", ready: model.asrReady, progress: model.asrProgress,
                           download: { model.downloadASRModel() })
            } else {
                cloudBlock(title: "Speech (cloud)", key: $model.cloud.asrKey, baseURL: $model.cloud.asrBaseURL,
                           cloudModel: $model.cloud.asrModel, ok: model.cloudASROK, test: { model.testCloudASR() },
                           deepSeek: nil)
            }
            // LLM
            if model.llmLocal {
                localBlock(title: "AI polish model", ready: model.llmReady, progress: model.llmProgress,
                           download: { model.downloadLLMModel() })
            } else {
                cloudLLMBlock(ok: model.cloudLLMOK, test: { model.testCloudLLM() },
                              deepSeek: { model.prefillDeepSeek() })
            }

            if model.anyLocal {
                Toggle("Downloads are slow? Use the China mirror (hf-mirror.com)", isOn: $model.hfMirror)
                    .font(.callout)
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text("Saved to \(model.modelsPath)").lineLimit(1).truncationMode(.middle)
                    Button("Show in Finder") { model.revealModelsFolder() }.buttonStyle(.link)
                }.font(.caption).foregroundStyle(.secondary)
                Text("First local run downloads about 1.5–4 GB total (one time). ASR + AI polish download together.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.status.isEmpty {
                Text(model.status).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func localBlock(title: LocalizedStringKey, ready: Bool, progress: Double?,
                            download: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.title2).foregroundStyle(ready ? .green : .orange)
            Text(title).font(.headline)
            Spacer()
            if ready {
                Text("Ready").foregroundStyle(.green)
            } else if let progress {
                if progress >= 0.99 {
                    // Download done; the model is loading into memory (first-ever can take a minute).
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Preparing…").foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView(value: progress).frame(width: 180)
                }
            } else {
                Button("Download", action: download)   // independent per stage → ASR + LLM download in parallel
            }
        }
        .padding(12).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func cloudBlock(title: LocalizedStringKey, key: Binding<String>, baseURL: Binding<String>,
                            cloudModel: Binding<String>, ok: Bool?, test: @escaping () -> Void,
                            deepSeek: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: "cloud").font(.headline)
                Spacer()
                if let ok { Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ok ? .green : .red) }
            }
            if let deepSeek {
                Button("Use DeepSeek preset", action: deepSeek).controlSize(.small)
            }
            SecureField("API key", text: key)
            TextField("Base URL", text: baseURL)
            TextField("Model", text: cloudModel)
            Button("Test connection", action: test).disabled(model.cloudTesting || key.wrappedValue.isEmpty)
        }
        .padding(12).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func cloudLLMBlock(ok: Bool?, test: @escaping () -> Void,
                               deepSeek: @escaping () -> Void) -> some View {
        let providers = CloudProviderRegistry.builtIn
        let current = providers.first { $0.id == model.cloud.llmProviderID } ?? CloudProviderRegistry.builtIn[0]
        let keyBinding = Binding<String>(
            get: { model.cloud.llmAPIKeys[model.cloud.llmProviderID] ?? "" },
            set: { model.cloud.llmAPIKeys[model.cloud.llmProviderID] = $0 }
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("AI polish (cloud)", systemImage: "cloud").font(.headline)
                Spacer()
                if let ok { Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ok ? .green : .red) }
            }
            Button("Use DeepSeek preset", action: deepSeek).controlSize(.small)
            Picker("Provider", selection: $model.cloud.llmProviderID) {
                ForEach(providers) { p in Text(p.displayName).tag(p.id) }
            }
            .onChange(of: model.cloud.llmProviderID) { newID in
                if let p = providers.first(where: { $0.id == newID }) {
                    model.cloud.llmBaseURL = p.baseURL
                    if !p.defaultModels.isEmpty, !p.defaultModels.contains(model.cloud.llmModel) {
                        model.cloud.llmModel = p.defaultModels[0]
                    }
                }
            }
            if current.needsAPIKey {
                SecureField("API key", text: keyBinding)
            }
            TextField("Base URL", text: $model.cloud.llmBaseURL)
            TextField("Model", text: $model.cloud.llmModel)
            Button("Test connection", action: test)
                .disabled(model.cloudTesting || (current.needsAPIKey && keyBinding.wrappedValue.isEmpty))
        }
        .padding(12).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct TryItStep: View {
    @ObservedObject var model: OnboardingModel
    private var suggestion: LocalizedStringKey {
        model.tryMode == 1
            ? "Try saying: “今天天气不错，我们出去走走吧”"
            : "Try saying: “嗯…帮我把这句话整理一下，去掉那些口头禅”"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader("Try it out", "Pick a mode, read the line aloud, and watch it work. (Nothing is typed anywhere.)")

            Picker("", selection: $model.tryMode) {
                Text("Dictation").tag(0)
                Text("Translation → English").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(model.tryRecording || model.tryBusy)

            Label(suggestion, systemImage: "quote.opening")
                .font(.callout).foregroundStyle(.secondary)
                .id(model.tryMode)
                .transition(.opacity)

            if model.warming {
                Label("Loading local models into memory — about 1–2 minutes the first time after each launch. You can use other features while this runs.",
                      systemImage: "arrow.down.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Button {
                model.toggleTry()
            } label: {
                Label(model.tryRecording ? "Stop & transcribe" : "Start recording",
                      systemImage: model.tryRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title3).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(model.tryRecording ? .red : .accentColor)
            .disabled(model.warming || model.tryBusy)
            .scaleEffect(model.tryRecording ? 1.02 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: model.tryRecording)

            if model.tryBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…").foregroundStyle(.secondary)
                }
            } else if !model.tryResult.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Result").font(.caption).foregroundStyle(.secondary)
                    Text(model.tryResult).textSelection(.enabled).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.smooth(duration: 0.25), value: model.tryBusy)
        .animation(.smooth(duration: 0.25), value: model.tryMode)
    }
}

private struct DoneStep: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BrandMark(size: 48)
            Text("You're all set").font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 8) {
                Text("Shortcuts — click a shortcut to change it").font(.caption).foregroundStyle(.secondary)
                HotkeyRecorder(label: "Voice Input", hotkey: $model.dictationHotkey)
                HotkeyRecorder(label: "Translation", hotkey: $model.translationHotkey)
                HotkeyRecorder(label: "Ask Anything", hotkey: $model.askHotkey)
            }
            .padding(12).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 10))
            Text("Click into any text field first. Press the hotkey once to start, then again to stop and insert.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Launch SaidDone at login", isOn: $model.launchAtLogin)
            Text("SaidDone lives in the menu bar. Open it any time from the menu-bar icon.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct StepHeader: View {
    let title: LocalizedStringKey; let subtitle: LocalizedStringKey
    init(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) { self.title = title; self.subtitle = subtitle }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title.bold())
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }
}
