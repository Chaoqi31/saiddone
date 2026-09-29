import Foundation
import Testing
import SaidDoneCore
@testable import SaidDoneApp

/// The user-facing error mapping (AppController.friendlyError) — every pipeline failure funnels
/// through it, so a wrong bucket means a misleading message on screen.
@MainActor
struct FriendlyErrorTests {
    private func message(_ error: Error) -> String { AppController.friendlyError(error) }

    @Test func providerErrorBuckets() {
        #expect((message(ProviderError.notConfigured("x"))) == (NSLocalizedString("Cloud setup issue — check your API key and endpoint in Settings → Cloud.", comment: "error")))
        #expect((message(ProviderError.modelUnavailable("x"))) == (NSLocalizedString("Engine unavailable. Please try again shortly.", comment: "error")))
        #expect((message(ProviderError.latencyBudgetExceeded)) == (NSLocalizedString("Timed out. Please try again.", comment: "error")))
    }

    @Test func networkErrorsMapToNetworkMessage() {
        let network = NSLocalizedString("Network unavailable. Check your connection and try again.", comment: "error")
        #expect((message(URLError(.notConnectedToInternet))) == network)
        #expect((message(URLError(.timedOut))) == network)
    }

    @Test func unknownErrorGetsGenericMessage() {
        struct Weird: Error {}
        #expect((message(Weird())) == (NSLocalizedString("Transcription failed. Please try again.", comment: "error")))
    }
}
