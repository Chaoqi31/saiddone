import AppKit
import Foundation
import Observation
import SaidDoneCore

/// History as the History pane and Home show it: one filtered, searchable page at a time, reloaded on every change.
@MainActor @Observable
final class HistoryModel {
    var mode: Mode? { didSet { if mode != oldValue { reload(reset: true) } } }
    var search = "" { didSet { if search != oldValue { reload(reset: true) } } }
    private(set) var entries: [HistoryEntry] = []
    private(set) var usage = UsageStats()
    private(set) var hasMore = false

    @ObservationIgnored let store: HistoryStore
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private let pageSize = 100

    init(store: HistoryStore) {
        self.store = store
        Task { [weak self] in
            for await _ in store.changes { self?.reload(reset: false) }
        }
        reload(reset: true)
    }

    func loadMore() {
        guard hasMore, let last = entries.last else { return }
        let query = HistoryQuery(mode: mode, search: search, before: last.created, limit: pageSize)
        loading?.cancel()
        loading = Task {
            let page = await store.page(query)
            guard !Task.isCancelled else { return }
            entries += page
            hasMore = page.count == pageSize
        }
    }

    func delete(_ entry: HistoryEntry) { Task { await store.delete([entry.id]) } }

    func deleteAll() { Task { await store.deleteAll() } }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func revealAudio(_ entry: HistoryEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([store.audioURL(entry.id)])
    }

    /// The latest query wins; a reload keeps as many rows as are already loaded, so paging survives new entries.
    private func reload(reset: Bool) {
        let limit = reset ? pageSize : max(pageSize, entries.count)
        let query = HistoryQuery(mode: mode, search: search, limit: limit)
        loading?.cancel()
        loading = Task {
            let page = await store.page(query)
            let usage = await store.usage()
            guard !Task.isCancelled else { return }
            entries = page
            hasMore = page.count == limit
            self.usage = usage
        }
    }
}
