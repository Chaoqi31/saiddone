import Foundation
import SaidDoneCore

/// Volcengine (Doubao) "录音文件识别大模型 — 极速版" ASR: one synchronous JSON request with
/// base64 WAV audio, no submit/query polling (clips ≤ 2h). Selected by ProviderFactory when the
/// cloud ASR base URL points at openspeech.bytedance.com. Audio leaves the device (GOALS disclosure).
public struct VolcengineASRProvider: ASRProvider {
    public let id: String
    public let location: ProviderLocation = .cloud

    static let flashURL = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash")!
    static let submitURL = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit")!
    static let queryURL = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/query")!
    /// X-Api-Status-Code "no speech detected" — not an error, just silence.
    static let silenceCode = "20000003"
    static let okCode = "20000000"

    let appID: String
    let accessToken: String
    /// `volc.bigasr.auc_turbo` (极速版). Editable via the Model field to try other tiers.
    let resourceID: String
    let session: URLSession

    public init(appID: String, accessToken: String,
                resourceID: String = "volc.bigasr.auc_turbo", session: URLSession = .shared) {
        self.appID = appID
        self.accessToken = accessToken
        self.resourceID = resourceID
        self.session = session
        self.id = "volcengine-asr:\(resourceID)"
    }

    public func transcribe(_ audio: AudioSamples, languageHint: String?) async throws -> String {
        guard !appID.isEmpty, !accessToken.isEmpty else {
            throw ProviderError.notConfigured("Volcengine ASR: APP ID / Access Token missing")
        }
        let requestID = UUID().uuidString
        // 极速版 (`volc.bigasr.auc_turbo`) = single synchronous flash call;
        // 标准版 (`volc.seedasr.auc`) = submit + poll query with the same request id.
        if resourceID.contains("_turbo") {
            let (data, _) = try await run(Self.flashURL, requestID: requestID, body: body(audio))
            return try Self.text(from: data)
        }
        _ = try await run(Self.submitURL, requestID: requestID, body: body(audio))
        let deadline = Date().addingTimeInterval(55)
        while Date() < deadline {
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(400))
            let (data, done) = try await run(Self.queryURL, requestID: requestID, body: [:])
            if done, let text = try? Self.text(from: data) {
                return text   // empty once the job finishes on silent audio
            }
        }
        throw ProviderError.latencyBudgetExceeded
    }

    private func body(_ audio: AudioSamples) -> [String: Any] {
        // WAV: universally accepted by this API (m4a is not documented as supported).
        [
            "user": ["uid": appID],
            "audio": [
                "format": "wav",
                "data": audio.wavData().base64EncodedString(),
            ],
            "request": [
                "model_name": "bigmodel",
                "show_utterances": false,
                "enable_itn": true,   // digit/punctuation normalisation
            ],
        ]
    }

    /// Executes one API call. Returns `(body, terminal)` — `terminal` false means the job is still
    /// processing (query flow) and the caller should poll again.
    private func run(_ url: URL, requestID: String, body: [String: Any]) async throws -> (Data, Bool) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(appID, forHTTPHeaderField: "X-Api-App-Key")
        req.setValue(accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        req.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        req.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
        req.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.modelUnavailable("Volcengine ASR: no HTTP response")
        }
        switch http.statusCode {
        case 401, 403:
            throw ProviderError.notConfigured("Volcengine ASR: unauthorized (\(http.statusCode))")
        case 200..<300:
            break
        default:
            let snippet = String(data: data.prefix(180), encoding: .utf8) ?? ""
            throw ProviderError.modelUnavailable("Volcengine ASR: HTTP \(http.statusCode) \(snippet)")
        }
        // Business status travels in a response header, not the HTTP code. Silence ("no speech")
        // is represented downstream as an empty `result.text` so callers see "" instead of an error.
        let status = http.value(forHTTPHeaderField: "X-Api-Status-Code") ?? Self.okCode
        // Silence ("no speech") is terminal, represented downstream as empty `result.text`.
        if status == Self.silenceCode { return (Data(#"{"result":{"text":""}}"#.utf8), true) }
        // Processing/queued (query flow) — caller keeps polling; the body has no text yet.
        if status == "20000001" || status == "20000002" { return (Data(#"{"result":{"text":""}}"#.utf8), false) }
        guard status == Self.okCode else {
            let message = http.value(forHTTPHeaderField: "X-Api-Message") ?? status
            throw ProviderError.modelUnavailable("Volcengine ASR: \(message)")
        }
        return (data, true)
    }

    /// Tolerant parse: observed shapes are `{"result":{"text":…}}` and `{"data":{"result":{"text":…}}}`.
    static func text(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.modelUnavailable("Volcengine ASR: unexpected response")
        }
        let result = (json["result"] as? [String: Any])
            ?? (json["data"] as? [String: Any])?["result"] as? [String: Any]
        if let text = result?["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw ProviderError.modelUnavailable("Volcengine ASR: unexpected response")
    }
}
