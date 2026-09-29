import Foundation
import Testing
@testable import SaidDoneCore

struct ASRCleanupTests {
    @Test func stripsTrailingHallucination() {
        #expect((ASRCleanup.strip("帮我修个bug 谢谢大家")) == "帮我修个bug")
    }
    @Test func stripsTraditionalHallucination() {
        #expect((ASRCleanup.strip("跑通这个测试 謝謝大家觀看")) == "跑通这个测试")
    }
    @Test func stripsSubscribeSpam() {
        #expect((ASRCleanup.strip("内容 请不吝点赞订阅转发打赏")) == "内容")
    }
    @Test func keepsNormalText() {
        #expect((ASRCleanup.strip("正常的一句话")) == "正常的一句话")
    }
    @Test func stripsBareTrailingThanks() {
        #expect((ASRCleanup.strip("今天我们来聊聊这个功能。谢谢")) == "今天我们来聊聊这个功能")
        #expect((ASRCleanup.strip("Let's ship it. Thank you.")) == "Let's ship it")
        #expect((ASRCleanup.strip("内容内容 谢谢你")) == "内容内容")
    }
    @Test func keepsThanksInsideSentence() {
        #expect((ASRCleanup.strip("谢谢你帮我看这个问题")) == "谢谢你帮我看这个问题")
    }
}
