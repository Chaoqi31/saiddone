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

    /// Which Mode is currently recording, nil = idle. Toggle (ADR-0006).
    private var activeMode: Mode?

    // Providers built from config: local ASR ladder (Qwen3-ASR→0.6B→WhisperKit) + LLM ladder (MLX→RuleBased).
    private var asr: ASRProvider
    private var llm: LLMProvider
    private let historyStore: HistoryStore
    private lazy var historyModel = HistoryModel(store: historyStore)
    private let overlay = RecordingOverlay()
    private lazy var setupModel: SetupModel = {
        let m = SetupModel()
        m.llmModelID = config.llm.modelID
        m.onPrepare = { [weak self] in await self?.prewarm() }
        return m
    }()
    private lazy var dictionaryModel = DictionaryModel(
        entries: config.dictionary.entries,
        onChange: { [weak self] entries in self?.saveDictionary(entries) }
    )
    private lazy var configModel = ConfigModel(config: config) { [weak self] newConfig in
        self?.applyConfig(newConfig)
    }

    override init() {
        let dir = (try? ConfigStore.defaultDirectory()) ?? FileManager.default.temporaryDirectory
        let store = ConfigStore(directory: dir)
        let cfg = store.load()
        self.configStore = store
        self.config = cfg
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
        slog("launched, \(n) hotkeys registered")
        Permissions.accessibilityTrusted(prompt: true)
        LoginItem.apply(config.launchAtLogin)
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
        let win = NSWindow(contentViewController: NSHostingController(
            rootView: MainView(history: historyModel, dictionary: dictionaryModel, config: configModel, setup: setupModel)))
        win.title = "SaidDone"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 980, height: 680))   // fixed start size; user can resize
        mainWindow = win
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        if let mode = activeMode {
            let label: String = {
                switch mode { case .translation: return "Translation"; case .rewrite: return "Rewrite"; default: return "Dictation" }
            }()
            menu.addItem(menuItem("Stop & Insert — \(label)", #selector(stopAndInsert), symbol: "stop.circle.fill"))
            menu.addItem(menuItem("Cancel (discard)", #selector(cancelRecording), symbol: "xmark.circle"))
        } else if isWorking {
            let working = menuItem("Working…", nil, symbol: "hourglass"); working.isEnabled = false
            menu.addItem(working)
        } else {
            menu.addItem(menuItem("Start Dictation        ⌃⌥D", #selector(toggleDictation), symbol: "mic"))
            menu.addItem(menuItem("Start Translation     ⌃⌥T", #selector(toggleTranslation), symbol: "globe"))
            menu.addItem(menuItem("Start Rewrite          ⌃⌥R", #selector(toggleRewrite), symbol: "wand.and.stars"))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Open SaidDone…", #selector(openMainWindow), symbol: "macwindow"))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit SaidDone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
            startRecording(mode)
        } else {
            finishRecording()
        }
    }

    private func startRecording(_ mode: Mode) {
        capture.onLevel = { [weak self] lvl in DispatchQueue.main.async { self?.overlay.updateLevel(lvl) } }
        do {
            try capture.start()
            activeMode = mode
            let label: String = {
                switch mode { case .translation: return "Translating"; case .rewrite: return "Rewrite — speak instruction"; default: return "Recording" }
            }()
            overlay.show(label: label)
            if config.soundsEnabled { SoundFx.start() }
            if config.muteAudioWhileRecording { SystemAudio.setMuted(true) }
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
            return "网络不可用，请检查连接后重试。"
        }
        if let pe = error as? ProviderError {
            switch pe {
            case .notConfigured: return "云端未配置，请在 Settings → Cloud 填写 Key。"
            case .modelUnavailable: return "引擎暂不可用，请稍后重试。"
            case .latencyBudgetExceeded: return "处理超时，请重试。"
            }
        }
        if s.contains("401") || s.contains("403") || s.contains("unauthor") || s.contains("api key") {
            return "云端 Key 无效，请在 Settings → Cloud 检查。"
        }
        return "转写失败，请重试。"
    }

    private func finishRecording() {
        guard let mode = activeMode else { return }
        let audio = capture.stop()
        capture.onLevel = nil
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
                                                      raw: result.rawTranscript, text: result.text, audioFile: audioFile))
                self.historyModel.refresh()
                InsertionService.insert(result.text, autoCopy: self.config.autoCopyToClipboard)
                if self.config.soundsEnabled { SoundFx.done() }
                self.overlay.hide()
            } catch {
                slog("pipeline error: \(error)")
                NSSound.beep()
                self.overlay.showError(Self.friendlyError(error))
            }
        }
    }
}
