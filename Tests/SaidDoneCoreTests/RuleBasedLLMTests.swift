import XCTest
@testable import SaidDoneCore

final class RuleBasedLLMTests: XCTestCase {
    let llm = RuleBasedLLM()

    func testRemovesEnglishFillersAndCases() async throws {
        let out = try await llm.polish("um i think uh we should ship it", context: .none)
        XCTAssertEqual(out, "I think we should ship it.")
    }

    func testCollapsesRepeats() async throws {
        let out = try await llm.polish("the the cat sat", context: .none)
        XCTAssertEqual(out, "The cat sat.")
    }

    func testRemovesChineseFiller() async throws {
        let out = try await llm.polish("那个 我们 明天 开会", context: .none)
        XCTAssertEqual(out, "我们 明天 开会")
    }

    func testSpacingBeforePunctuation() async throws {
        let out = try await llm.polish("hello , world", context: .none)
        XCTAssertEqual(out, "Hello, world.")
    }

    func testTranslateThrows() async {
        do {
            _ = try await llm.translate("hi", to: "zh", context: .none)
            XCTFail("expected throw")
        } catch {
            // expected: RuleBasedLLM cannot translate
        }
    }
}
