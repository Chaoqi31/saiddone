import Foundation

/// A user term: ASR may mis-hear `wrong`, replace with `right`. Case-insensitive, whole-word.
public struct DictionaryEntry: Codable, Sendable, Equatable {
    public var wrong: String
    public var right: String
    public init(wrong: String, right: String) {
        self.wrong = wrong
        self.right = right
    }
}

/// Post-ASR term correction (GOALS A5: "术语正确，个人词典生效"). Pure, deterministic, runs before Polish.
public struct CustomDictionary: Codable, Sendable {
    public var entries: [DictionaryEntry]
    public init(entries: [DictionaryEntry] = []) { self.entries = entries }

    /// Apply all corrections. Whole-word, case-insensitive for ASCII terms; substring for CJK
    /// (CJK has no word boundaries). Longer `wrong` first so overlapping terms resolve greedily.
    public func apply(to text: String) -> String {
        var result = text
        for entry in entries.sorted(by: { $0.wrong.count > $1.wrong.count }) where !entry.wrong.isEmpty {
            result = Self.replace(entry.wrong, with: entry.right, in: result)
        }
        return result
    }

    static func replace(_ wrong: String, with right: String, in text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: wrong)
        // Constrain a side only when its edge char is a word char, so terms like "c++" still match
        // ("\b" would fail after '+'). CJK has no word boundaries -> no constraint.
        // ASCII-only: CJK has no word boundaries, so it must match as a substring.
        func isWordChar(_ c: Character?) -> Bool {
            guard let c, c.isASCII else { return false }
            return c.isLetter || c.isNumber || c == "_"
        }
        let lead = isWordChar(wrong.first) ? "(?<![A-Za-z0-9_])" : ""
        let trail = isWordChar(wrong.last) ? "(?![A-Za-z0-9_])" : ""
        let pattern = lead + escaped + trail
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        let template = NSRegularExpression.escapedTemplate(for: right)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
