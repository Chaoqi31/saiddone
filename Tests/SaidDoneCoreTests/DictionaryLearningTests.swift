import Foundation
import Testing
@testable import SaidDoneCore

struct DictionaryLearningTests {
    @Test func singleTermSwap() {
        let t = DictionaryLearning.diffTerms(old: "deploy 到 Verso", new: "deploy 到 Vercel")
        #expect(t == ([DictionaryEntry(wrong: "Verso", right: "Vercel")]))
    }
    @Test func twoTermSwap() {
        let t = DictionaryLearning.diffTerms(old: "push 到 man 用 Verso", new: "push 到 main 用 Vercel")
        #expect(t == ([.init(wrong: "man", right: "main"), .init(wrong: "Verso", right: "Vercel")]))
    }
    @Test func noLatinChange() {
        #expect(DictionaryLearning.diffTerms(old: "今天开会", new: "明天开会").isEmpty)
    }
    @Test func unbalancedReturnsEmpty() {
        // counts differ -> don't guess
        #expect(DictionaryLearning.diffTerms(old: "use Verso", new: "use Vercel now Extra").isEmpty)
    }
}
