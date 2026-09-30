import Foundation
import SaidDoneCore
import Testing
@testable import SaidDoneEngines

private let prompt = Prompt(system: "rules", user: "<transcription>hi</transcription>", maxOutputTokens: 512)
private var ok: [String: Any] { ["choices": [["message": ["content": "Hi."]]]] }

private func chat(_ server: StubServer, _ dialect: ChatDialect) -> CloudChatModel {
    CloudChatModel(transport: OpenAICompatible(baseURL: server.baseURL, key: "sk-test", session: server.session),
                   model: "m1", dialect: dialect)
}

struct OpenAICompatibleTests {
    @Test func chatSpeaksTheVendorDialect() async throws {
        let server = StubServer { _ in .json(ok) }
        #expect(try await chat(server, .thinkingOff).reply(to: prompt) == "Hi.")
        let sent = try #require(server.received.first)
        #expect(sent.request.url?.absoluteString == "https://\(server.host)/v1/chat/completions")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(sent.json["model"] as? String == "m1")
        #expect(sent.json["max_tokens"] as? Int == 512)
        #expect(sent.json["temperature"] as? Int == 0)
        #expect((sent.json["thinking"] as? [String: String]) == ["type": "disabled"])
        let messages = try #require(sent.json["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "rules"], ["role": "user", "content": prompt.user]])
    }

    @Test func openAIUsesItsOwnParameterNames() async throws {
        let server = StubServer { _ in .json(ok) }
        _ = try await chat(server, .openAI).reply(to: prompt)
        let body = try #require(server.received.first).json
        #expect(body["max_completion_tokens"] as? Int == 512)
        #expect(body["reasoning_effort"] as? String == "none")
        #expect(body["max_tokens"] == nil && body["thinking"] == nil)
    }

    @Test func aRejectedTunedRequestFallsBackToPlainAndStaysPlain() async throws {
        let server = StubServer { received in
            received.json["thinking"] == nil ? .json(ok) : .json(["error": ["message": "unknown field thinking"]], status: 400)
        }
        let model = chat(server, .thinkingOff)
        #expect(try await model.reply(to: prompt) == "Hi.")
        #expect(try await model.reply(to: prompt) == "Hi.")
        let bodies = server.received.map(\.json)
        #expect(bodies.count == 3)
        #expect(bodies[1]["max_tokens"] == nil && bodies[1]["temperature"] == nil, "plain carries model and messages only")
        #expect(bodies[2]["thinking"] == nil)
    }

    @Test func statusCodesMapToEngineErrors() async {
        let unauthorized = StubServer { _ in .http(401) }
        #expect(await failure { _ = try await chat(unauthorized, .standard).reply(to: prompt) } == .unauthorized)
        #expect(unauthorized.received.count == 1, "auth failures are not retried")

        let missing = StubServer { _ in .json(["error": ["message": "model not found"]], status: 404) }
        #expect(await failure { _ = try await chat(missing, .standard).reply(to: prompt) } == .rejected("model not found"))

        let garbage = StubServer { _ in .http(200, body: Data("<html>".utf8)) }
        #expect(await failure { _ = try await chat(garbage, .standard).reply(to: prompt) } == .badResponse)
    }

    @Test func transientFailuresAreRetriedTwice() async throws {
        let flaky = StubServer { _ in .http(429) }
        #expect(await failure { _ = try await chat(flaky, .standard).reply(to: prompt) } == .rateLimited)
        #expect(flaky.received.count == 3)

        let recovering = StubServer { [counter = Counter()] _ in counter.next() == 1 ? .failure(.networkConnectionLost) : .json(ok) }
        #expect(try await chat(recovering, .standard).reply(to: prompt) == "Hi.")
        #expect(recovering.received.count == 2)
    }

