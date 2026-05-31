import XCTest
import SaidDoneCore
@testable import SaidDoneProviders

final class LadderTests: XCTestCase {
    let audio = AudioSamples(samples: [0, 0, 0])

    func testASRFailsOverToWorkingRung() async throws {
        // MLX scaffold throws -> ladder must fall through to the Echo (working) rung.
        let ladder = FallbackASRProvider([
            MLXQwenASRProvider(),
            EchoASRProvider(preset: "fell through ok"),
        ])
        let out = try await ladder.transcribe(audio, languageHint: nil)
        XCTAssertEqual(out, "fell through ok")
    }

    func testASRThrowsWhenAllRungsFail() async {
        let ladder = FallbackASRProvider([MLXQwenASRProvider(), MLXQwenASRProvider()])
        do {
            _ = try await ladder.transcribe(audio, languageHint: nil)
            XCTFail("expected throw")
        } catch { /* expected */ }
    }

    func testLLMPolishFallsToRuleBased() async throws {
        // MLX scaffold throws on polish -> deterministic RuleBasedLLM floor takes over.
        let ladder = FallbackLLMProvider([MLXQwenLLMProvider(), RuleBasedLLM()])
        let out = try await ladder.polish("um  hello", context: .none)
        XCTAssertEqual(out, "Hello.")
    }

    func testFactoryDefaultsToLocalLadders() {
        let asr = ProviderFactory.makeASR(.default)
        let llm = ProviderFactory.makeLLM(.default)
        XCTAssertEqual(asr.location, .local)
        XCTAssertEqual(llm.location, .local)
    }
}
