import Foundation
import Testing
@testable import SaidDoneCore

struct PolishOutputTests {
    @Test func normalizesEmptyPlaceholders() {
        #expect((PolishOutput.normalize("（空文本）")) == "")
        #expect((PolishOutput.normalize("empty")) == "")
    }

    @Test func normalizesAnyOutputToEmptyWhenSourceIsOnlyFillerOrCancel() {
        #expect((PolishOutput.normalize("I mean", source: "um uh like you know I mean")) == "")
        #expect((PolishOutput.normalize("发消息说明天开会。", source: "给小王发消息说明天开会 算了")) == "")
    }

    @Test func allowsEmptyForPureFillersAndCancels() {
        #expect(PolishOutput.acceptsEmpty(for: "嗯 那个 就是 呃"))
        #expect(PolishOutput.acceptsEmpty(for: "send email no wait cancel that"))
        #expect(PolishOutput.acceptsEmpty(for: "给小王发消息说明天开会 算了"))
    }

    @Test func doesNotAllowEmptyForNormalTextOrCorrections() {
        #expect(!(PolishOutput.acceptsEmpty(for: "send the report tomorrow")))
        #expect(!(PolishOutput.acceptsEmpty(for: "明天见 不对 后天见")))
        #expect(!(PolishOutput.acceptsEmpty(for: "cancel that meeting tomorrow")))
    }
}
