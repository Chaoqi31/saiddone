import AVFoundation
import SaidDoneCore
import SwiftUI

/// First run: language, permissions, engines, shortcuts, then a real dictation into a text box. Every step edits the
/// live settings, so there is nothing to apply at the end.
struct OnboardingView: View {
    let root: AppRoot
    @State private var step: Step

    enum Step: Int, CaseIterable {
        case welcome, permissions, engines, shortcuts, tryIt
    }

    init(root: AppRoot, step: Step = .welcome) {
        self.root = root
        _step = State(initialValue: step)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: WelcomeStep(root: root)
                case .permissions: PermissionsStep(root: root)
                case .engines: EnginesStep(root: root)
                case .shortcuts: ShortcutsStep(root: root)
                case .tryIt: TryItStep(root: root)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(Step.allCases, id: \.self) { item in
                        Circle()
                            .fill(item == step ? Color.accentColor : Color.primary.opacity(0.2))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityHidden(true)
                Spacer()
                if let previous = Step(rawValue: step.rawValue - 1) {
                    Button(tr("Back")) { step = previous }
                }
                if let next = Step(rawValue: step.rawValue + 1) {
                    Button(tr("Continue")) { step = next }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue)
                } else {
                    Button(tr("Done"), action: root.finishOnboarding)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 680, height: 560)
    }

    private var canContinue: Bool {
        let issues = root.setup.issues
        switch step {
        case .permissions:
            return !issues.contains(.microphoneNotAllowed) && !issues.contains(.accessibilityNotAllowed)
        case .engines:
            // A model still downloading is fine: the last step waits for it.
            return issues.allSatisfy { issue in
                switch issue {
                case let .modelNotInstalled(model): root.library.isDownloading(model)
                case .credentialMissing, .speechModelNotChosen, .aiModelNotChosen, .onDeviceAIUnavailable: false
                default: true
                }
            }
        case .welcome, .shortcuts, .tryIt:
            return true
        }
    }
}

private struct StepHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(.title.bold())
            Text(verbatim: detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomeStep: View {
    let root: AppRoot

    var body: some View {
        @Bindable var settings = root.settings
        VStack(alignment: .leading, spacing: 24) {
            BrandMark(size: 72)
            StepHeader(title: tr("Welcome to SaidDone"),
                       detail: tr("Talk instead of typing. SaidDone turns what you say into clean, punctuated text, right where your cursor is, in any app."))
            Form {
                Picker(tr("Language"), selection: $settings.prefs.interfaceLanguage) {
                    ForEach(InterfaceLanguage.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
                }
                Picker(tr("I speak"), selection: $settings.prefs.spokenLanguage) {
                    Text(tr("Detect automatically")).tag(SpokenLanguage.detect)
                    ForEach(Language.spoken) { Text(verbatim: $0.endonym).tag(SpokenLanguage.fixed($0)) }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(maxWidth: 420)
        }
        .padding(32)
    }
}

private struct PermissionsStep: View {
    let root: AppRoot

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(title: tr("Allow access"),
                       detail: tr("SaidDone needs to hear you and to type into other apps. Nothing leaves your Mac unless you choose a cloud engine."))
            VStack(spacing: 12) {
                PermissionRow(title: tr("Microphone"), detail: tr("To hear what you say."),
                              granted: root.permissions.microphone == .authorized) {
                    root.fix(.microphoneNotAllowed)
                }
                PermissionRow(title: tr("Accessibility"),
                              detail: tr("For the shortcuts, and to put text where you type. macOS opens System Settings: turn on SaidDone there, then come back."),
                              granted: root.permissions.accessibility) {
                    root.fix(.accessibilityNotAllowed)
                }
                if root.settings.prefs.shortcuts.usesFn {
                    PermissionRow(title: tr("The 🌐 key"),
                                  detail: tr("Optional. In Keyboard settings, set “Press 🌐 key to” to “Do Nothing”, so fn only starts SaidDone."),
                                  granted: root.permissions.globeKeyFree, action: tr("Open Keyboard Settings")) {
                        root.fix(.globeKeyAssigned)
                    }
                }
            }
        }
        .padding(32)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    var action = tr("Allow")
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2)
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.headline)
                Text(verbatim: detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted { Button(action, action: perform) }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct EnginesStep: View {
    let root: AppRoot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StepHeader(title: tr("Choose your engines"),
                       detail: tr("One engine turns speech into words, the other cleans them up. The defaults work well; you can change them any time."))
                .padding([.horizontal, .top], 32)
            Form {
                SpeechSection(root: root)
                AISection(root: root)
            }
            .formStyle(.grouped)
        }
    }
}

private struct ShortcutsStep: View {
    let root: AppRoot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StepHeader(title: tr("Your shortcuts"),
                       detail: tr("Each mode has its own shortcut. Keep these, or add your own."))
                .padding([.horizontal, .top], 32)
            ShortcutsPane(root: root)
        }
    }
}

private struct TryItStep: View {
    let root: AppRoot
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: tr("Try it"), detail: instructions)
            TextEditor(text: $text)
                .font(.title3)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
                .frame(height: 170)
            status
        }
        .padding(32)
        .onAppear { focused = true }
    }

    private var instructions: String {
        guard let trigger = root.settings.prefs.shortcuts.triggers(for: .dictation).first else {
            return tr("Add a shortcut for Voice Input first.")
        }
        return tr("Click in the box, press %@, and say something like “Let’s meet on Friday at 3.” Then press %@ again.",
                  trigger.label, trigger.label)
    }

    @ViewBuilder private var status: some View {
        let downloading = [root.settings.prefs.speech.localModel, root.settings.prefs.ai.localModel]
            .compactMap { $0 }.compactMap { model in root.library.progress[model].map { (model, $0) } }
        if let (model, progress) = downloading.first {
            HStack {
                ProgressView(value: progress).frame(width: 160)
                Text(tr("%@ is still downloading. Try it when it’s done.", model.name)).foregroundStyle(.secondary)
            }
        } else if case .recording = root.dictation.phase {
            Label(tr("Listening…"), systemImage: "waveform").foregroundStyle(.red)
        } else if case let .processing(stage) = root.dictation.phase {
            Label(stage.label, systemImage: "ellipsis")
        } else if !text.isEmpty {
            Label(tr("That’s it. It works the same in every app."), systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        }
    }
}
