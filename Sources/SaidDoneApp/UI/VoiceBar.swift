import SaidDoneCore
import SwiftUI

/// The floating bar at the bottom of the screen: the live recording, the job in progress, and what happened.
struct VoiceBar: View {
    let root: AppRoot

    private var dictation: Dictation { root.dictation }

    var body: some View {
        VStack(spacing: 6) {
            if let notice = dictation.notice {
                NoticeRow(notice: notice, root: root)
                    .modifier(Bar())
            }
            switch dictation.phase {
            case .idle:
                EmptyView()
            case let .recording(mode, style, since):
                RecordingRow(root: root, mode: mode, style: style, since: since)
                    .modifier(Bar())
            case let .processing(stage):
                ProcessingRow(stage: stage, waiting: dictation.waiting, cancel: dictation.cancel)
                    .modifier(Bar())
            }
        }
        .frame(width: 420)
        .padding(12)
        .animation(.snappy(duration: 0.2), value: dictation.phase)
        .animation(.snappy(duration: 0.2), value: dictation.notice)
    }
}

struct Bar: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

struct RecordingRow: View {
    let root: AppRoot
    let mode: Mode
    let style: RecordingStyle
    let since: Date

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: mode.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.red.gradient))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mode.title).font(.system(size: 12, weight: .semibold))
                    if mode == .translation { TargetMenu(settings: root.settings) }
                }
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 110, alignment: .leading)
            Waveform(levels: root.recorder.levels)
                .frame(height: 22)
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(Duration.seconds(max(0, context.date.timeIntervalSince(since))).formatted(.time(pattern: .minuteSecond)))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button(action: root.dictation.finish) { Image(systemName: "checkmark") }
                .help(tr("Finish"))
                .accessibilityLabel(tr("Finish"))
            Button(action: root.dictation.cancel) { Image(systemName: "xmark") }
                .help(tr("Cancel (Esc)"))
                .accessibilityLabel(tr("Cancel"))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var hint: String {
        guard style == .toggle else { return tr("Release to finish") }
        let trigger = root.settings.prefs.shortcuts.triggers(for: mode).first
        return trigger.map { tr("Press %@ to finish", $0.label) } ?? tr("Click ✓ to finish")
    }
}

/// Where a translation goes. Read when the recording ends, so it can change mid-sentence.
private struct TargetMenu: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Menu {
            Picker(tr("Translate into"), selection: $settings.prefs.translationTarget) {
                ForEach(Language.translationTargets) { Text($0.endonym).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(verbatim: "→ " + settings.prefs.translationTarget.endonym)
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.red.opacity(0.85))
                    .frame(width: 3, height: max(3, CGFloat(levels[index]) * 22))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }
}

struct ProcessingRow: View {
    let stage: Stage
    let waiting: Int
    let cancel: () -> Void
    @State private var started = Date.now

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            TimelineView(.periodic(from: started, by: 1)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stage.label).font(.system(size: 12, weight: .semibold))
                    if stage == .preparing, context.date.timeIntervalSince(started) > 3 {
                        Text(tr("The first time a model loads takes a few minutes."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if waiting > 0 {
                Text(tr("%lld more waiting", waiting))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button(action: cancel) { Image(systemName: "xmark") }
                .buttonStyle(.bordered).controlSize(.small)
                .help(tr("Cancel (Esc)"))
                .accessibilityLabel(tr("Cancel"))
        }
        .task(id: stage) { started = .now }
    }
}

struct NoticeRow: View {
    let notice: Notice
    let root: AppRoot

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            actions
            Button { root.dictation.dismissNotice() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(tr("Dismiss"))
        }
        .controlSize(.small)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var actions: some View {
        switch notice {
        case let .failed(reason, entry, transcript):
            if let transcript, !transcript.isEmpty {
                Button(tr("Copy text")) {
                    root.inserter.copy(transcript)
                    root.dictation.dismissNotice()
                }
            }
            if reason != .missingCredential, reason != .modelMissing {
                Button(tr("Retry")) {
                    root.dictation.dismissNotice()
                    root.dictation.retry(entry)
                }
            }
        case let .setupNeeded(issue):
            Button(tr("Fix")) {
                root.dictation.dismissNotice()
                root.fix(issue)
            }
        case .microphoneFailed, .microphoneMissing:
            Button(tr("Settings")) {
                root.dictation.dismissNotice()
                root.windows.showMain(.microphone)
            }
        case .copied, .nothingHeard, .retryUnavailable, .learned:
            EmptyView()
        }
    }

    private var message: String {
        switch notice {
        case .copied: tr("Copied. Paste it with ⌘V.")
        case .nothingHeard: tr("Didn’t catch that.")
        case let .failed(reason, _, _): reason.message
        case .retryUnavailable: tr("The recording is no longer available.")
        case let .setupNeeded(issue): issue.title
        case let .microphoneFailed(error): error.message
        case let .microphoneMissing(name): tr("%@ isn’t connected. Using the default microphone.", name)
        case let .learned(terms): tr("Added to your dictionary: %@", terms.joined(separator: ", "))
        }
    }

    private var symbol: String {
        switch notice {
        case .copied: "doc.on.clipboard"
        case .nothingHeard: "ear"
        case .failed, .setupNeeded, .microphoneFailed: "exclamationmark.triangle.fill"
        case .retryUnavailable, .microphoneMissing: "info.circle"
        case .learned: "character.book.closed.fill"
        }
    }

    private var tint: Color {
        switch notice {
        case .failed, .setupNeeded, .microphoneFailed: .orange
        case .learned: .green
        default: .secondary
        }
    }
}
