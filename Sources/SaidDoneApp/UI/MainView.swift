import SaidDoneCore
import SwiftUI

/// The main window: Home, History and Dictionary, then the settings panes, in one sidebar.
struct MainView: View {
    let root: AppRoot
    @Bindable private var navigation: Navigation

    init(root: AppRoot) {
        self.root = root
        navigation = root.navigation
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding($navigation.pane)) {
                ForEach(Pane.top) { row($0) }
                Section(tr("Settings")) {
                    ForEach(Pane.settings) { row($0) }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(navigation.pane.title)
        }
        .frame(minWidth: 780, minHeight: 540)
    }

    private func row(_ pane: Pane) -> some View {
        Label(pane.title, systemImage: pane.symbol).tag(pane)
    }

    @ViewBuilder private var detail: some View {
        switch navigation.pane {
        case .home: HomePane(root: root)
        case .history: HistoryPane(root: root)
        case .dictionary: DictionaryPane(store: root.dictionary)
        case .general: GeneralPane(root: root)
        case .shortcuts: ShortcutsPane(root: root)
        case .microphone: MicrophonePane(root: root)
        case .engines: EnginesPane(root: root)
        case .personalization: PersonalizationPane(settings: root.settings)
        }
    }
}

// MARK: - Home

struct HomePane: View {
    let root: AppRoot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                let issues = root.setup.issues
                if !issues.isEmpty {
                    Card(title: tr("Finish setting up"), symbol: "exclamationmark.triangle.fill",
                         attention: issues.contains(where: \.blocksRecording)) {
                        ForEach(issues, id: \.self) { issue in
                            IssueRow(issue: issue, library: root.library, fix: root.fix)
                        }
                    }
                }
                StatsCard(usage: root.historyModel.usage)
                QuickStartCard(shortcuts: root.settings.prefs.shortcuts)
                RecentCard(root: root)
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            BrandMark(size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "SaidDone").font(.largeTitle.bold())
                Text(status).foregroundStyle(.secondary)
            }
        }
    }

    private var status: String {
        if root.setup.recordingBlocker != nil { return tr("Finish setting up to start dictating.") }
        guard let trigger = root.settings.prefs.shortcuts.triggers(for: .dictation).first else {
            return tr("Ready. Add a shortcut to start dictating.")
        }
        return tr("Ready. Press %@ anywhere to start dictating.", trigger.label)
    }
}

private struct StatsCard: View {
    let usage: UsageStats
    @Environment(\.locale) private var locale

    var body: some View {
        Card(title: tr("Your dictation"), symbol: "chart.bar.fill") {
            HStack(spacing: 0) {
                stat(usage.words.formatted(), tr("words dictated"))
                Divider().frame(height: 36)
                stat(duration(usage.timeSaved), tr("typing time saved"))
                Divider().frame(height: 36)
                stat(usage.wordsPerMinute.formatted(), tr("words per minute"))
                Divider().frame(height: 36)
                stat(usage.dictations.formatted(), tr("dictations"))
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(verbatim: value).font(.title2.weight(.semibold)).foregroundStyle(.tint)
            Text(verbatim: label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// In the interface language, which can differ from the system's.
    private func duration(_ duration: Duration) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration < .seconds(3600) ? [.minute] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: TimeInterval(duration.components.seconds)) ?? "0"
    }
}

private struct QuickStartCard: View {
    let shortcuts: Shortcuts

    var body: some View {
        Card(title: tr("How to use it"), symbol: "bolt.fill") {
            ForEach(Mode.allCases, id: \.self) { mode in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: mode.title).font(.body.weight(.medium))
                        Text(verbatim: mode.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(Array(shortcuts.triggers(for: mode).prefix(2).enumerated()), id: \.element) { index, trigger in
                            if index > 0 { Text(tr("or")).font(.caption).foregroundStyle(.secondary) }
                            Keycaps(trigger: trigger)
                        }
                    }
                }
                Divider()
            }
            Label(tr("Tap the shortcut to talk hands-free, then tap it again to finish. Or hold it while you talk."),
                  systemImage: "hand.tap")
                .font(.callout).foregroundStyle(.secondary)
            Label(tr("Press Esc to cancel. Text goes where your cursor is."), systemImage: "escape")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct RecentCard: View {
    let root: AppRoot

    var body: some View {
        Card(title: tr("Recent"), symbol: "clock") {
            let recent = Array(root.historyModel.entries.prefix(3))
            if recent.isEmpty {
                Text(tr("Nothing yet. Your dictations will show up here."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(recent) { entry in
                    HStack {
                        Text(verbatim: entry.displayText).lineLimit(1).font(.callout)
                        Spacer()
                        Text(entry.created, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                }
                Button(tr("Show all history")) { root.navigation.pane = .history }
                    .buttonStyle(.link)
            }
        }
    }
}

extension HistoryEntry {
    /// The text a person would call "what it produced": the result, else what was heard.
    var displayText: String {
        outcome.text ?? transcript ?? ""
    }
}
