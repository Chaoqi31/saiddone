import AppKit
import SwiftUI
import SaidDoneCore
import SaidDoneProviders

/// Append-only debug log to /tmp/saiddone.log (NSLog doesn't reliably surface for this bundle).
func slog(_ message: String) {
    NSLog("%@", message)
    let line = "\(Date()) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/saiddone.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: url)
    }
}

/// Menu-bar controller: owns config, capture, hotkeys, providers; runs the toggle record loop.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private let capture = AudioCapture()
    private let configStore: ConfigStore
    private var config: AppConfig
    private let localization: LocalizationManager

    /// Which Mode is currently recording, nil = idle. Toggle (ADR-0006).
    private var activeMode: Mode?

    // Providers built from config: local ASR = WhisperKit, local LLM = MLX-Qwen (cloud if configured).
    private var asr: ASRProvider
    private var llm: LLMProvider
    private let historyStore: HistoryStore
    private lazy var historyModel = HistoryModel(store: historyStore)
    private let overlay = RecordingOverlay()
    private var previewTask: Task<Void, Never>?

    /// Live transcription preview while recording (opt-in). Cancelled before the final pipeline runs.
    private func startPreviewLoop() {
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            while !Task.isCancelled, self.activeMode != nil {
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled, self.activeMode != nil else { break }
                let snap = self.capture.snapshot()
                guard snap.duration >= 0.8 else { continue }
                if let t = try? await self.asr.transcribe(snap.trimmedSilence(), languageHint: self.config.asrLanguage),
                   !Task.isCancelled, self.activeMode != nil {
                    self.overlay.updatePreview(t)
                }
            }
        }
    }
    private lazy var setupModel: SetupModel = {
        let m = SetupModel()
        m.llmModelID = config.llm.modelID
        m.useMirror = !config.huggingFaceEndpoint.isEmpty
        m.onPrepare = { [weak self] in await self?.prewarm() }
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
        m.launchAtLogin = config.launchAtLogin
        m.dictationHotkey = config.dictationHotkey
        m.translationHotkey = config.translationHotkey
        m.rewriteHotkey = config.rewriteHotkey
        m.appLanguage = localization.code
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
        m.warmUp = { [weak self] in await self?.prewarm() }
        m.tryToggle = { [weak self] in await self?.onboardingTryToggle() }
        m.finishWizard = { [weak self] in self?.finishOnboarding() }
        return m
    }()

    override init() {
        let dir = (try? ConfigStore.defaultDirectory()) ?? FileManager.default.temporaryDirectory
        let store = ConfigStore(directory: dir)
        let cfg = store.load()
        self.configStore = store
        self.config = cfg
        self.localization = LocalizationManager(override: cfg.appLanguage)
        self.asr = ProviderFactory.makeASR(cfg)
        self.llm = ProviderFactory.makeLLM(cfg)
        self.historyStore = HistoryStore(directory: dir)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        overlay.model.onFinish = { [weak self] in self?.finishRecording() }
        overlay.model.onCancel = { [weak self] in self?.cancelRecording() }
        historyModel.onLearnTerms = { [weak self] terms in self?.learnTerms(terms) }
        historyModel.onReinsert = { [weak self] text in
            InsertionService.insert(text, autoCopy: self?.config.autoCopyToClipboard ?? false)
        }
        let n = registerHotkeys()
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
            await prewarm()
        }
        // Show the window on launch unless started as a login item (then stay in the background).
        if !config.launchAtLogin { openMainWindow() }
    }

    /// Clicking the app/Dock icon while it's already running re-opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openMainWindow()
        return true
    }

    /// Closing the window keeps the app alive in the menu bar (it's a background dictation tool).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: UI

    private var isWorking = false  // pipeline running after a stop

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshUI()
    }

    private func menuItem(_ title: String, _ sel: Selector?, symbol: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return i
    }

    private var mainWindow: NSWindow?

    /// Sync the window's editor models with the latest config (dictionary/settings live in the window).
    private func syncWindowModels() {
        historyModel.refresh()
        dictionaryModel.entries = config.dictionary.entries
        configModel.config = config
        setupModel.refresh()
    }

    @objc private func openMainWindow() {
        syncWindowModels()
        if let win = mainWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
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
        c.appLanguage = onboardingModel.appLanguage
        c.dictationHotkey = onboardingModel.dictationHotkey
        c.translationHotkey = onboardingModel.translationHotkey
        c.rewriteHotkey = onboardingModel.rewriteHotkey
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
        Task { await prewarm() }
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
            let orch = PipelineOrchestrator(asr: asr, llm: llm, dictionary: config.dictionary)
            do {
                let r = try await orch.run(audio, mode: mode, languageHint: config.asrLanguage)
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
        try? configStore.save(config)
        configModel.config = config   // keep the Settings editor in sync
    }

    /// Merge auto-learned correction terms into the dictionary (from a History edit).
    private func learnTerms(_ terms: [DictionaryEntry]) {
        var byKey = Dictionary(config.dictionary.entries.map { ($0.wrong, $0) }) { a, _ in a }
        for t in terms { byKey[t.wrong] = t }
        let merged = byKey.values.sorted { $0.wrong < $1.wrong }
        saveDictionary(merged)
        dictionaryModel.entries = merged   // reflect in an open window
        slog("learned dictionary terms: \(terms.map { "\($0.wrong)->\($0.right)" }.joined(separator: ","))")
    }

    /// Persist edited config and rebuild providers so changes take effect immediately.
    private func applyConfig(_ newConfig: AppConfig) {
        config = newConfig
        try? configStore.save(newConfig)
        asr = ProviderFactory.makeASR(newConfig)
        llm = ProviderFactory.makeLLM(newConfig)
        setupModel.llmModelID = newConfig.llm.modelID
        dictionaryModel.entries = newConfig.dictionary.entries
        LoginItem.apply(newConfig.launchAtLogin)
        hotkeys.unregisterAll()
        registerHotkeys()
    }

    /// Rebuild menu + icon for current state. Recording shows explicit Stop / Cancel.
    private func refreshUI() {
        let menu = NSMenu()

        // Status header: which engines are active, plus a warning if a chosen local model is missing.
        let engines = menuItem(engineSummary(), nil); engines.isEnabled = false
        menu.addItem(engines)
        if missingLocalModelMessage() != nil {
            menu.addItem(menuItem(NSLocalizedString("Model not downloaded — open Setup", comment: "menu"),
                                  #selector(openMainWindow), symbol: "exclamationmark.triangle.fill"))
        }
        menu.addItem(.separator())

        if let mode = activeMode {
            let label: String = {
                switch mode {
                case .translation: return NSLocalizedString("Translation", comment: "mode name")
                case .rewrite: return NSLocalizedString("Rewrite", comment: "mode name")
                default: return NSLocalizedString("Dictation", comment: "mode name")
                }
            }()
            menu.addItem(menuItem(String(format: NSLocalizedString("Stop & Insert — %@", comment: "menu"), label), #selector(stopAndInsert), symbol: "stop.circle.fill"))
            menu.addItem(menuItem(NSLocalizedString("Cancel (discard)", comment: "menu"), #selector(cancelRecording), symbol: "xmark.circle"))
        } else if isWorking {
            let working = menuItem(NSLocalizedString("Working…", comment: "menu"), nil, symbol: "hourglass"); working.isEnabled = false
            menu.addItem(working)
        } else {
            menu.addItem(menuItem(NSLocalizedString("Start Dictation        ⌃⌥D", comment: "menu"), #selector(toggleDictation), symbol: "mic"))
            menu.addItem(menuItem(NSLocalizedString("Start Translation     ⌃⌥T", comment: "menu"), #selector(toggleTranslation), symbol: "globe"))
            menu.addItem(menuItem(NSLocalizedString("Start Rewrite          ⌃⌥R", comment: "menu"), #selector(toggleRewrite), symbol: "wand.and.stars"))
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
        previewTask?.cancel(); previewTask = nil
        if config.muteAudioWhileRecording { SystemAudio.setMuted(false) }
        overlay.hide()
        activeMode = nil
        slog("recording cancelled")
        refreshUI()
    }

    @objc private func stopAndInsert() { finishRecording() }

    /// Warm the ASR model at launch so first real use isn't a 20-40s mystery wait.
    func prewarm() async {
        slog("prewarming models…")
        _ = try? await asr.transcribe(AudioSamples(samples: [Float](repeating: 0, count: 1600)),
                                      languageHint: config.asrLanguage)
        _ = try? await llm.polish("warm up", context: .none)
        slog("models warm")
    }

    // MARK: Hotkeys / toggle

    @discardableResult
    private func registerHotkeys() -> Int {
        var n = 0
        if hotkeys.register(config.dictationHotkey, onPress: { [weak self] in self?.toggle(.dictation) }) { n += 1 }
        if hotkeys.register(config.translationHotkey, onPress: { [weak self] in
            self?.toggle(.translation(target: self?.config.targetLanguage ?? "en"))
        }) { n += 1 }
        if hotkeys.register(config.rewriteHotkey, onPress: { [weak self] in self?.toggle(.rewrite) }) { n += 1 }
        return n
    }

    @objc private func toggleRewrite() { toggle(.rewrite) }

    @objc private func toggleDictation() { toggle(.dictation) }
    @objc private func toggleTranslation() { toggle(.translation(target: config.targetLanguage)) }

    private func toggle(_ mode: Mode) {
        if activeMode == nil {
            // Fail fast (before recording) if a chosen local model isn't downloaded — clearer than a
            // cryptic mid-pipeline error or a silent multi-GB download.
            if let msg = missingLocalModelMessage() { overlay.showError(msg); return }
            startRecording(mode)
        } else {
            finishRecording()
        }
    }

    /// One-line summary of the active engines for the menu-bar status header.
    private func engineSummary() -> String {
        func loc(_ l: ProviderLocation) -> String {
            l == .local ? NSLocalizedString("Local", comment: "engine location") : NSLocalizedString("Cloud", comment: "engine location")
        }
        let ai = config.llm.location == .local ? Self.shortLLMName(config.llm.modelID) : NSLocalizedString("Cloud", comment: "engine location")
        return String(format: NSLocalizedString("Speech: %@ · AI: %@", comment: "menu engine summary"),
                      loc(config.asr.location), ai)
    }

    /// "mlx-community/Qwen3-4B-4bit" -> "Qwen3 4B" for compact display.
    private static func shortLLMName(_ id: String) -> String {
        id.replacingOccurrences(of: "mlx-community/", with: "")
          .replacingOccurrences(of: "-4bit", with: "")
          .replacingOccurrences(of: "-", with: " ")
    }

    /// If a stage is set to a local engine whose model isn't on disk, an actionable message; else nil.
    private func missingLocalModelMessage() -> String? {
        let root = SetupModel.modelsRoot
        if config.asr.location == .local,
           !SetupModel.dirNonEmpty(root.appendingPathComponent("argmaxinc/whisperkit-coreml")) {
            return NSLocalizedString("Speech model not downloaded — open Settings → Setup.", comment: "missing model")
        }
        if config.llm.location == .local {
            let cfg = root.appendingPathComponent(config.llm.modelID).appendingPathComponent("config.json")
            if !FileManager.default.fileExists(atPath: cfg.path) {
                return NSLocalizedString("AI model not downloaded — open Settings → Setup.", comment: "missing model")
            }
        }
        return nil
    }

    private func startRecording(_ mode: Mode) {
        capture.onLevel = { [weak self] lvl in DispatchQueue.main.async { self?.overlay.updateLevel(lvl) } }
        capture.preferBuiltInMic = config.preferBuiltInMic
        do {
            try capture.start()
            activeMode = mode
            let label: String = {
                switch mode {
                case .translation: return NSLocalizedString("Translating", comment: "overlay label")
                case .rewrite: return NSLocalizedString("Rewrite — speak instruction", comment: "overlay label")
                default: return NSLocalizedString("Recording", comment: "overlay label")
                }
            }()
            overlay.show(label: label)
            if config.soundsEnabled { SoundFx.start() }
            if config.muteAudioWhileRecording { SystemAudio.setMuted(true) }
            if config.showLivePreview { startPreviewLoop() }
            slog("recording started")
            refreshUI()
        } catch {
            capture.onLevel = nil
            slog("capture.start failed: \(error)")
            NSSound.beep()
        }
    }

    /// Calm, user-facing message for a pipeline failure (technical detail stays in the log).
    static func friendlyError(_ error: Error) -> String {
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

    private func finishRecording() {
        guard let mode = activeMode else { return }
        let audio = capture.stop()
        capture.onLevel = nil
        previewTask?.cancel(); previewTask = nil
        if config.muteAudioWhileRecording { SystemAudio.setMuted(false) }
        overlay.showProcessing()
        activeMode = nil
        isWorking = true
        slog("recording stopped, \(String(format: "%.1f", audio.duration))s audio, running pipeline…")
        refreshUI()

        // Resolve App Profile tone from the foreground app (where text will land).
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var context = config.appProfiles.context(bundleID: bundleID, url: nil)
        context.userProfile = config.userProfile.isEmpty ? nil : config.userProfile

        let orch = PipelineOrchestrator(asr: asr, llm: llm, dictionary: config.dictionary)
        Task { @MainActor in
            defer { self.isWorking = false; self.refreshUI() }
            do {
                let result: PipelineResult
                if case .rewrite = mode {
                    let instruction = try await self.asr.transcribe(audio.trimmedSilence(), languageHint: self.config.asrLanguage)
                    let selection = InsertionService.grabSelection()
                    let out = try await self.llm.rewrite(instruction, selection: selection, context: context)
                    result = PipelineResult(text: out, rawTranscript: "[rewrite] " + instruction, elapsed: 0)
                } else {
                    result = try await orch.run(audio, mode: mode, context: context,
                                                languageHint: self.config.asrLanguage)
                }
                slog("RAW: '\(result.rawTranscript)'")
                slog("pipeline done -> '\(result.text)' (\(String(format: "%.2f", result.elapsed))s)")
                let finalText = self.config.voiceCommandsEnabled ? VoiceCommands.apply(result.text) : result.text
                // No speech captured: don't insert an empty/garbage result or save an empty history row.
                guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    slog("pipeline produced empty text — skipping insert")
                    self.overlay.showError(NSLocalizedString("No speech detected — try again.", comment: "empty result"))
                    return
                }
                // Save to history BEFORE inserting, so text is recoverable even if paste fails.
                let modeStr: String = {
                    switch mode { case .translation: return "translation"; case .rewrite: return "rewrite"; default: return "dictation" }
                }()
                let id = UUID()
                var audioFile: String? = nil
                if !audio.samples.isEmpty {
                    let name = "\(id).wav"
                    try? FileManager.default.createDirectory(at: self.historyStore.audioDirectory, withIntermediateDirectories: true)
                    if (try? audio.wavData().write(to: self.historyStore.audioURL(name))) != nil { audioFile = name }
                }
                self.historyStore.append(HistoryEntry(id: id, date: Date(), mode: modeStr,
                                                      raw: result.rawTranscript, text: finalText, audioFile: audioFile))
                self.historyModel.refresh()
                InsertionService.insert(finalText, autoCopy: self.config.autoCopyToClipboard)
                if self.config.soundsEnabled { SoundFx.done() }
                self.overlay.showDone(self.config.autoCopyToClipboard
                    ? NSLocalizedString("Inserted · on clipboard", comment: "dictation done toast, auto-copy on")
                    : NSLocalizedString("Inserted", comment: "dictation done toast"))
            } catch {
                slog("pipeline error: \(error)")
                NSSound.beep()
                self.overlay.showError(Self.friendlyError(error))
            }
        }
    }
}
