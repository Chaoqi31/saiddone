import Foundation

/// Learn dictionary terms from a user's correction: diff the original vs the edited text and
/// extract Latin-token substitutions (e.g. "Verso" → "Vercel"). Used when the user fixes a word
/// in History — the change is auto-captured as a Custom Dictionary entry.
public enum DictionaryLearning {
    public static func diffTerms(old: String, new: String) -> [DictionaryEntry] {
        let oldT = latinTokens(old), newT = latinTokens(new)
        let oldSet = Set(oldT.map { $0.lowercased() }), newSet = Set(newT.map { $0.lowercased() })
        let removed = oldT.filter { !newSet.contains($0.lowercased()) }
        let added = newT.filter { !oldSet.contains($0.lowercased()) }
        // Only confident when the same number of tokens were swapped (1:1, in order).
        guard !removed.isEmpty, removed.count == added.count, removed.count <= 5 else { return [] }
        return zip(removed, added)
            .filter { $0 != $1 && $0.count >= 2 }
            .map { DictionaryEntry(wrong: $0, right: $1) }
    }

    static func latinTokens(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9.+#-]*")
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}
