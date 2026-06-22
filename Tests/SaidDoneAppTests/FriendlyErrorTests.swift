import XCTest
import SaidDoneCore
@testable import SaidDoneApp

/// The user-facing error mapping (AppController.friendlyError) — every pipeline failure funnels
/// through it, so a wrong bucket means a misleading message on screen.
@MainActor
final class FriendlyErrorTests: XCTestCase {
    private func message(_ error: Error) -> String { AppController.friendlyError(error) }

    func testProviderErrorBuckets() {
        XCTAssertEqual(message(ProviderError.notConfigured("x")),
                       NSLocalizedString("Cloud setup issue — check your API key and endpoint in Settings → Cloud.", comment: "error"))
        XCTAssertEqual(message(ProviderError.modelUnavailable("x")),
                       NSLocalizedString("Engine unavailable. Please try again shortly.", comment: "error"))
        XCTAssertEqual(message(ProviderError.latencyBudgetExceeded),
                       NSLocalizedString("Timed out. Please try again.", comment: "error"))
    }

    func testNetworkErrorsMapToNetworkMessage() {
        let network = NSLocalizedString("Network unavailable. Check your connection and try again.", comment: "error")
        XCTAssertEqual(message(URLError(.notConnectedToInternet)), network)
        XCTAssertEqual(message(URLError(.timedOut)), network)
    }

    func testUnknownErrorGetsGenericMessage() {
        struct Weird: Error {}
        XCTAssertEqual(message(Weird()),
                       NSLocalizedString("Transcription failed. Please try again.", comment: "error"))
    }
}