    @Test func transcriptionUploadsAudioWithHints() async throws {
        let server = StubServer { _ in .json(["text": "你好 Vercel"]) }
        let transcriber = CloudTranscriber(
            transport: OpenAICompatible(baseURL: server.baseURL, key: "sk", session: server.session), model: "gpt-transcribe")
        let audio = AudioSamples(samples: (0..<16_000).map { sin(Float($0) * 0.1) * 0.3 })
        let text = try await transcriber.transcribe(audio, hints: RecognitionHints(language: .chinese,
                                                                                   vocabulary: ["Vercel", "SaidDone"]))
        #expect(text == "你好 Vercel")
        let sent = try #require(server.received.first)
        #expect(sent.request.url?.path == "/v1/audio/transcriptions")
        let form = String(decoding: sent.body, as: UTF8.self)
        for part in ["name=\"model\"\r\n\r\ngpt-transcribe", "name=\"language\"\r\n\r\nzh",
                     "name=\"prompt\"\r\n\r\n我们刚才聊到了 Vercel 和 SaidDone。", "filename=\"audio.m4a\""] {
            #expect(form.contains(part), "form carries \(part)")
        }
    }

    @Test func modelListIsSorted() async throws {
        let server = StubServer { _ in .json(["data": [["id": "b"], ["id": "a"]]]) }
        let transport = OpenAICompatible(baseURL: server.baseURL, key: "", session: server.session)
        #expect(try await transport.models() == ["a", "b"])
        let sent = try #require(server.received.first)
        #expect(sent.request.httpMethod == "GET")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == nil, "keyless servers get no header")
    }
}

struct VolcengineTests {
    private func transcriber(appID: String, _ server: StubServer) -> VolcengineTranscriber {
        VolcengineTranscriber(appID: appID, key: "token", session: server.session, endpoint: server.baseURL)
    }

    private let audio = AudioSamples(samples: [Float](repeating: 0.1, count: 8_000))

    @Test func requestCarriesCredentialsAudioAndHotwords() throws {
        let server = StubServer { _ in .http(200) }
        let newConsole = transcriber(appID: "", server).request(audio, hints: RecognitionHints(vocabulary: ["SaidDone"]))
        #expect(newConsole.value(forHTTPHeaderField: "X-Api-Key") == "token")
        #expect(newConsole.value(forHTTPHeaderField: "X-Api-App-Key") == nil)
        #expect(newConsole.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.bigasr.auc_turbo")

        let oldConsole = transcriber(appID: "123", server).request(audio, hints: RecognitionHints())
        #expect(oldConsole.value(forHTTPHeaderField: "X-Api-App-Key") == "123")
        #expect(oldConsole.value(forHTTPHeaderField: "X-Api-Access-Key") == "token")

        let body = try #require(try JSONSerialization.jsonObject(with: newConsole.httpBody!) as? [String: Any])
        let audioField = try #require(body["audio"] as? [String: String])
        #expect(audioField["format"] == "wav")
        #expect(Data(base64Encoded: audioField["data"]!) == audio.wavData())
        let context = try #require(((body["request"] as? [String: Any])?["corpus"] as? [String: String])?["context"])
        #expect(context == #"{"hotwords":[{"word":"SaidDone"}]}"#)
    }

    @Test func statusHeaderDecidesTheOutcome() async throws {
        let success = StubServer { _ in .json(["result": ["text": "你好"]], headers: ["X-Api-Status-Code": "20000000"]) }
        #expect(try await transcriber(appID: "", success).transcribe(audio, hints: RecognitionHints()) == "你好")

        let silence = StubServer { _ in .http(200, headers: ["X-Api-Status-Code": "20000003"]) }
        #expect(try await transcriber(appID: "", silence).transcribe(audio, hints: RecognitionHints()) == "")

        let busy = StubServer { _ in .http(200, headers: ["X-Api-Status-Code": "55000031"]) }
        #expect(await failure { _ = try await transcriber(appID: "", busy).transcribe(audio, hints: RecognitionHints()) }
                == .serverBusy)

        let invalid = StubServer { _ in
            .http(200, headers: ["X-Api-Status-Code": "45000001", "X-Api-Message": "invalid audio"])
        }
        #expect(await failure { _ = try await transcriber(appID: "", invalid).transcribe(audio, hints: RecognitionHints()) }
                == .rejected("invalid audio"))
    }

    @Test func aMissingKeyFailsBeforeAnyRequest() async {
        let server = StubServer { _ in .http(200) }
        let unkeyed = VolcengineTranscriber(appID: "", key: "", session: server.session)
        #expect(await failure { _ = try await unkeyed.transcribe(audio, hints: RecognitionHints()) } == .missingCredential)
        #expect(server.received.isEmpty)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
