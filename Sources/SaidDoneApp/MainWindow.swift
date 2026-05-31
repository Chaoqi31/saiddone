import SwiftUI
import AppKit
import AVFoundation
import SaidDoneCore

/// Recent history for the main window.
@MainActor
final class HistoryModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    @Published var search = ""
    let store: HistoryStore
    private var player: AVAudioPlayer?
    init(store: HistoryStore) { self.store = store; refresh() }
    func refresh() { entries = store.recent() }
    func clear() { store.clear(); refresh() }
    func delete(_ e: HistoryEntry) {
        if let u = audioURL(e) { try? FileManager.default.removeItem(at: u) }
        store.remove(id: e.id); refresh()
    }
    var filtered: [HistoryEntry] {
        search.isEmpty ? entries : entries.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    func audioURL(_ e: HistoryEntry) -> URL? {
        guard let f = e.audioFile else { return nil }
        let u = store.audioURL(f)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    func play(_ e: HistoryEntry) {
        guard let u = audioURL(e) else { return }
        player = try? AVAudioPlayer(contentsOf: u); player?.play()
    }
    /// Reveal the WAV in Finder (user can then copy/move it out).
    func exportAudio(_ e: HistoryEntry) {
        guard let u = audioURL(e) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case home, history, setup
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String { self == .home ? "house" : self == .history ? "clock" : "checklist" }
}

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct MainView: View {
    @ObservedObject var history: HistoryModel
    @ObservedObject var setup: SetupModel
    @State private var pane: Pane? = .home

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label(p.title, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 210)
        } detail: {
            switch pane ?? .home {
            case .home: HomePane(history: history, go: { pane = $0 })
            case .history: HistoryPane(model: history)
            case .setup: SetupView(model: setup)
            }
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 480, idealHeight: 520)
    }
}

// MARK: - Home

private struct HomePane: View {
    @ObservedObject var history: HistoryModel
    var go: (Pane) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(LinearGradient(colors: [.indigo, .purple], startPoint: .top, endPoint: .bottom))
                        .frame(width: 60, height: 60)
                        .overlay(Image(systemName: "waveform").font(.system(size: 28, weight: .semibold)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SaidDone").font(.largeTitle.bold())
                        Text("Local-first voice-to-text").foregroundStyle(.secondary)
                    }
                }

                card("Quick start", icon: "bolt.fill") {
                    shortcutRow("Dictation", "speak → press again to stop & insert", "⌃⌥D")
                    Divider()
                    shortcutRow("Translation", "speak one language, insert another", "⌃⌥T")
                    Divider()
                    Label("Text lands at your cursor — click into a field first.", systemImage: "cursorarrow.rays")
                        .font(.callout).foregroundStyle(.secondary)
                }

                card("Recent", icon: "clock") {
                    if history.entries.isEmpty {
                        Text("No dictations yet. Press ⌃⌥D to start.").foregroundStyle(.secondary).font(.callout)
                    } else {
                        ForEach(history.entries.prefix(3)) { e in
                            HStack {
                                Text(e.text).lineLimit(1).font(.callout)
                                Spacer()
                                Button { copyToClipboard(e.text) } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless)
                            }
                            if e.id != history.entries.prefix(3).last?.id { Divider() }
                        }
                        Button("See all \(history.entries.count) →") { go(.history) }
                            .buttonStyle(.borderless).font(.callout)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(24)
        }
    }

    private func card(_ title: String, icon: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func shortcutRow(_ title: String, _ subtitle: String, _ keys: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(keys).font(.system(.body, design: .rounded).weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

// MARK: - History

private struct HistoryPane: View {
    @ObservedObject var model: HistoryModel

    private var groups: [(String, [HistoryEntry])] {
        let cal = Calendar.current
        var keys: [String] = []
        var dict: [String: [HistoryEntry]] = [:]
        for e in model.filtered {
            let key = label(for: e.date, cal: cal)
            if dict[key] == nil { keys.append(key) }
            dict[key, default: []].append(e)
        }
        return keys.map { ($0, dict[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { e in row(e) }
                    }
                }
            }
            .overlay {
                if model.filtered.isEmpty {
                    ContentUnavailableView(model.search.isEmpty ? "No dictations yet" : "No matches",
                                           systemImage: "clock")
                }
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search history")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu { Button("Refresh") { model.refresh() }; Button("Clear all", role: .destructive) { model.clear() } }
                label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .navigationTitle("History")
    }

    private func row(_ e: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(e.text).textSelection(.enabled)
            HStack(spacing: 8) {
                Text(e.mode == "translation" ? "翻译" : "听写")
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Text(e.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if model.audioURL(e) != nil {
                    Button { model.play(e) } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.borderless).help("Play audio")
                    Button { model.exportAudio(e) } label: { Image(systemName: "square.and.arrow.down") }
                        .buttonStyle(.borderless).help("Reveal audio in Finder")
                }
                Button { copyToClipboard(e.text) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy")
            }
        }
        .padding(.vertical, 2)
        .swipeActions {
            Button(role: .destructive) { model.delete(e) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func label(for date: Date, cal: Calendar) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
