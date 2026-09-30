import AppKit
import SaidDoneCore
import SwiftUI
import UniformTypeIdentifiers

/// Words and names SaidDone should spell your way. Terms you add also replace their known mishearings; terms
/// learned from your corrections steer recognition and the AI.
struct DictionaryPane: View {
    @Bindable var store: DictionaryStore
    @State private var newTerm = ""
    @State private var newMisheard = ""
    @State private var search = ""
    @State private var origin: Term.Origin?
    @State private var editing: Term?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(tr("SaidDone spells these your way. Add names, products and jargon it gets wrong."))
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField(tr("Word or name"), text: $newTerm)
                        .frame(maxWidth: 220)
                    TextField(tr("Often heard as (optional, comma-separated)"), text: $newMisheard)
                    Button(tr("Add"), action: add)
                        .keyboardShortcut(.defaultAction)
                        .disabled(Term.clean(newTerm) == nil)
                }
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
                HStack(spacing: 10) {
                    Picker(tr("Show"), selection: $origin) {
                        Text(tr("All")).tag(Term.Origin?.none)
                        Text(tr("Added by you")).tag(Term.Origin?.some(.manual))
                        Text(tr("Learned")).tag(Term.Origin?.some(.learned))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    TextField(tr("Search"), text: $search).textFieldStyle(.roundedBorder)
                    Button(tr("Import…"), action: importCSV)
                    Button(tr("Export…"), action: exportCSV).disabled(store.lexicon.terms.isEmpty)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            if shown.isEmpty {
                ContentUnavailableView(store.lexicon.terms.isEmpty ? tr("No words yet") : tr("No matches"),
                                       systemImage: "character.book.closed",
                                       description: Text(store.lexicon.terms.isEmpty
                                           ? tr("Add one above. When you fix a word right after dictating, SaidDone learns it too.")
                                           : tr("Try other words.")))
                    .frame(maxHeight: .infinity)
            } else {
                List(shown) { term in
                    TermRow(term: term, edit: { editing = term }, delete: { store.lexicon.remove(term.id) })
                }
            }
        }
        .sheet(item: $editing) { term in
            TermEditor(term: term) { text, misheard in
                store.lexicon.edit(term.id, text: text, misheard: misheard)
            }
        }
    }

    private var shown: [Term] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return store.lexicon.terms.reversed().filter { term in
            (origin == nil || term.origin == origin)
                && (query.isEmpty || ([term.text] + term.misheard).contains { $0.lowercased().contains(query) })
        }
    }

    private func add() {
        guard Term.clean(newTerm) != nil else { return }
        store.lexicon.add(newTerm, misheard: variants(newMisheard), at: .now)
        newTerm = ""
        newMisheard = ""
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        store.lexicon.importCSV(text, at: .now)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SaidDone Dictionary.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Data(store.lexicon.exportCSV().utf8).writeAtomically(to: url)
    }
}

/// Mishearings typed into one field, separated by Latin or Chinese commas.
private func variants(_ text: String) -> [String] {
    text.split(whereSeparator: { ",，、".contains($0) }).map(String.init)
}

private struct TermRow: View {
    let term: Term
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: term.text).font(.body.weight(.medium))
                if !term.misheard.isEmpty {
                    Text(tr("Heard as: %@", term.misheard.joined(separator: ", ")))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if term.origin == .learned {
                Text(tr("Learned"))
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.green.opacity(0.15), in: Capsule())
            }
            Button(action: edit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help(tr("Edit")).accessibilityLabel(tr("Edit"))
            Button(action: delete) { Image(systemName: "trash") }
                .buttonStyle(.borderless).help(tr("Delete")).accessibilityLabel(tr("Delete"))
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(tr("Edit…"), action: edit)
            Button(tr("Delete"), role: .destructive, action: delete)
        }
    }
}

private struct TermEditor: View {
    let term: Term
    let save: (String, [String]) -> Void
    @State private var text: String
    @State private var misheard: String
    @Environment(\.dismiss) private var dismiss

    init(term: Term, save: @escaping (String, [String]) -> Void) {
        self.term = term
        self.save = save
        _text = State(initialValue: term.text)
        _misheard = State(initialValue: term.misheard.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Edit Word")).font(.headline)
            Form {
                TextField(tr("Spelling"), text: $text)
                TextField(tr("Often heard as"), text: $misheard)
            }
            Text(tr("Mishearings of words you add are replaced with your spelling. Separate them with commas."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(tr("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Save")) {
                    save(text, variants(misheard))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(Term.clean(text) == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
