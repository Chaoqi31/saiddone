import XCTest
@testable import SaidDoneCore

final class DictionaryLearningTests: XCTestCase {
    func testSingleTermSwap() {
        let t = DictionaryLearning.diffTerms(old: "deploy 到 Verso", new: "deploy 到 Vercel")
        XCTAssertEqual(t, [DictionaryEntry(wrong: "Verso", right: "Vercel")])
    }
    func testTwoTermSwap() {
        let t = DictionaryLearning.diffTerms(old: "push 到 man 用 Verso", new: "push 到 main 用 Vercel")
        XCTAssertEqual(t, [.init(wrong: "man", right: "main"), .init(wrong: "Verso", right: "Vercel")])
    }
    func testNoLatinChange() {
        XCTAssertTrue(DictionaryLearning.diffTerms(old: "今天开会", new: "明天开会").isEmpty)
    }
    func testUnbalancedReturnsEmpty() {
        // counts differ -> don't guess
        XCTAssertTrue(DictionaryLearning.diffTerms(old: "use Verso", new: "use Vercel now Extra").isEmpty)
    }
}
