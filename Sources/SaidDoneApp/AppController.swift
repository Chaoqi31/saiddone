import AppKit
import SwiftUI
import SaidDoneCore
import SaidDoneProviders

/// Append-only debug log in Caches (NSLog doesn't reliably surface for this bundle).
func slog(_ message: String) {
    NSLog("%@", message)
    let line = "\(Date()) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let dir = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
               ?? FileManager.default.temporaryDirectory).appendingPathComponent("SaidDone", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("saiddone.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: url)
    }
}

/// Serializes potentially blocking Keychain writes away from the main actor. The JSON settings file
/// is persisted synchronously first, so ordinary preferences survive even if Keychain is locked.
private actor ConfigPersistence {
    let store: ConfigStore

    init(store: ConfigStore) { self.store = store }

    func saveSecrets(_ config: AppConfig) {
        do {
            try store.saveSecrets(config)
        } catch {
            slog("config secret persistence failed: \(error)")
        }
    }
}

/// Menu-bar controller: owns config, capture, hotkeys, providers; runs the toggle record loop.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private let capture = AudioCapture()
    private let configStore: ConfigStore
    private let configPersistence: ConfigPersistence
    private var config: AppConfig
    private var configRevision = 0
    private var secretRevision = 0
    private let localization: LocalizationManager

    /// Which Mode is currently recording, nil = idle. Toggle (ADR-0006).
    private var activeMode: Mode?
    /// Selection captured when Ask recording starts (before ASR can take seconds).
    private var askSelectionSnapshot: String?

    // Preserves warm adapters until provider-relevant config actually changes.
    private var providerRuntime: ProviderRuntime
    private var asr: ASRProvider { providerRuntime.asr }
    private var llm: LLMProvider { providerRuntime.llm }
    private let historyRepository: HistoryRepository
    private lazy var historyModel = HistoryModel(repository: historyRepository)
    private let overlay = RecordingOverlay()
    private var hotkeyWarning: String?

    private lazy var setupModel: SetupModel = {
        let m = SetupModel()
        m.sync(from: config)
        m.useMirror = !config.huggingFaceEndpoint.isEmpty
        m.onPrepare = { [weak self] in await self?.prepareEngines() }
        m.onDownloadASR = { [weak self] progress in
            guard let self else { return }
            try await ModelDownloader.downloadWhisper(model: self.config.asr.modelID,
                                                      endpoint: self.config.huggingFaceEndpoint, progress: progress)
        }
        m.onDownloadLLM = { [weak self] progress in
            guard let self else { return }
            try await ModelDownloader.downloadMLX(repoID: self.config.llm.modelID,
                                                  endpoint: self.config.huggingFaceEndpoint, progress: progress)
        }
        m.onSetMirror = { [weak self] on in
            guard let self else { return }
            var c = self.config
            c.huggingFaceEndpoint = on ? "https://hf-mirror.com" : ""
            self.applyConfig(c)
        }
        return m
    }()
    private lazy var dictionaryModel = DictionaryModel(
        entries: config.dictionary.entries,
        onChange: { [weak self] entries in self?.saveDictionary(entries) }
    )
    private lazy var configModel = ConfigModel(config: config) { [weak self] newConfig in
        self?.applyConfig(newConfig)
    }

    // First-run wizard.
    private var onboardingWindow: NSWindow?
    private var onboardingTrying = false
    private lazy var onboardingModel: OnboardingModel = {
        let m = OnboardingModel()
        m.loadDraft(from: config, effectiveLanguage: localization.code)
        m.onSetLanguage = { [weak self] code in self?.localization.set(code) }
        m.requestMic = { await Permissions.requestMicrophone() }
        m.downloadWhisper = { model, endpoint, progress in
            try await ModelDownloader.downloadWhisper(model: model, endpoint: endpoint, progress: progress)
        }
        m.downloadLLM = { repoID, endpoint, progress in
            try await ModelDownloader.downloadMLX(repoID: repoID, endpoint: endpoint, progress: progress)
        }
        m.testCloud = { baseURL, key in await Self.testCloudConnection(baseURL: baseURL, key: key) }
        m.applyDraft = { [weak self] in self?.applyOnboardingDraft() }
        m.warmUp = { [weak self] in await self?.prepareEngines() }
        m.tryToggle = { [weak self] in await self?.onboardingTryToggle() }
        m.finishWizard = { [weak self] in self?.finishOnboarding() }
        return m
    }()

    override init() {
        let dir = (try? ConfigStore.defaultDirectory()) ?? FileManager.default.temporaryDirectory
        let store = ConfigStore(directory: dir)
        let cfg = store.loadWithoutSecrets()
        self.configStore = store
        self.configPersistence = ConfigPersistence(store: store)
        self.config = cfg
        self.localization = LocalizationManager(override: cfg.appLanguage)
        self.providerRuntime = ProviderRuntime(config: cfg)
        self.historyRepository = HistoryRepository(directory: dir)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        setupStatusItem()
        hydrateSecretsInBackground()
        overlay.model.onFinish = { [weak self] in self?.finishRecording() }
        overlay.model.onCancel = { [weak self] in self?.cancelRecording() }
        historyModel.onLearnTerms = { [weak self] terms in self?.learnTerms(terms) }
        historyModel.onReinsert = { [weak self] text in
            guard let self else { return }
            if !InsertionService.insert(text, autoCopy: self.config.autoCopyToClipboard) {
                self.showInsertPermissionError()
            }
        }
        let n = registerHotkeys()
        refreshUI()
        slog("launched, \(n) hotkeys registered — ASR=\(asr.id) LLM=\(llm.id)")
        LoginItem.apply(config.launchAtLogin)

        // First launch: run the setup wizard instead of prompting permissions / opening the main window.
        if !config.onboardingCompleted {
            openOnboarding()
            return
        }

        Permissions.accessibilityTrusted(prompt: true)
        Task {
            _ = await Permissions.requestMicrophone()
            // Let the window paint first — model warm-up runs in the background without blocking the app.
            try? await Task.sleep(for: .milliseconds(800))
            scheduleBackgroundPrewarm()
        }
        // Registration is a preference, not a launch source. Only the Apple-event login marker
        // means this particular launch should stay in the background; a manual Dock/Finder launch
        // must still open the window even when "Launch at login" is enabled.
        let loginItemLaunch = Self.launchedAsLoginItem()
        slog("launch source — loginItem=\(loginItemLaunch)")
        if Self.shouldOpenMainWindow(
            onboardingCompleted: config.onboardingCompleted,
            launchedAsLoginItem: loginItemLaunch
        ) {
            openMainWindow()
        }
    }

    /// Clicking the app/Dock icon while it's already running re-opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openMainWindow()
        return true
    }

    /// Closing the window keeps the app alive in the menu bar (it's a background dictation tool).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    static func shouldOpenMainWindow(
        onboardingCompleted: Bool,
        launchedAsLoginItem: Bool
    ) -> Bool {
        onboardingCompleted && !launchedAsLoginItem
    }

    private static func launchedAsLoginItem() -> Bool {
        NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
    }

    // MARK: UI

    private var isWorking = false  // pipeline running after a stop

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshUI()
    }

    /// Install a minimal main menu. macOS SwiftUI TextFields need standard Edit-menu actions
    /// (cut:/copy:/paste:/selectAll:) on the responder chain — without them ⌘V/⌘C/⌘A do nothing
    /// in Settings text fields. The selectors are handled by the firstResponder automatically.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit SaidDone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = main
    }

    private func menuItem(_ title: String, _ sel: Selector?, symbol: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return i
    }

    private var mainWindow: NSWindow?

    /// Sync the window's editor models with the latest config (dictionary/settings live in the window).
    /// NOTE: we deliberately do NOT overwrite `configModel.config` here. The Settings editor is the
    /// source of truth for in-progress edits; resetting it on every `openMainWindow()` (Dock click,
    /// menu-bar "Open SaidDone…") would wipe unsaved Cloud-tab edits — see commit history for the bug.
    /// First-window sync happens in `openMainWindow()` instead.
    private func syncWindowModels() {
        historyModel.refresh()
        dictionaryModel.entries = config.dictionary.entries
        setupModel.refresh()
    }

    @objc private func openMainWindow() {
        if let win = mainWindow {
            syncWindowModels()
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // First-time creation: prime the editor models with the current config (launch-time .env
        // hydration, onboarding, dictionary auto-learn may have changed it since the lazy init).
        configModel.config = config
        syncWindowModels()
        let root = LocalizedRoot(localization: localization) {
            MainView(history: self.historyModel, dictionary: self.dictionaryModel,
                     config: self.configModel, setup: self.setupModel)
        }
        let win = NSWindow(contentViewController: NSHostingController(rootView: root))
        win.title = "SaidDone"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 980, height: 680))   // fixed start size; user can resize
        mainWindow = win
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Onboarding wizard

    @objc private func openOnboarding() {
        if let win = onboardingWindow {
            win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        if config.onboardingCompleted {
            onboardingModel.loadDraft(from: config, effectiveLanguage: localization.code)
        }
        onboardingModel.refreshPermissions()
        onboardingModel.refreshModelReadiness()
        let root = LocalizedRoot(localization: localization) { OnboardingView(model: self.onboardingModel) }
        let win = NSWindow(contentViewController: NSHostingController(rootView: root))
        win.title = NSLocalizedString("Welcome to SaidDone", comment: "onboarding window title")
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        onboardingWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Build a config from the wizard's draft engine choice. `complete` marks onboarding done + applies
    /// the login-item preference (only at the final step).
    private func configFromOnboarding(complete: Bool) -> AppConfig {
        var c = config
        c.asr = ProviderSelection(location: onboardingModel.asrLocal ? .local : .cloud, modelID: onboardingModel.asrModelID)
        c.llm = ProviderSelection(location: onboardingModel.llmLocal ? .local : .cloud, modelID: onboardingModel.llmModelID)
        c.cloud = onboardingModel.cloud
        c.huggingFaceEndpoint = onboardingModel.endpoint
        c.appLanguage = onboardingModel.appLanguageOverride(
            preserving: config.appLanguage,
            onboardingCompleted: config.onboardingCompleted)
        c.dictationHotkey = onboardingModel.dictationHotkey
        c.translationHotkey = onboardingModel.translationHotkey
        c.askHotkey = onboardingModel.askHotkey
        if complete {
            c.launchAtLogin = onboardingModel.launchAtLogin
            c.onboardingCompleted = true
        }
        return c
    }

    /// Commit the draft engine choice to the live providers so the Try-it step uses the real engines.
    private func applyOnboardingDraft() { applyConfig(configFromOnboarding(complete: false)) }

    private func finishOnboarding() {
        applyConfig(configFromOnboarding(complete: true))
        onboardingWindow?.close(); onboardingWindow = nil
        scheduleBackgroundPrewarm()
        openMainWindow()
    }

    /// Start/stop a one-off test capture for the wizard's Try-it step. Result is shown in the wizard,
    /// never inserted into another app.
    private func onboardingTryToggle() async {
        if onboardingTrying {
            let audio = capture.stop()
            capture.onLevel = nil
            onboardingTrying = false
            onboardingModel.tryRecording = false
            onboardingModel.tryBusy = true
            let mode: Mode = onboardingModel.tryMode == 1 ? .translation(target: "en") : .dictation
            let orch = PipelineOrchestrator(asr: asr, llm: llm, dictionary: config.dictionary,
                                            llmTimeout: isPrewarming ? 0 : config.llmTimeoutSeconds)
            do {
                let r = try await orch.run(
                    audio, mode: mode,
                    options: PipelineOptions(languageHint: config.asrLanguage))
                onboardingModel.tryResult = r.text.isEmpty
                    ? NSLocalizedString("(no speech detected — try again)", comment: "onboarding try")
                    : r.text
            } catch {
                onboardingModel.tryResult = Self.friendlyError(error)
            }
            onboardingModel.tryBusy = false
        } else {
            do {
                try capture.start()
                onboardingTrying = true
                onboardingModel.tryRecording = true
                onboardingModel.tryResult = ""
            } catch {
                onboardingModel.tryResult = NSLocalizedString("Microphone error — check the permission.", comment: "onboarding try")
            }
        }
    }

    /// Minimal reachability check for an OpenAI-compatible endpoint: GET {baseURL}/models with the key.
    static func testCloudConnection(baseURL: String, key: String) async -> Bool {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard !key.isEmpty, let url = URL(string: trimmed + "/models") else { return false }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 12
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch { return false }
    }

    /// Dictionary changes are read live at dictation time, so just persist — no provider rebuild.
    private func saveDictionary(_ entries: [DictionaryEntry]) {
        config.dictionary.entries = entries
        configRevision += 1
        persistConfig(config)
        configModel.config = config   // keep the Settings editor in sync
    }

    /// Merge auto-learned correction terms into the dictionary (from a History edit).
    private func learnTerms(_ terms: [DictionaryEntry]) {
        var byKey = Dictionary(config.dictionary.entries.map { ($0.wrong, $0) }) { a, _ in a }
        for t in terms { byKey[t.wrong] = t }
        let merged = byKey.values.sorted { $0.wrong < $1.wrong }
        saveDictionary(merged)
        dictionaryModel.entries = merged   // reflect in an open window
        slog("learned dictionary terms: \(terms.count)")
    }

    /// Persist edited config and rebuild providers so changes take effect immediately.
    private func applyConfig(_ newConfig: AppConfig) {
        let languageChanged = newConfig.appLanguage != config.appLanguage
        let secretsChanged = newConfig.cloud.llmAPIKeys != config.cloud.llmAPIKeys
            || newConfig.cloud.asrKey != config.cloud.asrKey
        config = newConfig
        configRevision += 1
        if secretsChanged { secretRevision += 1 }
        persistConfig(newConfig, includeSecrets: secretsChanged)
        if languageChanged { localization.set(newConfig.appLanguage) }
        let replacements = providerRuntime.apply(newConfig)
        setupModel.sync(from: newConfig)
        dictionaryModel.entries = newConfig.dictionary.entries
        LoginItem.apply(newConfig.launchAtLogin)
        hotkeys.unregisterAll()
        registerHotkeys()
        refreshUI()
        if replacements != .none {
            slog("providers replaced — ASR=\(replacements.asr) LLM=\(replacements.llm)")
        }
    }

    /// Decode-first startup keeps UI responsive; secrets and optional `.env` hydration happen away
    /// from the main actor. If the user edits settings before hydration completes, their newer state
    /// wins and the late result is discarded.
    private func hydrateSecretsInBackground() {
        let store = configStore
        let baseConfig = config
        let expectedConfigRevision = configRevision
        let expectedSecretRevision = secretRevision
        let hadInlineASRKey = !baseConfig.cloud.asrKey.isEmpty
        Task.detached(priority: .userInitiated) { [weak self] in
            var hydrated = store.hydrateSecrets(baseConfig)
            let environmentChanged = EnvLoader.mergeInto(&hydrated)
            await self?.installHydratedConfig(
                hydrated,
                expectedConfigRevision: expectedConfigRevision,
                expectedSecretRevision: expectedSecretRevision,
                environmentChanged: environmentChanged,
                hadInlineASRKey: hadInlineASRKey)
        }
    }

    private func installHydratedConfig(
        _ hydrated: AppConfig,
        expectedConfigRevision: Int,
        expectedSecretRevision: Int,
        environmentChanged: Bool,
        hadInlineASRKey: Bool
    ) {
        guard secretRevision == expectedSecretRevision else {
            slog("secret hydration skipped — credentials changed while Keychain was loading")
            return
        }
        let ordinarySettingsUnchanged = configRevision == expectedConfigRevision
        let merged = ordinarySettingsUnchanged && environmentChanged
            ? hydrated
            : ConfigHydration.mergeSecrets(from: hydrated, into: config)
        config = merged
        let replacements = providerRuntime.apply(merged)
        setupModel.sync(from: merged)
        if mainWindow != nil { configModel.config = merged }
        if onboardingWindow != nil {
            for (id, key) in merged.cloud.llmAPIKeys
            where onboardingModel.cloud.llmAPIKeys[id, default: ""].isEmpty {
                onboardingModel.cloud.llmAPIKeys[id] = key
            }
            if onboardingModel.cloud.asrKey.isEmpty {
                onboardingModel.cloud.asrKey = merged.cloud.asrKey
            }
        }
        if (environmentChanged && ordinarySettingsUnchanged) || hadInlineASRKey {
            try? configStore.saveWithoutSecrets(merged)
        }
        if environmentChanged {
            Task { await configPersistence.saveSecrets(merged) }
        }
        refreshUI()
        slog("cloud secrets hydrated — providers replaced ASR=\(replacements.asr) LLM=\(replacements.llm)")
    }

    private func persistConfig(_ value: AppConfig, includeSecrets: Bool = false) {
        do {
            try configStore.saveWithoutSecrets(value)
        } catch {
            slog("config persistence failed: \(error)")
        }
        if includeSecrets {
            Task { await configPersistence.saveSecrets(value) }
        }
    }

    /// Rebuild menu + icon for current state. Recording shows explicit Stop / Cancel.
    private func refreshUI() {
        let menu = NSMenu()

        // Status header: which engines are active, plus a warning if a chosen local model is missing.
        let engines = menuItem(engineSummary(), nil); engines.isEnabled = false
        menu.addItem(engines)
        if isPrewarming, let stage = prewarmStage {
            let warming = menuItem(
                String(format: NSLocalizedString("Loading in background — %@", comment: "menu prewarm stage"), stage),
                nil, symbol: "arrow.down.circle")
            warming.isEnabled = false
            menu.addItem(warming)
        }
        if let issue = recordingAvailabilityIssue() {
            menu.addItem(menuItem(issue.menuMessage, #selector(openMainWindow),
                                  symbol: "exclamationmark.triangle.fill"))
        }
        if let hotkeyWarning {
            menu.addItem(menuItem(hotkeyWarning, #selector(openMainWindow), symbol: "keyboard"))
        }
        menu.addItem(.separator())

        if let mode = activeMode {
            let label: String = {
                switch mode {
                case .translation: return NSLocalizedString("Translation", comment: "mode name")
                case .ask: return NSLocalizedString("Ask Anything", comment: "mode name")
                default: return NSLocalizedString("Voice Input", comment: "mode name")
                }
            }()
            menu.addItem(menuItem(String(format: NSLocalizedString("Stop & Insert — %@", comment: "menu"), label), #selector(stopAndInsert), symbol: "stop.circle.fill"))
            menu.addItem(menuItem(NSLocalizedString("Cancel (discard)", comment: "menu"), #selector(cancelRecording), symbol: "xmark.circle"))
        } else if isWorking {
            let working = menuItem(NSLocalizedString("Working…", comment: "menu"), nil, symbol: "hourglass"); working.isEnabled = false
            menu.addItem(working)
        } else {
            menu.addItem(menuItem(NSLocalizedString("Start Voice Input       ⌃⌥D", comment: "menu"), #selector(toggleDictation), symbol: "mic"))
            menu.addItem(menuItem(NSLocalizedString("Start Translation     ⌃⌥T", comment: "menu"), #selector(toggleTranslation), symbol: "globe"))
            menu.addItem(menuItem(NSLocalizedString("Start Ask Anything    ⌃⌥A", comment: "menu"), #selector(toggleAsk), symbol: "text.bubble"))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem(NSLocalizedString("Open SaidDone…", comment: "menu"), #selector(openMainWindow), symbol: "macwindow"))
        menu.addItem(menuItem(NSLocalizedString("Setup Assistant…", comment: "menu"), #selector(openOnboarding), symbol: "sparkles"))
        menu.addItem(.separator())
        menu.addItem(withTitle: NSLocalizedString("Quit SaidDone", comment: "menu"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        let recording = activeMode != nil
        let name = recording ? "mic.fill" : (isWorking ? "hourglass" : "mic")
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "SaidDone")
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
        recording ? startBlink() : stopBlink()
    }

    private var blinkTimer: Timer?
    private func startBlink() {
        guard blinkTimer == nil else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let b = self?.statusItem.button else { return }
                b.alphaValue = b.alphaValue > 0.6 ? 0.35 : 1.0
            }
        }
    }
    private func stopBlink() {
        blinkTimer?.invalidate(); blinkTimer = nil
        statusItem.button?.alphaValue = 1.0
    }

    private func updateStatusIcon() { refreshUI() }

    /// Stop capture and discard — instant mic release, no pipeline.
    @objc private func cancelRecording() {
        guard activeMode != nil else { return }
        _ = capture.stop()
        capture.onLevel = nil
        if config.muteAudioWhileRecording { SystemAudio.setMuted(false) }
        overlay.hide()
        activeMode = nil
        askSelectionSnapshot = nil
        slog("recording cancelled")
        refreshUI()
    }

    @objc private func stopAndInsert() { finishRecording() }

    /// True while local models load into memory after launch (background — app stays usable).
    private var isPrewarming = false
    private var prewarmStage: String?
    private var prewarmTask: Task<Void, Never>?

    /// Kick off a single background warm-up; safe to call from launch / Setup / onboarding.
    private func scheduleBackgroundPrewarm() {
        guard prewarmTask == nil else { return }
        prewarmTask = Task { [weak self] in
            await self?.prewarm()
            self?.prewarmTask = nil
        }
    }

    /// Start a tracked warm-up and wait for it. Setup/onboarding use this path so a recording that
    /// finishes concurrently can wait for the same task instead of touching a provider mid-warm-up.
    private func prepareEngines() async {
        scheduleBackgroundPrewarm()
        await prewarmTask?.value
    }

    /// Warm local models into memory so the first dictation isn't a mystery wait. Cloud engines skip.
    /// Runs in the background with per-stage timeouts so a slow load never blocks the app forever.
    func prewarm() async {
        let needsASR = config.asr.location == .local
        let needsLLM = config.llm.location == .local
        let usesCloud = config.asr.location == .cloud || config.llm.location == .cloud

        if usesCloud {
            await ProviderFactory.warmCloud(config)
        }
        guard needsASR || needsLLM else {
            slog(usesCloud ? "cloud connections warm" : "prewarm skipped — cloud-only engines")
            return
        }
        guard !isPrewarming else {
            await prewarmTask?.value
            return
        }

        slog("prewarming models…")
        isPrewarming = true
        defer { isPrewarming = false; prewarmStage = nil; refreshUI() }
        refreshUI()

        if needsASR {
            prewarmStage = NSLocalizedString("Speech model…", comment: "prewarm stage")
            refreshUI()
            let ok = await withTimeout(90) {
                _ = try? await self.asr.transcribe(
                    AudioSamples(samples: [Float](repeating: 0, count: 1600)),
                    languageHint: self.config.asrLanguage)
            }
            if !ok { slog("prewarm: speech model timed out after 90s") }
        }
        guard !Task.isCancelled else { return }

        if needsLLM {
            prewarmStage = NSLocalizedString("AI model…", comment: "prewarm stage")
            refreshUI()
            let ok = await withTimeout(120) {
                _ = try? await self.llm.polish("warm up", context: .none)
            }
            if !ok { slog("prewarm: AI model timed out after 120s") }
        }
        slog("models warm")
    }

    /// Run `operation` but give up after `seconds` (returns false on timeout).
    private func withTimeout(_ seconds: TimeInterval,
                             operation: @MainActor @escaping () async -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = PrewarmResumeGate(continuation)
            Task { @MainActor in
                await operation()
                gate.resume(true)
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                gate.resume(false)
            }
        }
    }

    // MARK: Hotkeys / toggle

    @discardableResult
    private func registerHotkeys() -> Int {
        var n = 0
        var failed: [String] = []
        let duplicates = Self.duplicateHotkeyNames(config)
        if hotkeys.register(config.dictationHotkey, onPress: { [weak self] in self?.toggle(.dictation) }) { n += 1 }
        else { failed.append(NSLocalizedString("Voice Input", comment: "hotkey label")) }
        if hotkeys.register(config.translationHotkey, onPress: { [weak self] in
            self?.toggle(.translation(target: self?.config.targetLanguage ?? "en"))
        }) { n += 1 }
        else { failed.append(NSLocalizedString("Translation", comment: "hotkey label")) }
        if hotkeys.register(config.askHotkey, onPress: { [weak self] in self?.toggle(.ask) }) { n += 1 }
        else { failed.append(NSLocalizedString("Ask Anything", comment: "hotkey label")) }
        let names = duplicates.isEmpty ? failed : duplicates
        hotkeyWarning = names.isEmpty
            ? nil
            : String(format: NSLocalizedString("Shortcut conflict — open Settings (%@)", comment: "hotkey warning"),
                     names.joined(separator: ", "))
        return n
    }

    static func duplicateHotkeyNames(_ config: AppConfig) -> [String] {
        let keys: [(String, Hotkey)] = [
            ("Voice Input", config.dictationHotkey),
            ("Translation", config.translationHotkey),
            ("Ask Anything", config.askHotkey),
        ]
        var byHotkey: [Hotkey: [String]] = [:]
        for (name, hotkey) in keys { byHotkey[hotkey, default: []].append(name) }
        return byHotkey.values.filter { $0.count > 1 }.flatMap { $0 }
    }

    @objc private func toggleAsk() { toggle(.ask) }

    @objc private func toggleDictation() { toggle(.dictation) }
    @objc private func toggleTranslation() { toggle(.translation(target: config.targetLanguage)) }

    enum RecordingToggleAction: Equatable {
        case start(Mode)
        case finish
        case switchMode(Mode)
        case ignoreBusy
    }

    /// Pure toggle decision — hotkey vs. current recording / pipeline state.
    static func recordingToggleAction(activeMode: Mode?, isWorking: Bool, requested: Mode) -> RecordingToggleAction {
        if isWorking { return .ignoreBusy }
        if let current = activeMode {
            return current == requested ? .finish : .switchMode(requested)
        }
        return .start(requested)
    }

    private func toggle(_ mode: Mode) {
        switch Self.recordingToggleAction(activeMode: activeMode, isWorking: isWorking, requested: mode) {
        case .ignoreBusy:
            slog("toggle ignored — pipeline running")
        case .finish:
            finishRecording()
        case .switchMode(let newMode):
            switchRecordingMode(to: newMode)
        case .start(let newMode):
            if let issue = recordingAvailabilityIssue() {
                overlay.showError(issue.message)
                return
            }
            startRecording(newMode)
        }
    }

    private static func recordingLabel(for mode: Mode) -> String {
        switch mode {
        case .translation: return NSLocalizedString("Translating", comment: "overlay label")
        case .ask: return NSLocalizedString("Ask — speak your question", comment: "overlay label")
        default: return NSLocalizedString("Recording", comment: "overlay label")
        }
    }

    /// Switch mode mid-capture without discarding audio (different hotkey while recording).
    private func switchRecordingMode(to mode: Mode) {
        guard activeMode != nil else { return }
        activeMode = mode
        if case .ask = mode {
            askSelectionSnapshot = InsertionService.grabSelection()
        } else {
            askSelectionSnapshot = nil
        }
        overlay.updateLabel(Self.recordingLabel(for: mode))
        slog("recording mode switched")
        refreshUI()
    }

    /// One-line summary of the active engines for the menu-bar status header.
    private func engineSummary() -> String {
        func loc(_ l: ProviderLocation) -> String {
            l == .local ? NSLocalizedString("Local", comment: "engine location") : NSLocalizedString("Cloud", comment: "engine location")
        }
        let ai: String = {
            if config.llm.location == .local { return Self.shortLLMName(config.llm.modelID) }
            return CloudProviderRegistry.builtIn.first { $0.id == config.cloud.llmProviderID }?.displayName
                ?? NSLocalizedString("Cloud", comment: "engine location")
        }()
        return String(format: NSLocalizedString("Speech: %@ · AI: %@", comment: "menu engine summary"),
                      loc(config.asr.location), ai)
    }

    /// "mlx-community/Qwen3-4B-4bit" -> "Qwen3 4B" for compact display.
    private static func shortLLMName(_ id: String) -> String {
        id.replacingOccurrences(of: "mlx-community/", with: "")
          .replacingOccurrences(of: "-4bit", with: "")
          .replacingOccurrences(of: "-", with: " ")
    }

    private func recordingAvailabilityIssue() -> EngineReadinessIssue? {
        EngineReadiness.issue(
            for: config,
            asrModelReady: ModelStorage.isWhisperReady(modelID: config.asr.modelID),
            llmModelReady: ModelStorage.isMLXReady(modelID: config.llm.modelID))
    }

    private func startRecording(_ mode: Mode) {
        // Model warm-up is independent of microphone capture. Start listening immediately so words
        // spoken while a model is loading are never discarded; processing waits below if necessary.
        beginCapture(mode)
    }

    private func beginCapture(_ mode: Mode) {
        capture.onLevel = { [weak self] lvl in DispatchQueue.main.async { self?.overlay.updateLevel(lvl) } }
        capture.preferBuiltInMic = config.preferBuiltInMic
        do {
            try capture.start()
            activeMode = mode
            if case .ask = mode {
                askSelectionSnapshot = InsertionService.grabSelection()
            } else {
                askSelectionSnapshot = nil
            }
            overlay.show(label: Self.recordingLabel(for: mode))
            if config.soundsEnabled { SoundFx.start() }
            if config.muteAudioWhileRecording { SystemAudio.setMuted(true) }
            slog("recording started")
            refreshUI()
        } catch {
            capture.onLevel = nil
            slog("capture.start failed: \(error)")
            overlay.showError(Self.friendlyCaptureError(
                error, microphoneAuthorized: Permissions.microphoneAuthorized()))
        }
    }

    static func friendlyCaptureError(_ error: Error, microphoneAuthorized: Bool) -> String {
        if !microphoneAuthorized {
            return NSLocalizedString(
                "Microphone access is unavailable — enable SaidDone in System Settings → Privacy & Security → Microphone.",
                comment: "capture permission error")
        }
        if error is CaptureError {
            return NSLocalizedString(
                "No working microphone input was found — check your input device and try again.",
                comment: "capture input error")
        }
        return NSLocalizedString(
            "Couldn't start recording — check your microphone input and try again.",
            comment: "capture start error")
    }

    /// Calm, user-facing message for a pipeline failure (technical detail stays in the log).
    static func friendlyError(_ error: Error) -> String {
        // Match URLError by code first — the string scan below misses bare codes without a description.
        if let ue = error as? URLError {
            let network: Set<URLError.Code> = [
                .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                .dnsLookupFailed, .cannotFindHost, .timedOut, .secureConnectionFailed,
            ]
            if network.contains(ue.code) {
                return NSLocalizedString("Network unavailable. Check your connection and try again.", comment: "error")
            }
        }
        let s = "\(error)".lowercased()
        if s.contains("tls") || s.contains("-1200") || s.contains("offline") || s.contains("network")
            || s.contains("connection") || s.contains("timed out") || s.contains("could not connect") {
            return NSLocalizedString("Network unavailable. Check your connection and try again.", comment: "error")
        }
        if let pe = error as? ProviderError {
            switch pe {
            case .notConfigured: return NSLocalizedString("Cloud setup issue — check your API key and endpoint in Settings → Cloud.", comment: "error")
            case .modelUnavailable: return NSLocalizedString("Engine unavailable. Please try again shortly.", comment: "error")
            case .latencyBudgetExceeded: return NSLocalizedString("Timed out. Please try again.", comment: "error")
            }
        }
        if s.contains("401") || s.contains("403") || s.contains("unauthor") || s.contains("api key") {
            return NSLocalizedString("Invalid cloud key — check Settings → Cloud.", comment: "error")
        }
        return NSLocalizedString("Transcription failed. Please try again.", comment: "error")
    }

    /// AI-operation budget: cloud generation on long utterances needs more headroom than local MLX.
    private func llmTimeoutBudget(for audio: AudioSamples) -> TimeInterval? {
        guard config.llmTimeoutSeconds > 0 else { return nil }
        var budget = config.llmTimeoutSeconds
        if llm.location == .cloud {
            budget = max(budget, 6 + audio.duration * 0.3)
        }
        return budget
    }

    private func finishRecording() {
        guard let mode = activeMode else { return }
        let audio = capture.stop()
        capture.onLevel = nil
        if config.muteAudioWhileRecording { SystemAudio.setMuted(false) }
        // Cloud roundtrips (ASR and/or LLM) routinely cross the 6s slow-hint threshold; the hint
        // message should reflect that, not claim a local model load that isn't happening.
        let cloudMode = config.asr.location == .cloud || config.llm.location == .cloud
        overlay.showProcessing(cloudMode: cloudMode)
        activeMode = nil
        isWorking = true
        slog("recording stopped, \(String(format: "%.1f", audio.duration))s audio, peakRMS=\(String(format: "%.4f", audio.peakRMS)), running pipeline…")
        refreshUI()

        if audio.duration < 0.15 || audio.peakRMS < 0.0005 {
            isWorking = false
            refreshUI()
            slog("capture empty or silent — mic may be disconnected or permission denied")
            overlay.showError(NSLocalizedString("No audio captured — check microphone permission and input device.", comment: "empty capture"))
            return
        }

        // Resolve App Profile tone from the foreground app (where text will land).
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var context = config.appProfiles.context(bundleID: bundleID, url: nil)
        context.userProfile = config.userProfile.isEmpty ? nil : config.userProfile
        context.spokenLanguage = config.asrLanguage
        let askSelection = askSelectionSnapshot ?? ""
        askSelectionSnapshot = nil

        // If background warm-up is still running, retain the captured audio and wait before asking
        // the same provider to transcribe. A first-launch load is not counted against the AI budget.
        let prewarmToAwait = prewarmTask
        let orch = PipelineOrchestrator(
            asr: asr, llm: llm, dictionary: config.dictionary,
            llmTimeout: prewarmToAwait == nil ? llmTimeoutBudget(for: audio) : nil,
            onProgress: { [weak self] progress, stage in
                Task { @MainActor in self?.overlay.updateProcessing(progress: progress, stageKey: stage) }
            },
            onDraft: { [weak self] draft in
                await MainActor.run {
                    guard let self else { return false }
                    return InsertionService.insertFastDraft(
                        draft, autoCopy: self.config.autoCopyToClipboard)
                }
            })
        let options = PipelineOptions(
            context: context,
            languageHint: config.asrLanguage,
            askSelection: askSelection,
            fastDraftEnabled: config.fastInsertBeforePolish,
            voiceCommandsEnabled: config.voiceCommandsEnabled)
        Task { @MainActor [mode, audio, orch, options, prewarmToAwait] in
            if let prewarmToAwait {
                self.overlay.updateProcessing(progress: 0, stageKey: "preparing")
                await prewarmToAwait.value
            }
            await self.runPipeline(mode: mode, audio: audio, orch: orch, options: options)
        }
    }

    private func runPipeline(mode: Mode, audio: AudioSamples, orch: PipelineOrchestrator,
                             options: PipelineOptions) async {
        defer { isWorking = false; refreshUI() }
        do {
            let result = try await orch.run(audio, mode: mode, options: options)
            let fastDraft = result.draftText
            slog("pipeline done, rawLen=\(result.rawTranscript.count), textLen=\(result.text.count), elapsed=\(String(format: "%.2f", result.elapsed))s polishSkipped=\(result.polishSkipped)")
            let finalText = result.text
            let trimmedFinal = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedFinal.isEmpty else {
                // Fast-insert draft survived an unpolished fallback; keep it only when the pipeline
                // marked polish as skipped, not when the LLM intentionally cleared fillers/cancels.
                if result.polishSkipped,
                   let draft = fastDraft?.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty {
                    slog("pipeline empty but draft retained (\(draft.count) chars)")
                    if config.soundsEnabled { SoundFx.done() }
                    overlay.showDone(NSLocalizedString("Inserted (unpolished draft)", comment: "dictation draft fallback"))
                    enqueueHistory(mode: mode, audio: audio, raw: result.rawTranscript, text: draft,
                                   elapsed: result.elapsed, polishSkipped: true)
                    return
                }
                slog("pipeline produced empty text — rawLen=\(result.rawTranscript.count), audio=\(String(format: "%.1f", audio.duration))s")
                let msg = result.rawTranscript.isEmpty
                    ? NSLocalizedString("Couldn't transcribe speech — try speaking louder or check your mic.", comment: "asr empty")
                    : NSLocalizedString("No speech detected — try again.", comment: "empty result")
                overlay.showError(msg)
                return
            }
            let inserted: Bool
            if let draft = fastDraft {
                if finalText != draft {
                    inserted = InsertionService.replaceFastDraft(with: finalText, replacing: draft,
                                                               autoCopy: config.autoCopyToClipboard)
                } else {
                    inserted = true
                }
            } else {
                inserted = InsertionService.insert(finalText, autoCopy: config.autoCopyToClipboard)
            }
            guard inserted else {
                enqueueHistory(mode: mode, audio: audio, raw: result.rawTranscript, text: finalText,
                               elapsed: result.elapsed, polishSkipped: result.polishSkipped)
                if fastDraft != nil {
                    overlay.showError(NSLocalizedString(
                        "Final text copied — the draft changed before it could be safely replaced.",
                        comment: "fast draft safe replacement fallback"))
                } else {
                    showInsertPermissionError()
                }
                return
            }
            if config.soundsEnabled { SoundFx.done() }
            overlay.showDone(config.autoCopyToClipboard
                ? NSLocalizedString("Inserted · on clipboard", comment: "dictation done toast, auto-copy on")
                : NSLocalizedString("Inserted", comment: "dictation done toast"))
            enqueueHistory(mode: mode, audio: audio, raw: result.rawTranscript, text: finalText,
                           elapsed: result.elapsed, polishSkipped: result.polishSkipped)
        } catch {
            slog("pipeline error: \(error)")
            NSSound.beep()
            overlay.showError(Self.friendlyError(error))
        }
    }

    private func showInsertPermissionError() {
        overlay.showError(NSLocalizedString(
            "Accessibility permission needed — text copied. Enable SaidDone in System Settings → Privacy & Security → Accessibility.",
            comment: "insert permission error"))
    }

    private func enqueueHistory(mode: Mode, audio: AudioSamples, raw: String, text: String,
                                elapsed: TimeInterval, polishSkipped: Bool) {
        let modeStr: String = {
            switch mode { case .translation: return "translation"; case .ask: return "ask"; default: return "dictation" }
        }()
        let entry = HistoryEntry(
            date: Date(), mode: modeStr, raw: raw, text: text,
            elapsed: elapsed > 0 ? elapsed : nil,
            polishSkipped: polishSkipped ? true : nil)
        historyModel.persist(entry, audio: audio)
    }
}

/// Ensures a prewarm timeout continuation resumes at most once.
private final class PrewarmResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<Bool, Never>

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func resume(_ value: Bool) {
        lock.withLock {
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: value)
        }
    }
}
