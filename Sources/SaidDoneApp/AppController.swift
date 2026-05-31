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

    override init() {
        let dir = (try? ConfigStore.defaultDirectory()) ?? FileManager.default.temporaryDirectory
        let store = ConfigStore(directory: dir)
        let cfg = store.load()
        self.configStore = store
        self.config = cfg
        self.asr = ProviderFactory.makeASR(cfg)
        self.llm = ProviderFactory.makeLLM(cfg)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        let n = registerHotkeys()
        slog("launched, \(n) hotkeys registered")
        Permissions.accessibilityTrusted(prompt: true)
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

    private func menuItem(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    private var settingsWindow: NSWindow?

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

    /// Persist edited config and rebuild providers so changes take effect immediately.
    private func applyConfig(_ newConfig: AppConfig) {
        config = newConfig
        try? configStore.save(newConfig)
        asr = ProviderFactory.makeASR(newConfig)
        llm = ProviderFactory.makeLLM(newConfig)
    }

    /// Rebuild menu + icon for current state. Recording shows explicit Stop / Cancel.
    private func refreshUI() {
        let menu = NSMenu()
        if let mode = activeMode {
            let label: String = { if case .translation = mode { return "Translation" } else { return "Dictation" } }()
            menu.addItem(menuItem("● Recording \(label) — click to Stop & Insert", #selector(stopAndInsert)))
            menu.addItem(menuItem("✕ Cancel (discard)", #selector(cancelRecording)))
        } else {
            menu.addItem(menuItem(isWorking ? "⏳ Working…" : "Start Dictation  (⌃⌥D)", #selector(toggleDictation)))
            menu.addItem(menuItem("Start Translation  (⌃⌥T)", #selector(toggleTranslation)))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", #selector(openSettings)))
        menu.addItem(withTitle: "Quit SaidDone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        let recording = activeMode != nil
        let name = recording ? "mic.fill" : (isWorking ? "hourglass" : "mic")
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "SaidDone")
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    private func updateStatusIcon() { refreshUI() }

    /// Stop capture and discard — instant mic release, no pipeline.
    @objc private func cancelRecording() {
        guard activeMode != nil else { return }
        _ = capture.stop()
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
        do {
            try capture.start()
            activeMode = mode
            slog("recording started")
            refreshUI()
        } catch {
            slog("capture.start failed: \(error)")
            NSSound.beep()
        }
    }

    private func finishRecording() {
        guard let mode = activeMode else { return }
        let audio = capture.stop()
        activeMode = nil
        isWorking = true
        slog("recording stopped, \(String(format: "%.1f", audio.duration))s audio, running pipeline…")
        refreshUI()

        // Resolve App Profile tone from the foreground app (where text will land).
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let context = config.appProfiles.context(bundleID: bundleID, url: nil)

        let orch = PipelineOrchestrator(asr: asr, llm: llm, dictionary: config.dictionary)
        Task { @MainActor in
            defer { self.isWorking = false; self.refreshUI() }
            do {
                let result = try await orch.run(audio, mode: mode, context: context,
                                                languageHint: self.config.asrLanguage)
                slog("pipeline done -> '\(result.text)' (\(String(format: "%.2f", result.elapsed))s)")
                InsertionService.insert(result.text)
            } catch {
                slog("pipeline error: \(error)")
                NSSound.beep()
            }
        }
    }
}
