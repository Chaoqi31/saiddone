import Foundation

/// Zero-model, offline, instant local Polish (GOALS A5 baseline): drop filler words, collapse
/// immediate repeats, fix spacing, sentence-case + end punctuation. Deterministic and testable.
/// Cannot translate (no model) -> Translation Mode must use an MLX/Cloud LLM Provider.
public struct RuleBasedLLM: LLMProvider {
    public let id = "rule-based-llm"
    public let location: ProviderLocation = .local
    public init() {}

    static let fillers: Set<String> = [
        "um", "uh", "uhh", "umm", "er", "erm", "hmm", "like", "you know", "i mean", "sort of", "kind of",
        "嗯", "呃", "啊", "那个", "这个", "就是说", "然后呢",
    ]

    public func polish(_ text: String, context: PolishContext) async throws -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }
        t = Self.removeFillers(t)
        t = Self.collapseRepeats(t)
        t = Self.normalizeSpacing(t)
        t = Self.cleanupPunctuation(t)
        t = Self.sentenceCaseAndPunctuate(t)
        return t
    }

    public func translate(_ text: String, to targetLanguage: String, context: PolishContext) async throws -> String {
        throw ProviderError.notConfigured("RuleBasedLLM cannot translate; select an MLX or Cloud LLM Provider")
    }

    // MARK: rules

    static func removeFillers(_ text: String) -> String {
        // Multi-word fillers first, then single tokens. Word/loose-boundary, case-insensitive.
        var t = text
        for filler in fillers.sorted(by: { $0.count > $1.count }) {
            let asciiBoundary = filler.allSatisfy { $0.isASCII }
            let escaped = NSRegularExpression.escapedPattern(for: filler)
            let pattern = asciiBoundary ? "(?<![A-Za-z])" + escaped + "(?![A-Za-z])" : escaped
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " ")
            }
        }
        return t
    }

    static func collapseRepeats(_ text: String) -> String {
        // "the the cat" -> "the cat"; "好 好 的" -> "好 的". Adjacent identical tokens.
        let re = try! NSRegularExpression(pattern: "\\b(\\w+)(\\s+\\1\\b)+", options: [.caseInsensitive])
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    }

    static func normalizeSpacing(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        // No space before ASCII punctuation.
        t = t.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Repair punctuation orphaned by filler removal (e.g. "Um," → ", "; "you know." → " .").
    static func cleanupPunctuation(_ text: String) -> String {
        var t = text
        func sub(_ pat: String, _ rep: String) {
            t = t.replacingOccurrences(of: pat, with: rep, options: .regularExpression)
        }
        sub("\\s+([,.!?;:，。！？；：])", "$1")          // no space before punctuation
        sub("([,;:，；：])\\s*([.。!！?？])", "$2")        // comma-then-terminator -> terminator (", ." -> ".")
        sub("([,.!?;:，。！？])\\1+", "$1")              // collapse duplicate punctuation
        sub("^[\\s,;:，；：、]+", "")                     // drop leading orphan punctuation/space
        sub("\\s{2,}", " ")
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func sentenceCaseAndPunctuate(_ text: String) -> String {
        guard let first = text.first else { return text }
        var t = text
        if first.isASCII && first.isLetter {
            t = first.uppercased() + t.dropFirst()
        }
        // Append a period if it ends without terminal punctuation and looks like Latin text.
        if let last = t.last, !".!?。！？…".contains(last), t.contains(where: { $0.isASCII && $0.isLetter }) {
            t += "."
        }
        return t
    }
}
