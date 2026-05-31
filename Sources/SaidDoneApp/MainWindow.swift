import SwiftUI
import AppKit
import SaidDoneCore

/// Loads recent history for the main window.
@MainActor
final class HistoryModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    let store: HistoryStore
    init(store: HistoryStore) { self.store = store; refresh() }
    func refresh() { entries = store.recent() }
    func clear() { store.clear(); refresh() }
}

/// The real app window: Home (status + how-to) and History (recover text that didn't land).
struct MainView: View {
    @ObservedObject var history: HistoryModel

    var body: some View {
        TabView {
            home.tabItem { Label("Home", systemImage: "house") }
            historyTab.tabItem { Label("History", systemImage: "clock") }
        }
        .frame(width: 560, height: 460)
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("SaidDone").font(.title.bold())
                    Text("Local-first voice-to-text").foregroundStyle(.secondary)
                }
            }
            Divider()
            Label("Dictation:  ⌃⌥D — speak, press again to stop & insert", systemImage: "keyboard")
            Label("Translation:  ⌃⌥T — speak one language, insert another", systemImage: "globe")
            Label("Text lands where your cursor is — click into a field first", systemImage: "cursorarrow")
            Label("Every dictation is saved in History (recover it if it didn't land)", systemImage: "clock.arrow.circlepath")
            Spacer()
            Text("Tip: change language/models/hotkeys in Settings (⌘,)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var historyTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(history.entries.count) entries").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { history.refresh() }
                Button("Clear") { history.clear() }
            }
            .padding(8)
            Divider()
            if history.entries.isEmpty {
                Spacer(); Text("No dictations yet.").foregroundStyle(.secondary); Spacer()
            } else {
                List(history.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text).textSelection(.enabled)
                        HStack(spacing: 8) {
                            Text(entry.mode == "translation" ? "翻译" : "听写")
                                .font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.text, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
