import XCTest
@testable import SaidDoneCore

final class VoiceCommandsTests: XCTestCase {
    func testChineseNewline() {
        XCTAssertEqual(VoiceCommands.apply("第一点 换行 第二点"), "第一点\n第二点")
    }
    func testEnglishNewline() {
        XCTAssertEqual(VoiceCommands.apply("item one new line item two"), "item one\nitem two")
    }
    func testCollapsesBlankLines() {
        XCTAssertEqual(VoiceCommands.apply("a 新段落 新段落 b"), "a\nb")
    }
}
