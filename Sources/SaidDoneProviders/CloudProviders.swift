import Foundation
import SaidDoneCore

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
        return try await chat(system: polishSystemPrompt(tone: context.tonePrompt), user: text)
    }

    public func translate(_ text: String, to targetLanguage: String, context: PolishContext) async throws -> String {
        let sys = "Translate the user's text into \(targetLanguage). Output only the translation, no notes."
        return try await chat(system: sys, user: text)
    }

    private func chat(system: String, user: String) async throws -> String {
        guard !apiKey.isEmpty else { throw ProviderError.notConfigured("cloud LLM API key missing") }
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
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

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderError.notConfigured("cloud LLM HTTP error")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ProviderError.notConfigured("cloud LLM: unexpected response")
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

        let (data, response) = try await session.upload(for: req, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderError.notConfigured("cloud ASR HTTP error")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw ProviderError.notConfigured("cloud ASR: unexpected response")
    }
}

