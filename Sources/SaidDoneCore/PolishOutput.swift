import Foundation

public enum PolishOutput {
    public static func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = compactForPolishHeuristic(trimmed)
        let emptyPlaceholders = [
            "空文本", "空", "无内容", "无文本", "empty", "null", "none",
        ]
        return emptyPlaceholders.contains(placeholder) ? "" : text
    }

    public static func normalize(_ text: String, source: String) -> String {
        acceptsEmpty(for: source) ? "" : normalize(text)
    }

    public static func acceptsEmpty(for source: String) -> Bool {
        let compact = compactForPolishHeuristic(source)
        guard !compact.isEmpty else { return true }
        if isPureFillerCompact(compact) { return true }

        let cancellationEndings = [
            "cancelthat", "nevermind", "nevermined", "scratchthat", "forgetthat",
            "算了", "算啦", "不用了", "不要了", "取消这句", "取消刚才", "全部取消",
            "删掉这句", "删掉刚才", "当我没说", "重来", "重新来",
        ]
        return cancellationEndings.contains { compact.hasSuffix($0) }
    }

    private static func isPureFillerCompact(_ compactText: String) -> Bool {
        var residue = compactText
        let fillers = [
            "那个什么", "那个啥", "就是说", "还有就是", "youknow", "imean",
            "那个", "然后", "的话", "一下", "就是",
            "嗯", "呃", "额", "喔", "唉", "诶", "哎", "哈", "嘛", "呐",
            "啊", "哦", "好", "就", "那", "um", "uh", "like",
        ].sorted { $0.count > $1.count }

        var changed = true
        while changed {
            changed = false
            for filler in fillers where residue.contains(filler) {
                residue = residue.replacingOccurrences(of: filler, with: "")
                changed = true
            }
        }
        return residue.isEmpty
    }

    private static func compactForPolishHeuristic(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        let drop = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        for scalar in text.lowercased().unicodeScalars where !drop.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }
}
