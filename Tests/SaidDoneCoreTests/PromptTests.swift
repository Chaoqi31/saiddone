import Foundation
import Testing
@testable import SaidDoneCore

struct PromptTests {
    @Test func contextPrefixCarriesLanguageProfileTermsAndTone() {
        let context = PromptContext(spokenLanguage: .chinese, profile: "iOS 工程师", tone: "casual",
                                    terms: ["Vercel", "SaidDone"])
        let prompt = Polish.prompt("hello", context)
        #expect(prompt.system.hasPrefix("【主要语言】中文"))
        #expect(prompt.system.contains("【用户背景】iOS 工程师"))
        #expect(prompt.system.contains("Vercel、SaidDone"))
        #expect(prompt.system.contains("【语气】casual"))
        #expect(prompt.user.contains("<transcription>\nhello\n</transcription>"))
    }

    @Test func outputBudgetScalesWithInputWithinBounds() {
        #expect(Prompt.budget(for: "hi") == 512)
        #expect(Prompt.budget(for: String(repeating: "字", count: 1000)) == 3256)
        #expect(Prompt.budget(for: String(repeating: "字", count: 10_000)) == 8192)
    }

    @Test func replyCleanupStripsThinkingTagsFencesAndPlaceholders() {
        #expect(Reply.clean("<think>hmm</think>\nHello.") == "Hello.")
        #expect(Reply.clean("```text\nHello.\n```") == "Hello.")
        #expect(Reply.clean("<transcription>Hello.</transcription>") == "Hello.")
        #expect(Reply.clean("（空文本）") == "")
        #expect(Reply.clean("empty") == "")
    }

    @Test func emptyReplyIsLegitimateOnlyForFillerOrASpokenCancel() {
        #expect(Polish.parse("", source: "嗯 那个 就是 呃") == .nothingSaid)
        #expect(Polish.parse("", source: "send email no wait cancel that") == .nothingSaid)
        #expect(Polish.parse("", source: "给小王发消息说明天开会 算了") == .nothingSaid)
        #expect(Polish.parse("", source: "send the report tomorrow") == .empty)
        #expect(Polish.parse("", source: "明天见 不对 后天见") == .empty)
        #expect(Polish.parse("", source: "cancel that meeting tomorrow") == .empty)
        #expect(Polish.parse("Hi.", source: "嗯 算了") == .text("Hi."))
    }

    @Test func fillerDetection() {
        #expect(Transcript.isFillerOnly("嗯，那个……就是 呃"))
        #expect(Transcript.isFillerOnly("um, uh, like"))
        #expect(!Transcript.isFillerOnly("嗯 好的我知道了"))
        #expect(!Transcript.isFillerOnly("umbrella"))
    }

    @Test func askReplyNeverOverwritesTheSelectionUnlessItSaysEdit() {
        #expect(Ask.parse("EDIT:\nNew text", selection: "old") == .replaceSelection("New text"))
        #expect(Ask.parse("EDIT:\nNew text", selection: "") == .answer("New text"))
        #expect(Ask.parse("ANSWER: 42", selection: "old") == .answer("42"))
        #expect(Ask.parse("Just prose", selection: "old") == .answer("Just prose"))
        #expect(Ask.parse("EDIT:", selection: "old") == nil)
        #expect(Ask.parse("  ", selection: "old") == nil)
    }

    @Test func translatePromptNamesTheTarget() {
        let prompt = Translate.prompt("你好", to: "ja", .none)
        #expect(prompt.system.contains("Japanese"))
        #expect(prompt.user.hasSuffix("Output only the final Japanese translation."))
    }
}

struct AskIntentTests {
    @Test(arguments: [
        ("search swift actors on YouTube", "swift actors", AskIntent.Site.youtube),
        ("Search GitHub for whisperkit.", "whisperkit", .github),
        ("google best ramen in tokyo", "best ramen in tokyo", .google),
        ("在百度上搜一下今天的天气", "今天的天气", .baidu),
        ("帮我在B站搜索 SwiftUI 教程", "SwiftUI 教程", .bilibili),
        ("搜一下 苹果发布会", "苹果发布会", .google),
    ])
    func recognizesExplicitSearches(request: String, query: String, site: AskIntent.Site) {
        #expect(AskIntent.parse(request) == AskIntent(query: query, site: site))
    }

    @Test func questionsGoToTheModel() {
        #expect(AskIntent.parse("what is the capital of France") == nil)
        #expect(AskIntent.parse("帮我写一封邮件") == nil)
        #expect(AskIntent.parse("how do I search in vim") == nil)
    }
}
