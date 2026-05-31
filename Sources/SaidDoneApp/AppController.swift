import AppKit
import SaidDoneCore

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

    // Providers. Default = local Echo placeholders until real engines (WhisperKit/MLX) are wired.
    private var asr: ASRProvider = EchoASRProvider(preset: "")
    private var llm: LLMProvider = EchoLLMProvider()

    override init() {
        let dir = (try? ConfigStore.defaultDirectory()) ?? FileManager.default.temporaryDirectory
        self.configStore = ConfigStore(directory: dir)
        self.config = configStore.load()
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
        menu.addItem(withTitle: "Quit SaidDone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
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
