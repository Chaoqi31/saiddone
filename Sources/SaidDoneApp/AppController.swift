import AppKit
import SwiftUI
import SaidDoneCore
import SaidDoneProviders

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
        registerHotkeys()
        Permissions.accessibilityTrusted(prompt: true)
        Task { _ = await Permissions.requestMicrophone() }
    }

    // MARK: UI

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        let menu = NSMenu()
        menu.addItem(withTitle: "Dictation (toggle)", action: #selector(toggleDictation), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Translation (toggle)", action: #selector(toggleTranslation), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit SaidDone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
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

    private func updateStatusIcon() {
        let recording = activeMode != nil
        let name = recording ? "mic.fill" : "mic"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "SaidDone")
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    // MARK: Hotkeys / toggle

    private func registerHotkeys() {
        hotkeys.register(config.dictationHotkey) { [weak self] in self?.toggle(.dictation) }
        hotkeys.register(config.translationHotkey) { [weak self] in
            self?.toggle(.translation(target: self?.config.targetLanguage ?? "en"))
        }
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
            updateStatusIcon()
        } catch {
            NSSound.beep()
        }
    }

    private func finishRecording() {
        guard let mode = activeMode else { return }
        let audio = capture.stop()
        activeMode = nil
        updateStatusIcon()

        // Resolve App Profile tone from the foreground app (where text will land).
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let context = config.appProfiles.context(bundleID: bundleID, url: nil)

        let orch = PipelineOrchestrator(asr: asr, llm: llm, dictionary: config.dictionary)
        Task { @MainActor in
            do {
                let result = try await orch.run(audio, mode: mode, context: context)
                InsertionService.insert(result.text)
            } catch {
                NSSound.beep()
            }
        }
    }
}
