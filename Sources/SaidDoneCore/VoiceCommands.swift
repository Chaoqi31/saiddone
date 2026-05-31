import Foundation

/// Spoken editing commands → text actions. Off by default (a setting), because words like "换行"
/// also occur in normal speech; power users opt in. Applied after polish.
public enum VoiceCommands {
    static let newlineWords = ["新起一段", "另起一段", "新段落", "换行", "新行", "new paragraph", "new line", "newline"]

    public static func apply(_ text: String) -> String {
        var t = text
        for w in newlineWords.sorted(by: { $0.count > $1.count }) {
            let ascii = w.allSatisfy { $0.isASCII }
            let pat = ascii ? "(?i)\\b" + NSRegularExpression.escapedPattern(for: w) + "\\b"
                            : NSRegularExpression.escapedPattern(for: w)
            if let re = try? NSRegularExpression(pattern: pat) {
                t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "\n")
            }
        }
        t = t.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
