import Foundation
import Testing
@testable import SaidDoneCore

struct VoiceCommandsTests {
    @Test func chineseNewline() {
        #expect((VoiceCommands.apply("第一点 换行 第二点")) == "第一点\n第二点")
    }
    @Test func englishNewline() {
        #expect((VoiceCommands.apply("item one new line item two")) == "item one\nitem two")
    }
    @Test func collapsesBlankLines() {
        #expect((VoiceCommands.apply("a 新段落 新段落 b")) == "a\nb")
    }
}
