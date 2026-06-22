import Foundation
import SaidDoneCore

/// Shared HTTP execution for cloud providers: bounded by the request's timeout, retries transient
/// failures (network drops, 408/429/5xx) with quadratic backoff, and maps status codes to the right
/// ProviderError so the user sees an accurate message (auth vs. busy vs. timeout).
enum CloudHTTP {
    static func send(label: String, maxRetries: Int = 2,
                     _ perform: () async throws -> (Data, URLResponse)) async throws -> Data {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await perform()
                guard let http = response as? HTTPURLResponse else {
                    throw ProviderError.modelUnavailable("\(label): no HTTP response")
                }
                switch http.statusCode {
                case 200..<300:
                    return data
                case 401, 403:
                    throw ProviderError.notConfigured("\(label): unauthorized (\(http.statusCode))")
                case 408, 429, 500...599:
                    if attempt < maxRetries { attempt += 1; try? await backoff(attempt); continue }
                    throw ProviderError.modelUnavailable("\(label): server busy (\(http.statusCode))")
                default:
                    let snippet = String(data: data.prefix(180), encoding: .utf8) ?? ""
                    throw ProviderError.notConfigured("\(label): HTTP \(http.statusCode) \(snippet)")
                }
            } catch let e as URLError {
                let transient: Set<URLError.Code> = [
                    .timedOut, .networkConnectionLost, .cannotConnectToHost,
                    .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost,
                ]
                if transient.contains(e.code), attempt < maxRetries { attempt += 1; try? await backoff(attempt); continue }
                if e.code == .timedOut { throw ProviderError.latencyBudgetExceeded }
                throw e   // non-transient network error — friendlyError maps it
            }
        }
    }

    private static func backoff(_ attempt: Int) async throws {
        try await Task.sleep(for: .milliseconds(400 * attempt * attempt))   // 400ms, 1.6s
    }
}

/// Cloud LLM via an OpenAI-compatible Chat Completions endpoint (ADR-0001 co-equal cloud path).
/// Opt-in: requires a user-provided key. Data leaves the device — caller must disclose this (GOALS).
public struct CloudLLMProvider: LLMProvider {
    public let id: String
    public let location: ProviderLocation = .cloud

    let apiKey: String
    let baseURL: URL
    let model: String
    let session: URLSession

    public init(apiKey: String, baseURL: URL, model: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.session = session
        self.id = "cloud-llm:\(model)"
    }

    public func polish(_ text: String, context: PolishContext) async throws -> String {
        return try await chat(system: PolishPrompt.system(context: context), user: text)
    }

    public func translate(_ text: String, to targetLanguage: String, context: PolishContext) async throws -> String {
        let sys = "Translate the user's text into \(targetLanguage). Output only the translation, no notes."
        return try await chat(system: sys, user: text)
    }

    public func ask(_ question: String, selection: String, context: PolishContext) async throws -> String {
        let sys = """
        你是智能助手（类似 Typeless「随便问」）。用户用语音提出了请求。
        - 若有【原文】（选中的文本）：按请求编辑原文，或回答关于原文的问题（摘要、解释、翻译等）。
        - 若无原文：直接回答用户的问题，或按请求生成内容。
        中文用简体。只输出最终结果，不要解释、不要引号、不要复述指令。
        """
        let user = selection.isEmpty ? "请求：\(question)" : "请求：\(question)\n\n【原文】：\(selection)"
        return try await chat(system: sys, user: user)
    }

    private func chat(system: String, user: String) async throws -> String {
        guard !apiKey.isEmpty else { throw ProviderError.notConfigured("cloud LLM API key missing") }
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0.2,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await CloudHTTP.send(label: "cloud LLM") { try await session.data(for: req) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ProviderError.modelUnavailable("cloud LLM: unexpected response")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Cloud ASR via an OpenAI-compatible `/audio/transcriptions` endpoint (multipart WAV upload).
/// Opt-in: requires a key; audio leaves the device.
public struct CloudASRProvider: ASRProvider {
    public let id: String
    public let location: ProviderLocation = .cloud
    let apiKey: String
    let baseURL: URL
    let model: String
    let session: URLSession

    public init(apiKey: String, baseURL: URL, model: String = "whisper-1", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.session = session
        self.id = "cloud-asr:\(model)"
    }

    public func transcribe(_ audio: AudioSamples, languageHint: String?) async throws -> String {
        guard !apiKey.isEmpty else { throw ProviderError.notConfigured("cloud ASR API key missing") }
        let boundary = "saiddone-\(UInt64(audio.samples.count))-boundary"
        var req = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60   // audio upload can be larger/slower than a chat call
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        if let languageHint { field("language", languageHint) }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio.wavData())
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let data = try await CloudHTTP.send(label: "cloud ASR") { try await session.upload(for: req, from: body) }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw ProviderError.modelUnavailable("cloud ASR: unexpected response")
    }
}

