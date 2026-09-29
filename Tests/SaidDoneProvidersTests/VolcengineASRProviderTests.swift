import Foundation
import Testing
@testable import SaidDoneProviders
import SaidDoneCore

/// Mocks URLProtocol so VolcengineASRProvider can be exercised against canned header/body pairs.
final class VolcASRMockProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else { fatalError("handler not set") }
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct VolcengineASRProviderTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VolcASRMockProtocol.self]
        return URLSession(configuration: config)
    }

    private let audio = AudioSamples(samples: [0.1, -0.1, 0.2, -0.2])

    @Test func successParsesText() async throws {
        VolcASRMockProtocol.handler = { req in
            #expect((req.value(forHTTPHeaderField: "X-Api-App-Key")) == "123")
            #expect((req.value(forHTTPHeaderField: "X-Api-Resource-Id")) == "volc.bigasr.auc_turbo")
            let body = #"{"result":{"text":" 你好 world \n"}}"#
            return (200, ["X-Api-Status-Code": "20000000"], Data(body.utf8))
        }
        let p = VolcengineASRProvider(appID: "123", accessToken: "tok", session: makeSession())
        let text = try await p.transcribe(audio, languageHint: nil)
        #expect(text == "你好 world")
    }

    @Test func successParsesNestedDataResult() async throws {
        VolcASRMockProtocol.handler = { _ in
            (200, ["X-Api-Status-Code": "20000000"],
             Data(#"{"data":{"result":{"text":"nested"}}}"#.utf8))
        }
        let p = VolcengineASRProvider(appID: "123", accessToken: "tok", session: makeSession())
        let text = try await p.transcribe(audio, languageHint: nil)
        #expect(text == "nested")
    }

    @Test func silenceReturnsEmptyNotError() async throws {
        // Flash resource so silence short-circuits on the single call.
        VolcASRMockProtocol.handler = { _ in
            (200, ["X-Api-Status-Code": "20000003"], Data())
        }
        let p = VolcengineASRProvider(appID: "123", accessToken: "tok", session: makeSession())
        let text = try await p.transcribe(audio, languageHint: nil)
        #expect(text == "")
    }

    @Test func businessErrorThrowsWithMessage() async {
        VolcASRMockProtocol.handler = { _ in
            (200, ["X-Api-Status-Code": "45000010", "X-Api-Message": "appid mismatch"], Data())
        }
        let p = VolcengineASRProvider(appID: "123", accessToken: "tok", session: makeSession())
        do {
            _ = try await p.transcribe(audio, languageHint: nil)
            Issue.record("expected throw")
        } catch let ProviderError.modelUnavailable(msg) {
            #expect(msg.contains("appid mismatch"), "\(msg)")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func missingCredentialsThrowsNotConfigured() async {
        let p = VolcengineASRProvider(appID: "", accessToken: "", session: makeSession())
        do {
            _ = try await p.transcribe(audio, languageHint: nil)
            Issue.record("expected throw")
        } catch let ProviderError.notConfigured(msg) {
            #expect(msg.contains("missing"), "\(msg)")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func factoryRoutesBytedanceHostToVolcengine() {
        var config = AppConfig.default
        config.asr = ProviderSelection(location: .cloud, modelID: "")
        config.cloud.asrBaseURL = "https://openspeech.bytedance.com"
        config.cloud.asrAppID = "123"
        config.cloud.asrKey = "tok"
        #expect(ProviderFactory.makeASR(config) is VolcengineASRProvider)

        config.cloud.asrBaseURL = "https://api.siliconflow.cn/v1"
        #expect(!(ProviderFactory.makeASR(config) is VolcengineASRProvider))
    }
}
