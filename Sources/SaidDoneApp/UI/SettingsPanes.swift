import AppKit
import SaidDoneCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - General

struct GeneralPane: View {
    let root: AppRoot

    var body: some View {
        @Bindable var settings = root.settings
        Form {
            Section {
                Picker(tr("Language"), selection: $settings.prefs.interfaceLanguage) {
                    ForEach(InterfaceLanguage.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
                }
                Picker(tr("Appearance"), selection: $settings.prefs.appearance) {
                    ForEach(Appearance.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
                }
                Toggle(tr("Show in Dock"), isOn: $settings.prefs.showInDock)
                Toggle(tr("Open at login"), isOn: Binding(get: { root.loginItem.enabled }, set: { root.loginItem.set($0) }))
                if root.loginItem.needsApproval {
                    Text(tr("Allow SaidDone in System Settings → General → Login Items."))
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section(tr("While recording")) {
                Toggle(tr("Play sounds"), isOn: $settings.prefs.sounds)
                Toggle(isOn: $settings.prefs.muteWhileRecording) {
                    Text(tr("Mute other audio"))
                    Text(tr("Sound from other apps is muted while you talk, so it doesn’t get transcribed."))
                }
            }
            Section(tr("History")) {
                Picker(tr("Keep history"), selection: $settings.prefs.historyRetention) {
                    ForEach(Retention.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
                }
                Toggle(isOn: $settings.prefs.learnFromCorrections) {
                    Text(tr("Learn from my corrections"))
                    Text(tr("When you fix a word right after SaidDone types it, the fix is added to your dictionary."))
                }
            }
            Section {
                LabeledContent(tr("Version"), value: Self.version)
                HStack {
                    Button(tr("Setup Assistant…")) { root.windows.showOnboarding() }
                    Button(tr("Show Data Folder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.standard.root])
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}

// MARK: - Shortcuts

struct ShortcutsPane: View {
    let root: AppRoot
    @State private var recording: Mode?
    @State private var moved: String?

    var body: some View {
        Form {
            let issues = root.setup.issues.filter { $0 == .accessibilityNotAllowed || $0 == .globeKeyAssigned }
            if !issues.isEmpty {
                Section {
                    ForEach(issues, id: \.self) { IssueRow(issue: $0, library: root.library, fix: root.fix) }
                }
            }
            ForEach(Mode.allCases, id: \.self) { mode in
                Section {
                    ForEach(root.settings.prefs.shortcuts.triggers(for: mode), id: \.self) { trigger in
                        HStack {
                            Keycaps(trigger: trigger)
                            Spacer()
                            Button { root.settings.prefs.shortcuts.unbind(trigger) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(tr("Remove"))
                            .accessibilityLabel(tr("Remove %@", trigger.label))
                        }
                    }
                    if recording == mode {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(tr("Press a key, a key combination or a mouse button…"))
                            Spacer()
                            Button(tr("Cancel")) { root.hotkeys.cancelCapture() }
                        }
                    } else {
                        Button(tr("Add Shortcut…")) { record(mode) }
                            .disabled(recording != nil || !root.permissions.accessibility)
                    }
                } header: {
                    Text(verbatim: mode.title)
                } footer: {
                    Text(verbatim: mode.summary)
                }
            }
            Section {
                if let moved { Text(verbatim: moved).foregroundStyle(.orange) }
                Text(tr("Tap a shortcut to talk hands-free, and tap it again to finish. Hold it to talk, and let go to finish. While holding fn, add ⇧ or ⌃ to switch to Translation or Ask."))
                    .font(.callout).foregroundStyle(.secondary)
                Button(tr("Restore Default Shortcuts")) {
                    root.settings.prefs.shortcuts = .default
                    moved = nil
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { root.hotkeys.cancelCapture() }
    }

    private func record(_ mode: Mode) {
        recording = mode
        moved = nil
        Task {
            defer { recording = nil }
            guard let trigger = await root.hotkeys.captureNextTrigger() else { return }
            if let previous = root.settings.prefs.shortcuts.bind(trigger, to: mode) {
                moved = tr("%@ moved from %@ to %@.", trigger.label, previous.title, mode.title)
            }
        }
    }
}

// MARK: - Microphone

struct MicrophonePane: View {
    let root: AppRoot

    var body: some View {
        @Bindable var settings = root.settings
        Form {
            if root.permissions.microphone != .authorized {
                Section { IssueRow(issue: .microphoneNotAllowed, library: root.library, fix: root.fix) }
            }
            Section {
                Picker(tr("Microphone"), selection: $settings.prefs.microphone) {
                    Text(tr("Automatic")).tag(MicrophoneChoice.automatic)
                    ForEach(root.recorder.devices) { device in
                        Text(verbatim: device.name).tag(MicrophoneChoice.device(uid: device.id, name: device.name))
                    }
                    if case let .device(uid, name) = settings.prefs.microphone,
                       !root.recorder.devices.contains(where: { $0.id == uid }) {
                        Text(tr("%@ (not connected)", name)).tag(settings.prefs.microphone)
                    }
                }
                LabeledContent(tr("Input level")) {
                    LevelMeter(levels: root.recorder.levels)
                }
            } footer: {
                Text(tr("Automatic uses the system’s input, except a Bluetooth headset: its microphone sounds worse, and using it drops the headset’s audio to call quality. The Mac’s own microphone is used instead."))
            }
        }
        .formStyle(.grouped)
        .onAppear { root.recorder.startMeter(settings.prefs.microphone) }
        .onDisappear { root.recorder.stopMeter() }
        .onChange(of: settings.prefs.microphone) { _, choice in root.recorder.startMeter(choice) }
    }
}

private struct LevelMeter: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geometry in
            let level = CGFloat(levels.suffix(4).max() ?? 0)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(.green.gradient).frame(width: max(4, geometry.size.width * level))
            }
        }
        .frame(width: 180, height: 6)
        .animation(.easeOut(duration: 0.1), value: levels)
        .accessibilityHidden(true)
    }
}

// MARK: - Personalization

struct PersonalizationPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                TextEditor(text: $settings.prefs.personalization.profile)
                    .font(.body)
                    .frame(minHeight: 70)
            } header: {
                Text(tr("About you"))
            } footer: {
                Text(tr("Helps the AI get your field’s words right. For example: “iOS developer, I mix English tech terms into Chinese.”"))
            }
            Section {
                TextField(tr("Tone"), text: $settings.prefs.personalization.defaultTone,
                          prompt: Text(tr("For example: friendly and concise")))
            } header: {
                Text(tr("Tone"))
            } footer: {
                Text(tr("How your text should sound. Leave it empty to keep the tone you speak in."))
            }
            Section {
                ForEach(apps, id: \.self) { bundleID in
                    HStack {
                        if let icon = Apps.icon(bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        }
                        Text(verbatim: Apps.name(bundleID)).frame(width: 140, alignment: .leading)
                        TextField(tr("Tone"), text: tone(bundleID), prompt: Text(tr("For example: formal")))
                            .labelsHidden()
                        Button { settings.prefs.personalization.toneByApp[bundleID] = nil } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(tr("Remove"))
                    }
                }
                Button(tr("Add App…"), action: addApp)
            } header: {
                Text(tr("Tone in specific apps"))
            } footer: {
                Text(tr("For example, formal in Mail and casual in Messages."))
            }
        }
        .formStyle(.grouped)
    }

    private var apps: [String] {
        settings.prefs.personalization.toneByApp.keys.sorted { Apps.name($0) < Apps.name($1) }
    }

    private func tone(_ bundleID: String) -> Binding<String> {
        Binding(get: { settings.prefs.personalization.toneByApp[bundleID] ?? "" },
                set: { settings.prefs.personalization.toneByApp[bundleID] = $0 })
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier,
              settings.prefs.personalization.toneByApp[bundleID] == nil
        else { return }
        settings.prefs.personalization.toneByApp[bundleID] = ""
    }
}
