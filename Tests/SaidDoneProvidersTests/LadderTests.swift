import XCTest
import SaidDoneCore
@testable import SaidDoneProviders

/// Always-throwing LLM, to exercise ladder fail-over without runtime side effects.
private struct ThrowingLLM: LLMProvider {
    let id = "throwing-llm"
    let location: ProviderLocation = .local
    func polish(_ text: String, context: PolishContext) async throws -> String {
        throw ProviderError.modelUnavailable(id)
    }
    func translate(_ text: String, to targetLanguage: String, context: PolishContext) async throws -> String {
        throw ProviderError.modelUnavailable(id)
    }
}

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

    func testLLMPolishFallsToNextRung() async throws {
        // First rung throws -> ladder falls through to the next working rung (EchoLLM).
        let ladder = FallbackLLMProvider([ThrowingLLM(), EchoLLMProvider()])
        let out = try await ladder.polish("um  hello", context: .none)
        XCTAssertEqual(out, "um hello")   // EchoLLM collapses whitespace, no rule cleanup
    }

    // Note: factory default location is covered by SaidDoneCoreTests.testDefaultIsZeroKeyLocal.
    // We avoid constructing the real WhisperKit/MLX ladder here (heavy framework init).
}
