import Foundation

/// A word or name the user wants spelled their way: "Vercel", "SaidDone", "张三".
public struct Term: Codable, Identifiable, Hashable, Sendable {
    public enum Origin: String, Codable, Sendable {
        case manual
        /// Added automatically after the user corrected an insertion.
        case learned
    }

    public let id: UUID
    public var text: String
    /// Known mishearings. On manual terms they are replaced deterministically after transcription.
    public var misheard: [String]
    public var origin: Origin
    public var added: Date

    public init(id: UUID = UUID(), text: String, misheard: [String] = [], origin: Origin, added: Date) {
        self.id = id
        self.text = text
        self.misheard = misheard
        self.origin = origin
        self.added = added
    }

    /// The form every term and variant is stored in: one line, no CSV separators.
    public static func clean(_ text: String) -> String? {
        let cleaned = text.components(separatedBy: CharacterSet(charactersIn: ",|\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Case is part of the spelling only for mixed-case or long all-caps terms ("iPhone", "GitHub", "JSON").
    /// "Apple" or "US" would wrongly capitalize ordinary words, so those are left to the AI step.
    var fixesCasing: Bool {
        let letters = text.filter(\.isLetter)
        guard letters.contains(where: \.isUppercase), letters.dropFirst().contains(where: \.isUppercase) else {
            return false
        }
        return letters.contains(where: \.isLowercase) || letters.count >= 3
    }
}

/// A word the user changed after it was inserted.
public struct Correction: Hashable, Sendable {
    public var heard: String
    public var meant: String

    public init(heard: String, meant: String) {
        self.heard = heard
        self.meant = meant
    }
}

/// The personal dictionary. One term list, three uses: recognition hints for the speech engine, the term list in the
/// AI prompt, and a deterministic correction pass before the AI step.
public struct Lexicon: Codable, Equatable, Sendable {
    public var terms: [Term]

    public init(terms: [Term] = []) { self.terms = terms }

    /// Replaces known mishearings of manual terms and fixes the casing of case-sensitive terms, in one pass so a
    /// replacement is never itself replaced. ASCII matches whole words only; CJK has no word boundaries and matches
    /// anywhere. The longest variant wins where two overlap.
    public func correct(_ text: String) -> String {
        var seen: Set<String> = []
        var rules: [(from: String, to: String)] = []
        for term in terms {
            var sources = term.origin == .manual ? term.misheard : []
            if term.fixesCasing { sources.append(term.text) }
            for source in sources where seen.insert(source.lowercased()).inserted {
                rules.append((source, term.text))
            }
        }
        guard !rules.isEmpty else { return text }
        rules.sort { $0.from.count > $1.from.count }
        let pattern = rules.map { "(" + Self.bounded($0.from) + ")" }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }

        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let group = (1...rules.count).first(where: { match.range(at: $0).location != NSNotFound }) else {
                continue
            }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += rules[group - 1].to
            cursor = NSMaxRange(match.range)
        }
        return result + source.substring(from: cursor)
    }

    /// Words the speech engine should expect. Bounded: a long Whisper prompt makes it invent vocabulary on
    /// near-silence.
    public func recognitionHints(limit: Int = 40) -> [String] { Array(ranked.prefix(limit).map(\.text)) }

    /// Canonical spellings for the AI prompt.
    public func promptTerms(limit: Int = 150) -> [String] { Array(ranked.prefix(limit).map(\.text)) }

    /// Adds a manual term, or merges into the term with the same spelling (which then becomes manual).
    @discardableResult
    public mutating func add(_ text: String, misheard: [String] = [], at date: Date) -> Term? {
        guard let text = Term.clean(text) else { return nil }
        let variants = misheard.compactMap(Term.clean)
        if let index = index(of: text) {
            terms[index].text = text
            terms[index].origin = .manual
            merge(variants, into: index)
            return terms[index]
        }
        let term = Term(text: text, misheard: dedupe(variants, excluding: text), origin: .manual, added: date)
        terms.append(term)
        return term
    }

    /// Records corrections as learned terms. Never overrides a manual term's spelling and never turns another
    /// term's spelling into a mishearing. Returns the terms that changed.
    @discardableResult
    public mutating func learn(_ corrections: [Correction], at date: Date) -> [Term] {
        var touched: [UUID] = []
        for correction in corrections {
            guard let heard = Term.clean(correction.heard), let meant = Term.clean(correction.meant),
                  heard != meant, index(of: heard) == nil || heard.lowercased() == meant.lowercased() else { continue }
            if let index = index(of: meant) {
                let before = terms[index]
                merge([heard], into: index)
                if terms[index] != before { touched.append(terms[index].id) }
            } else {
                let term = Term(text: meant, misheard: [heard], origin: .learned, added: date)
                terms.append(term)
                touched.append(term.id)
            }
        }
        return terms.filter { touched.contains($0.id) }
    }

    public mutating func remove(_ id: Term.ID) { terms.removeAll { $0.id == id } }

    /// One term per line: `term` or `term,misheard|misheard`. Merges into existing terms. Returns the number of
    /// lines imported.
    @discardableResult
    public mutating func importCSV(_ text: String, at date: Date) -> Int {
        var count = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            let misheard = fields.count > 1 ? fields[1].split(separator: "|").map(String.init) : []
            if add(String(fields[0]), misheard: misheard, at: date) != nil { count += 1 }
        }
        return count
    }

