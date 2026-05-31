import XCTest
@testable import SaidDoneCore

final class ASRCleanupTests: XCTestCase {
    func testStripsTrailingHallucination() {
        XCTAssertEqual(ASRCleanup.strip("帮我修个bug 谢谢大家"), "帮我修个bug")
    }
    func testStripsTraditionalHallucination() {
        XCTAssertEqual(ASRCleanup.strip("跑通这个测试 謝謝大家觀看"), "跑通这个测试")
    }
    func testStripsSubscribeSpam() {
        XCTAssertEqual(ASRCleanup.strip("内容 请不吝点赞订阅转发打赏"), "内容")
    }
    func testKeepsNormalText() {
        XCTAssertEqual(ASRCleanup.strip("正常的一句话"), "正常的一句话")
    }
}
