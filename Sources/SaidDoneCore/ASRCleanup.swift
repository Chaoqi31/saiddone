import Foundation

/// Deterministic cleanup of common ASR hallucinations (Whisper/Qwen emit these on silence/noise),
/// applied to every transcript before polish so even the rule-based path stays clean.
public enum ASRCleanup {
    /// Phrases Whisper-family models hallucinate on silence — never real dictation. Simplified + Traditional.
    static let hallucinations: [String] = [
        "谢谢大家观看", "謝謝大家觀看", "谢谢大家", "謝謝大家",
        "谢谢观看", "謝謝觀看", "谢谢收看", "謝謝收看",
        "请不吝点赞订阅转发打赏支持明镜与点点栏目", "请不吝点赞订阅转发打赏",
        "請不吝點贊訂閱轉發打賞支持明鏡與點點欄目", "請不吝點贊訂閱轉發打賞",
        "请点赞订阅", "請點贊訂閱", "字幕志愿者", "字幕由", "本字幕",
        "明镜与点点栏目", "明鏡與點點欄目", "Thanks for watching", "thanks for watching",
    ]

    /// Standalone phrases Whisper appends on END-silence (a final "谢谢"/"thank you" after a pause).
    /// Stripped ONLY when they are the trailing fragment — bare "谢谢" can be real mid-sentence.
    static let trailingArtifacts: [String] = [
        "谢谢观看", "謝謝觀看", "谢谢大家", "謝謝大家", "谢谢你的观看",
        "谢谢你", "謝謝你", "谢谢", "謝謝",
        "thank you for watching", "thank you", "thanks",
    ]

    public static func strip(_ text: String) -> String {
        var t = text
        for phrase in hallucinations {
            t = t.replacingOccurrences(of: phrase, with: "")
        }
        // Collapse whitespace and trim stray separators left behind.
        t = t.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        t = stripTrailingArtifacts(t)
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t，,。.、"))
    }

    private static let edgePunct = CharacterSet(charactersIn: " \n\t，,。.、!！?？~～…")

    /// Repeatedly peel a trailing hallucination tail (and the punctuation around it) off the end.
    private static func stripTrailingArtifacts(_ text: String) -> String {
        var t = text
        var changed = true
        while changed {
            changed = false
            let trimmed = t.trimmingCharacters(in: edgePunct)
            for a in trailingArtifacts where trimmed.lowercased().hasSuffix(a.lowercased()) {
                t = String(trimmed.dropLast(a.count))
                changed = true
                break
            }
        }
        return t
    }
}
