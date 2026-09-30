import AppKit
import Observation
import SaidDoneCore
import SaidDoneEngines

/// The only type that knows every part. It builds the stores and services, hands AppKit to `Windows`, and applies
/// the settings that act outside a job. Jobs read settings themselves when they run, so an edit reaches the next job
/// without any wiring here.
@MainActor
final class AppRoot: NSObject, NSApplicationDelegate {
    let settings: SettingsStore
    let localization: Localization
    let vault: Vault
    let dictionary: DictionaryStore
    let history: HistoryStore
    let historyModel: HistoryModel
    let library: ModelLibrary
    let engines: Engines
    let permissions: PermissionsModel
    let setup: SetupStatus
    let hotkeys: HotkeyTap
    let recorder: Recorder
    let inserter: Inserter
    let answers: AnswerPanel
    let dictation: Dictation
    let loginItem = LoginItem()
    let navigation = Navigation()
    private(set) var windows: Windows!

    init(paths: AppPaths = .standard, keychain: KeychainItem? = KeychainItem()) {
        settings = SettingsStore(url: paths.settings)
        localization = Localization(settings.prefs.interfaceLanguage)
        vault = Vault(item: keychain)
        dictionary = DictionaryStore(url: paths.dictionary)
        history = HistoryStore(folder: paths.history)
        historyModel = HistoryModel(store: history)
        library = ModelLibrary(files: paths.models)
        engines = Engines(files: paths.models)
        permissions = PermissionsModel()
        setup = SetupStatus(settings: settings, vault: vault, library: library, permissions: permissions)
        hotkeys = HotkeyTap(settings.prefs.shortcuts)
        recorder = Recorder()
        inserter = Inserter()
        answers = AnswerPanel(inserter: inserter)
        dictation = Dictation(settings: settings, vault: vault, dictionary: dictionary, history: history,
                              engines: engines, recorder: recorder, inserter: inserter, answers: answers, setup: setup)
        super.init()
        windows = Windows(root: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let atLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
        windows.install()
        vault.load()
        Task { await history.recover(retention: settings.prefs.historyRetention) }
        Task { await dictation.run(hotkeys.gestures) }
        react()
        if !settings.prefs.onboardingCompleted {
            windows.showOnboarding()
        } else if !atLogin {
            windows.showMain()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if settings.prefs.onboardingCompleted { windows.showMain() } else { windows.showOnboarding() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A recording in progress is dropped rather than left muting the Mac's output.
    func applicationWillTerminate(_ notification: Notification) {
        dictation.cancel()
    }

    /// What the user does about an issue, wherever it is shown.
    func fix(_ issue: Issue) {
        switch issue {
        case .microphoneNotAllowed:
            Task { await permissions.requestMicrophone() }
        case .accessibilityNotAllowed:
            permissions.requestAccessibility()
        case .globeKeyAssigned:
            permissions.openKeyboardSettings()
        case let .modelNotInstalled(model):
            library.download(model, mirror: settings.prefs.downloadMirror)
            if settings.prefs.onboardingCompleted { windows.showMain(.engines) }
        case .credentialMissing, .speechModelNotChosen, .aiModelNotChosen:
            if settings.prefs.onboardingCompleted { windows.showMain(.engines) } else { windows.showOnboarding() }
        }
    }

    func finishOnboarding() {
        settings.prefs.onboardingCompleted = true
        windows.closeOnboarding()
        windows.showMain(.home)
    }

    // MARK: - Settings that act immediately

    private struct Warmup: Equatable {
        let setup: EngineSetup
        let installed: Set<LocalModel>
    }

    private func react() {
        Observe.track { self.settings.prefs.shortcuts } apply: { self.hotkeys.update($0) }
        // The tap can only start once Accessibility is granted, which macOS doesn't announce.
        Observe.track { self.permissions.accessibility } apply: { if $0 { self.hotkeys.start() } }
        // Esc is swallowed only while it cancels or closes something.
        Observe.track { self.dictation.isBusy || self.answers.isVisible } apply: { self.hotkeys.escapeIsLive = $0 }
        Observe.track { self.settings.prefs.interfaceLanguage } apply: { self.localization.apply($0) }
        Observe.track { self.settings.prefs.appearance } apply: { NSApp.appearance = $0.nsAppearance }
        Observe.track { self.settings.prefs.showInDock } apply: { inDock in
            NSApp.setActivationPolicy(inDock ? .regular : .accessory)
            // Leaving the Dock deactivates the app; keep the window the user is looking at in front.
            if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { NSApp.activate() }
        }
        Observe.track { self.settings.prefs.historyRetention } apply: { retention in
            Task { await self.history.prune(retention) }
        }
        // Loads the chosen models ahead of the first job, again whenever the choice changes or a download lands.
        Observe.track { () -> Warmup? in
            guard self.vault.state != .loading else { return nil }
            return Warmup(setup: EngineSetup(self.settings.prefs, key: self.vault.key), installed: self.library.installed)
        } apply: { warmup in
            guard let warmup else { return }
            Task { await self.engines.prewarm(warmup.setup) }
        }
    }
}

/// The main window's sidebar.
enum Pane: String, CaseIterable, Identifiable, Hashable {
    case home, history, dictionary
    case general, shortcuts, microphone, engines, personalization

    var id: String { rawValue }

    static let top: [Pane] = [.home, .history, .dictionary]
    static let settings: [Pane] = [.general, .shortcuts, .microphone, .engines, .personalization]

    var title: String {
        switch self {
        case .home: tr("Home")
        case .history: tr("History")
        case .dictionary: tr("Dictionary")
        case .general: tr("General")
        case .shortcuts: tr("Shortcuts")
        case .microphone: tr("Microphone")
        case .engines: tr("Speech & AI")
        case .personalization: tr("Personalization")
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .history: "clock"
        case .dictionary: "character.book.closed"
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .microphone: "mic"
        case .engines: "cpu"
        case .personalization: "person.crop.circle"
        }
    }
}

@MainActor @Observable
final class Navigation {
    var pane: Pane = .home
}