    public func exportCSV() -> String {
        terms.map { term in
            term.misheard.isEmpty ? term.text : term.text + "," + term.misheard.joined(separator: "|")
        }.joined(separator: "\n") + (terms.isEmpty ? "" : "\n")
    }

    /// Word swaps between what was inserted and what the user left after editing it. Only confident, term-like
    /// changes count: the same number of Latin words swapped one for one (at most 5), where the new spelling has a
    /// capital or a digit ("Verso" → "Vercel"). "their" → "there" is an edit, not a term.
    public static func corrections(inserted: String, edited: String) -> [Correction] {
        let before = latinWords(inserted), after = latinWords(edited)
        let beforeSet = Set(before.map { $0.lowercased() }), afterSet = Set(after.map { $0.lowercased() })
        let removed = before.filter { !afterSet.contains($0.lowercased()) }
        let added = after.filter { !beforeSet.contains($0.lowercased()) }
        guard !removed.isEmpty, removed.count == added.count, removed.count <= 5 else {
            return casingFixes(before, after)
        }
        return zip(removed, added)
            .filter { heard, meant in heard.count >= 2 && meant.contains { $0.isUppercase || $0.isNumber } }
            .map { Correction(heard: $0, meant: $1) } + casingFixes(before, after)
    }

    // MARK: - Private

    /// Manual terms first, newest first.
    private var ranked: [Term] {
        terms.sorted { a, b in
            a.origin != b.origin ? a.origin == .manual : a.added > b.added
        }
    }

    private func index(of text: String) -> Int? {
        let key = text.lowercased()
        return terms.firstIndex { $0.text.lowercased() == key }
    }

    private mutating func merge(_ variants: [String], into index: Int) {
        terms[index].misheard = dedupe(terms[index].misheard + variants, excluding: terms[index].text)
    }

    private func dedupe(_ variants: [String], excluding text: String) -> [String] {
        var seen: Set<String> = [text]
        return variants.filter { seen.insert($0).inserted }
    }

    /// Same word, new casing ("github" → "GitHub").
    private static func casingFixes(_ before: [String], _ after: [String]) -> [Correction] {
        guard before.count == after.count else { return [] }
        return zip(before, after)
            .filter { $0 != $1 && $0.lowercased() == $1.lowercased() }
            .map { Correction(heard: $0, meant: $1) }
    }

    private static let latinWord = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9.+#-]*")

    private static func latinWords(_ text: String) -> [String] {
        let source = text as NSString
        return latinWord.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range).trimmingCharacters(in: CharacterSet(charactersIn: ".-")) }
            .filter { !$0.isEmpty }
    }

    /// Constrains a side to a word boundary only when that edge is an ASCII word character, so "c++" still
    /// matches and CJK matches as a substring.
    private static func bounded(_ literal: String) -> String {
        func isWordCharacter(_ c: Character?) -> Bool {
            guard let c, c.isASCII else { return false }
            return c.isLetter || c.isNumber || c == "_"
        }
        let lead = isWordCharacter(literal.first) ? "(?<![A-Za-z0-9_])" : ""
        let trail = isWordCharacter(literal.last) ? "(?![A-Za-z0-9_])" : ""
        return lead + NSRegularExpression.escapedPattern(for: literal) + trail
    }
}
