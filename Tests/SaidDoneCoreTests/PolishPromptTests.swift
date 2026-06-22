import XCTest
@testable import SaidDoneCore

final class PolishPromptTests: XCTestCase {
    func testIncludesCodeSwitchCorrectionRule() {
        let prompt = PolishPrompt.system(context: .none)
        XCTAssertTrue(prompt.contains("中英混说 ASR 纠错"))
        XCTAssertTrue(prompt.contains("语义明显不符"))
    }

    func testSpokenLanguageZhHint() {
        var ctx = PolishContext()
        ctx.spokenLanguage = "zh"
        let prompt = PolishPrompt.system(context: ctx)
        XCTAssertTrue(prompt.contains("主要语言"))
        XCTAssertTrue(prompt.contains("英文术语"))
    }

    func testIncludesAntiEmptyRule() {
        let prompt = PolishPrompt.system(context: .none)
        XCTAssertTrue(prompt.contains("禁止输出空文本"))
    }
}
