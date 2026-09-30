import SaidDoneCore
import SwiftUI

/// Every job, newest first: what was said, what came out, and what went wrong. Failed jobs keep their recording,
/// so they can run again.
struct HistoryPane: View {
    let root: AppRoot
    @State private var confirmingDeleteAll = false
    @Environment(\.locale) private var locale

    private var model: HistoryModel { root.historyModel }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker(tr("Show"), selection: $model.mode) {
                    Text(tr("All")).tag(Mode?.none)
                    ForEach(Mode.allCases, id: \.self) { Text(verbatim: $0.title).tag(Mode?.some($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField(tr("Search"), text: $model.search)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive) { confirmingDeleteAll = true } label: {
                    Label(tr("Delete All…"), systemImage: "trash")
                }
                .disabled(model.entries.isEmpty && model.search.isEmpty && model.mode == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            if model.entries.isEmpty {
                ContentUnavailableView(model.search.isEmpty ? tr("No history yet") : tr("No matches"),
                                       systemImage: "clock",
                                       description: Text(model.search.isEmpty
                                           ? tr("Every dictation is kept here, with its recording.")
                                           : tr("Try other words.")))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(Self.days(model.entries), id: \.day) { group in
                        Section(title(group.day)) {
                            ForEach(group.entries) { HistoryRow(entry: $0, root: root) }
                        }
                    }
                    if model.hasMore {
                        Button(tr("Show older")) { model.loadMore() }
                            .buttonStyle(.link)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .confirmationDialog(tr("Delete all history?"), isPresented: $confirmingDeleteAll) {
            Button(tr("Delete All"), role: .destructive) { model.deleteAll() }
        } message: {
            Text(tr("Every entry and recording is deleted. Your stats stay."))
        }
    }

    private static func days(_ entries: [HistoryEntry]) -> [(day: Date, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var groups: [(day: Date, entries: [HistoryEntry])] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.created)
            if groups.last?.day == day { groups[groups.count - 1].entries.append(entry) } else { groups.append((day, [entry])) }
        }
        return groups
    }

    private func title(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return tr("Today") }
        if Calendar.current.isDateInYesterday(day) { return tr("Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year().locale(locale))
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let root: AppRoot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if case .ask = entry.request, let question = entry.transcript {
                Text(verbatim: question).font(.callout).foregroundStyle(.secondary)
            }
            if !entry.displayText.isEmpty {
                Text(verbatim: entry.displayText).textSelection(.enabled)
            }
            if case .translate = entry.request, let transcript = entry.transcript, entry.outcome.text != nil {
                Text(verbatim: transcript).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Text(verbatim: entry.mode.title)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Text(entry.created, format: .dateTime.hour().minute())
                if let app = entry.app { Text(verbatim: Apps.name(app)) }
                outcome
                Spacer()
                actions
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contextMenu { menu }
    }

    @ViewBuilder private var outcome: some View {
        switch entry.outcome {
        case .pending:
            Text(tr("Processing…"))
        case let .delivered(_, delivery):
            Text(verbatim: delivery.label)
        case .nothingSaid:
            Text(tr("Nothing said"))
        case let .failed(failure):
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var actions: some View {
        if entry.outcome.isUnfinished, entry.hasAudio, entry.outcome != .pending {
            Button(tr("Retry")) { root.dictation.retry(entry.id) }
                .controlSize(.small)
        }
        if !entry.displayText.isEmpty {
            Button { root.historyModel.copy(entry.displayText) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help(tr("Copy"))
                .accessibilityLabel(tr("Copy"))
        }
        Menu { menu } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(tr("More"))
    }

    @ViewBuilder private var menu: some View {
        if let text = entry.outcome.text {
            Button(tr("Copy")) { root.historyModel.copy(text) }
        }
        if let transcript = entry.transcript, transcript != entry.outcome.text {
            Button(tr("Copy What You Said")) { root.historyModel.copy(transcript) }
        }
        if entry.hasAudio {
            Button(tr("Run Again")) { root.dictation.retry(entry.id) }
            Button(tr("Show Recording in Finder")) { root.historyModel.revealAudio(entry) }
        }
        Divider()
        Button(tr("Delete"), role: .destructive) { root.historyModel.delete(entry) }
    }
}
