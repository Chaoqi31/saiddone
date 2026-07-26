import XCTest
@testable import SaidDoneCore

final class PolishOutputTests: XCTestCase {
    func testNormalizesEmptyPlaceholders() {
        XCTAssertEqual(PolishOutput.normalize("（空文本）"), "")
        XCTAssertEqual(PolishOutput.normalize("empty"), "")
    }

    func testNormalizesAnyOutputToEmptyWhenSourceIsOnlyFillerOrCancel() {
        XCTAssertEqual(PolishOutput.normalize("I mean", source: "um uh like you know I mean"), "")
        XCTAssertEqual(PolishOutput.normalize("发消息说明天开会。", source: "给小王发消息说明天开会 算了"), "")
    }

    func testAllowsEmptyForPureFillersAndCancels() {
        XCTAssertTrue(PolishOutput.acceptsEmpty(for: "嗯 那个 就是 呃"))
        XCTAssertTrue(PolishOutput.acceptsEmpty(for: "send email no wait cancel that"))
        XCTAssertTrue(PolishOutput.acceptsEmpty(for: "给小王发消息说明天开会 算了"))
    }

    func testDoesNotAllowEmptyForNormalTextOrCorrections() {
        XCTAssertFalse(PolishOutput.acceptsEmpty(for: "send the report tomorrow"))
        XCTAssertFalse(PolishOutput.acceptsEmpty(for: "明天见 不对 后天见"))
        XCTAssertFalse(PolishOutput.acceptsEmpty(for: "cancel that meeting tomorrow"))
    }
}
