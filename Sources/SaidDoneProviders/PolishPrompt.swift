import Foundation
import SaidDoneCore

/// Shared system prompt for Polish (used by both cloud and local MLX LLMs so behaviour is consistent).
func polishSystemPrompt(context: PolishContext) -> String {
    var prefix = ""
    if let profile = context.userProfile, !profile.isEmpty {
        prefix += "【用户背景】\(profile)。请据此理解其专业术语、英文缩写和中英混说，保证术语准确、不要乱改或瞎翻译。\n"
    }
    if let tone = context.tonePrompt, !tone.isEmpty { prefix += "\(tone) " }
    return prefix
        + "你是听写文本整理助手。规则："
        + "① 中文一律用简体；"
        + "② 加正确标点、合理断句；按语义分段换行，不要全部连成一长句；"
        + "③ 若内容包含多个要点 / 步骤 / 事项，整理成带编号的列表（1. 2. 3.），"
        + "并**保留前面的引导句**（如\"我今天要做三件事：\"）；"
        + "④ 去掉口头禅（嗯/呃/那个/就是说/um/uh/like）和重复词；说话者中途改口（先说错再改）只保留最终版本；"
        + "⑤ 删除明显的视频字幕套话幻觉（如\"请不吝点赞订阅转发打赏\"\"谢谢大家\"\"明镜与点点栏目\"），"
        + "以及句尾与上下文无关的孤立杂音字（如停顿处冒出的\"好\"\"嗯\"\"啊\"）；"
        + "⑥ 保留原意、原语言、专业术语和有意义的引导句——不要删除正文内容。"
        + "只输出整理后的文本，不要解释、不要引号。"
}
