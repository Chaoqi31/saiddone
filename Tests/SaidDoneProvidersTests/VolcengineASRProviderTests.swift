import XCTest
@testable import SaidDoneProviders
import SaidDoneCore

/// Mocks URLProtocol so VolcengineASRProvider can be exercised against canned header/body pairs.
final class VolcASRMockProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: String], Data))?

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

final class VolcengineASRProviderTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VolcASRMockProtocol.self]
        return URLSession(configuration: config)
    }

    private let audio = AudioSamples(samples: [0.1, -0.1, 0.2, -0.2])

    override func tearDown() {
        VolcASRMockProtocol.handler = nil
    }

    func testSuccessParsesText() async throws {
        VolcASRMockProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Api-App-Key"), "123")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Api-Resource-Id"), "volc.bigasr.auc_turbo")
            let body = #"{"result":{"text":" 你好 world \n"}}"#
            return (200, ["X-Api-Status-Code": "20000000"], Data(body.utf8))
        }
        let p = VolcengineASRProvider(appID: "123", accessToken: "tok", session: makeSession())
        let text = try await p.transcribe(audio, languageHint: nil)
        XCTAssertEqual(text, "你好 world")
    }

    func testSuccessParsesNestedDataResult() async throws {
        VolcASRMockProtocol.handler = { _ in
            (200, ["X-Api-Status-Code": "20000000"],
             Data(#"{"data":{"result":{"text":"nested"}}}"#.utf8))
        }
        let p = VolcengineASRProvider(appID: "123", accessToken: "tok", session: makeSession())
        let text = try await p.transcribe(audio, languageHint: nil)
        XCTAssertEqual(text, "nested")
    }

    func testSubmitQueryFlowPollsUntilDone() async throws {
        // Sequence: submit (ok, empty) → query (processing) → query (done, text).
        let responses: [(Int, String, String)] = [
            (200, "20000000", "{}"),
            (200, "20000001", #"{"result":{"text":""}}"#),
            (200, "20000000", #"{"result":{"text":"你好 world"}}"#),
        ]
        var call = 0
        VolcASRMockProtocol.handler = { req in
            let (status, code, body) = responses[min(call, responses.count - 1)]
            call += 1
            XCTAssertTrue(req.url!.path.contains("submit") || req.url!.path.contains("query"))
            return (status, ["X-Api-Status-Code": code], Data(body.utf8))
        }
        let p = VolcengineASRProvider(appID: "123", accessToken: "tok",
                                      resourceID: "volc.seedasr.auc", session: makeSession())
        let text = try await p.transcribe(audio, languageHint: nil)
        XCTAssertEqual(text, "你好 world")
        XCTAssertEqual(call, 3)
    }

    func testSilenceReturnsEmptyNotError() async throws {
        // Flash resource so silence short-circuits on the single call.
        VolcASRMockProtocol.handler = { _ in
            (200, ["X-Api-Status-Code": "20000003"], Data())
        }
        let p = VolcengineASRProvider(appID: "123", accessToken: "tok", session: makeSession())
        let text = try await p.transcribe(audio, languageHint: nil)
        XCTAssertEqual(text, "")
    }

    func testBusinessErrorThrowsWithMessage() async {
        VolcASRMockProtocol.handler = { _ in
            (200, ["X-Api-Status-Code": "45000010", "X-Api-Message": "appid mismatch"], Data())
        }
        let p = VolcengineASRProvider(appID: "123", accessToken: "tok", session: makeSession())
        do {
            _ = try await p.transcribe(audio, languageHint: nil)
            XCTFail("expected throw")
        } catch let ProviderError.modelUnavailable(msg) {
            XCTAssertTrue(msg.contains("appid mismatch"), msg)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMissingCredentialsThrowsNotConfigured() async {
        let p = VolcengineASRProvider(appID: "", accessToken: "", session: makeSession())
        do {
            _ = try await p.transcribe(audio, languageHint: nil)
            XCTFail("expected throw")
        } catch let ProviderError.notConfigured(msg) {
            XCTAssertTrue(msg.contains("missing"), msg)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testFactoryRoutesBytedanceHostToVolcengine() {
        var config = AppConfig(directory: URL(fileURLWithPath: "/tmp"))
        config.asr = ProviderSelection(location: .cloud, modelID: "")
        config.cloud.asrBaseURL = "https://openspeech.bytedance.com"
        config.cloud.asrAppID = "123"
        config.cloud.asrKey = "tok"
        XCTAssertTrue(ProviderFactory.makeASR(config) is VolcengineASRProvider)

        config.cloud.asrBaseURL = "https://api.siliconflow.cn/v1"
        XCTAssertFalse(ProviderFactory.makeASR(config) is VolcengineASRProvider)
    }
}
