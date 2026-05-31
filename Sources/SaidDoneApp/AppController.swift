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
        let n = registerHotkeys()
        slog("launched, \(n) hotkeys registered")
        Permissions.accessibilityTrusted(prompt: true)
        LoginItem.apply(config.launchAtLogin)
        Task {
            _ = await Permissions.requestMicrophone()
            await prewarm()
        }
    }

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

    private var settingsWindow: NSWindow?
    private var mainWindow: NSWindow?

    @objc private func openMainWindow() {
        if let win = mainWindow {
            historyModel.refresh()
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        historyModel.refresh()
        setupModel.refresh()
        let win = NSWindow(contentViewController: NSHostingController(rootView: MainView(history: historyModel, setup: setupModel)))
        win.title = "SaidDone"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        mainWindow = win
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettings() {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = ConfigModel(config: config) { [weak self] newConfig in
            self?.applyConfig(newConfig)
        }
        let win = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        win.title = "SaidDone Settings"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        settingsWindow = win
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Merge auto-learned correction terms into the dictionary (from a History edit).
    private func learnTerms(_ terms: [DictionaryEntry]) {
        var cfg = config
        var byKey = Dictionary(cfg.dictionary.entries.map { ($0.wrong, $0) }) { a, _ in a }
        for t in terms { byKey[t.wrong] = t }
        cfg.dictionary.entries = byKey.values.sorted { $0.wrong < $1.wrong }
        applyConfig(cfg)
        slog("learned dictionary terms: \(terms.map { "\($0.wrong)->\($0.right)" }.joined(separator: ","))")
    }

    /// Persist edited config and rebuild providers so changes take effect immediately.
    private func applyConfig(_ newConfig: AppConfig) {
        config = newConfig
        try? configStore.save(newConfig)
        asr = ProviderFactory.makeASR(newConfig)
        llm = ProviderFactory.makeLLM(newConfig)
        setupModel.llmModelID = newConfig.llm.modelID
        LoginItem.apply(newConfig.launchAtLogin)
        hotkeys.unregisterAll()
        registerHotkeys()
    }

    /// Rebuild menu + icon for current state. Recording shows explicit Stop / Cancel.
    private func refreshUI() {
        let menu = NSMenu()
        if let mode = activeMode {
            let label: String = { if case .translation = mode { return "Translation" } else { return "Dictation" } }()
            menu.addItem(menuItem("Stop & Insert — \(label)", #selector(stopAndInsert), symbol: "stop.circle.fill"))
            menu.addItem(menuItem("Cancel (discard)", #selector(cancelRecording), symbol: "xmark.circle"))
        } else if isWorking {
            let working = menuItem("Working…", nil, symbol: "hourglass"); working.isEnabled = false
            menu.addItem(working)
        } else {
            menu.addItem(menuItem("Start Dictation        ⌃⌥D", #selector(toggleDictation), symbol: "mic"))
            menu.addItem(menuItem("Start Translation     ⌃⌥T", #selector(toggleTranslation), symbol: "globe"))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Open SaidDone…", #selector(openMainWindow), symbol: "macwindow"))
        menu.addItem(menuItem("Settings…", #selector(openSettings), symbol: "gearshape"))
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
        return n
    }

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
            let label: String = { if case .translation = mode { return "Translating" } else { return "Recording" } }()
            overlay.show(label: label)
            slog("recording started")
            refreshUI()
        } catch {
            capture.onLevel = nil
            slog("capture.start failed: \(error)")
            NSSound.beep()
        }
    }

    private func finishRecording() {
        guard let mode = activeMode else { return }
        let audio = capture.stop()
        capture.onLevel = nil
        overlay.showProcessing()
        activeMode = nil
        isWorking = true
        slog("recording stopped, \(String(format: "%.1f", audio.duration))s audio, running pipeline…")
        refreshUI()

        // Resolve App Profile tone from the foreground app (where text will land).
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let context = config.appProfiles.context(bundleID: bundleID, url: nil)

        let orch = PipelineOrchestrator(asr: asr, llm: llm, dictionary: config.dictionary)
        Task { @MainActor in
            defer { self.isWorking = false; self.overlay.hide(); self.refreshUI() }
            do {
                let result = try await orch.run(audio, mode: mode, context: context,
                                                languageHint: self.config.asrLanguage)
                slog("RAW: '\(result.rawTranscript)'")
                slog("pipeline done -> '\(result.text)' (\(String(format: "%.2f", result.elapsed))s)")
                // Save to history BEFORE inserting, so text is recoverable even if paste fails.
                let modeStr: String = { if case .translation = mode { return "translation" } else { return "dictation" } }()
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
            } catch {
                slog("pipeline error: \(error)")
                NSSound.beep()
            }
        }
    }
}
