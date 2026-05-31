import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import SaidDoneCore

/// Recent history for the main window.
@MainActor
final class HistoryModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    @Published var search = ""
    let store: HistoryStore
    private var player: AVAudioPlayer?
    /// Called with terms learned when the user edits an entry (wired to add them to the dictionary).
    var onLearnTerms: (([DictionaryEntry]) -> Void)?
    /// Re-insert a past entry at the cursor (wired to the insertion service).
    var onReinsert: ((String) -> Void)?
    init(store: HistoryStore) { self.store = store; refresh() }

    func exportAll() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "saiddone-history.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = entries.map { "[\($0.date.formatted())] \($0.text)" }.joined(separator: "\n\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Save an edited entry; auto-learns Latin-term corrections into the dictionary. Returns them.
    @discardableResult
    func saveEdit(_ e: HistoryEntry, newText: String) -> [DictionaryEntry] {
        let terms = DictionaryLearning.diffTerms(old: e.text, new: newText)
        var updated = e; updated.text = newText
        store.update(updated); refresh()
        if !terms.isEmpty { onLearnTerms?(terms) }
        return terms
    }
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

/// Editable dictionary backed by the app config (changes persisted via `onChange`).
@MainActor
final class DictionaryModel: ObservableObject {
    @Published var entries: [DictionaryEntry]
    let onChange: ([DictionaryEntry]) -> Void
    init(entries: [DictionaryEntry], onChange: @escaping ([DictionaryEntry]) -> Void) {
        self.entries = entries; self.onChange = onChange
    }
    func commit() { onChange(entries) }
    func add() { entries.insert(.init(wrong: "", right: ""), at: 0); commit() }
    func removeAt(_ i: Int) { guard entries.indices.contains(i) else { return }; entries.remove(at: i); commit() }

    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "saiddone-dictionary.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(entries).write(to: url)
    }
    func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let imported = try? JSONDecoder().decode([DictionaryEntry].self, from: data) else { return }
        var byKey = Dictionary(entries.map { ($0.wrong, $0) }) { a, _ in a }
        for e in imported { byKey[e.wrong] = e }
        entries = byKey.values.sorted { $0.wrong < $1.wrong }
        commit()
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case home, history, dictionary, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .home: return "house"; case .history: return "clock"
        case .dictionary: return "character.book.closed"; case .settings: return "gearshape"
        }
    }
}

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct MainView: View {
    @ObservedObject var history: HistoryModel
    @ObservedObject var dictionary: DictionaryModel
    @ObservedObject var config: ConfigModel
    @ObservedObject var setup: SetupModel
    @State private var pane: Pane? = .home

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label(p.title, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            switch pane ?? .home {
            case .home: HomePane(history: history, go: { pane = $0 })
            case .history: HistoryPane(model: history)
            case .dictionary: DictionaryPane(model: dictionary)
            case .settings: SettingsView(model: config, setup: setup)
            }
        }
        .frame(minWidth: 820, minHeight: 560)   // no ideal -> panes don't drive window resizing
    }
}

private struct DictionaryPane: View {
    @ObservedObject var model: DictionaryModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Dictionary").font(.title2.bold())
                Spacer()
                Button { model.importFile() } label: { Image(systemName: "square.and.arrow.down") }.help("Import")
                Button { model.export() } label: { Image(systemName: "square.and.arrow.up") }.help("Export")
                Button { model.add() } label: { Label("Add term", systemImage: "plus") }
            }
            Text("Heard → Correct. Applied to every transcript. Auto-filled when you fix a word in History.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(model.entries.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        TextField("heard", text: Binding(get: { model.entries[i].wrong },
                                                         set: { model.entries[i].wrong = $0 }))
                            .onSubmit { model.commit() }
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("correct", text: Binding(get: { model.entries[i].right },
                                                           set: { model.entries[i].right = $0 }))
                            .onSubmit { model.commit() }
                        Button { model.removeAt(i) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .overlay { if model.entries.isEmpty {
                ContentUnavailableView("No terms yet", systemImage: "character.book.closed",
                                       description: Text("Add a term, or fix a word in History to learn one."))
            } }
            Text("Tip: press Return after editing a cell to save.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20)
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

                card("Stats", icon: "chart.bar.fill") {
                    HStack(spacing: 0) {
                        stat("\(history.entries.count)", "dictations")
                        Divider().frame(height: 34)
                        stat("\(totalChars)", "characters")
                        Divider().frame(height: 34)
                        stat("≈\(minutesSaved) min", "typing saved")
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

    private var totalChars: Int { history.entries.reduce(0) { $0 + $1.text.count } }
    private var minutesSaved: Int { max(0, totalChars / 200) }   // ~200 chars/min typing

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
    @State private var editing: HistoryEntry?
    @State private var draft = ""

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
                Menu {
                    Button("Refresh") { model.refresh() }
                    Button("Export…") { model.exportAll() }
                    Divider()
                    Button("Clear all", role: .destructive) { model.clear() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .navigationTitle("History")
        .sheet(item: $editing) { e in editSheet(e) }
    }

    private func editSheet(_ e: HistoryEntry) -> some View {
        let detected = DictionaryLearning.diffTerms(old: e.text, new: draft)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Edit & learn").font(.headline)
            Text("Fix any wrong words. English-term fixes get added to your dictionary so future dictations auto-correct.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft).font(.body).frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            if detected.isEmpty {
                Label("No new dictionary terms detected.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Will add to dictionary: " + detected.map { "\($0.wrong) → \($0.right)" }.joined(separator: ",  "),
                      systemImage: "character.book.closed.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            HStack {
                Spacer()
                Button("Cancel") { editing = nil }
                Button("Save") { model.saveEdit(e, newText: draft); editing = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 480)
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
                Button { model.onReinsert?(e.text) } label: { Image(systemName: "arrow.up.left.square") }
                    .buttonStyle(.borderless).help("Insert at cursor")
                Button { draft = e.text; editing = e } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Edit & learn term")
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
