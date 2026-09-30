import Foundation
import SaidDoneCore

/// One client for every OpenAI-compatible endpoint: `/chat/completions`, `/audio/transcriptions` and `/models`.
struct OpenAICompatible: Sendable {
    let baseURL: URL
    let key: String
    let session: URLSession

    /// `dialect` nil sends only the model and the messages, which any compatible server accepts.
    func chat(model: String, _ prompt: Prompt, dialect: ChatDialect?) async throws(EngineError) -> String {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": prompt.system],
                ["role": "user", "content": prompt.user],
            ],
            "stream": false,
        ]
        if let dialect {
            body["temperature"] = 0
            switch dialect {
            case .standard:
                body["max_tokens"] = prompt.maxOutputTokens
            case .thinkingOff:
                body["max_tokens"] = prompt.maxOutputTokens
                body["thinking"] = ["type": "disabled"]
            case .openAI:
                body["max_completion_tokens"] = prompt.maxOutputTokens
                body["reasoning_effort"] = "none"
            }
        }
        var request = request("chat/completions", method: "POST", timeout: 60)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await HTTP.send(request, on: session)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else { throw .badResponse }
        return message["content"] as? String ?? ""
    }

    func transcribe(model: String, audio: EncodedAudio, hints: RecognitionHints) async throws(EngineError) -> String {
        let boundary = "SaidDone-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "json")
        if let language = hints.language { field("language", language.rawValue) }
        if let prompt = hints.prompt { field("prompt", prompt) }
        body.append(Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audio.filename)\"\r\n"
            + "Content-Type: \(audio.mimeType)\r\n\r\n").utf8))
        body.append(audio.data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = request("audio/transcriptions", method: "POST", timeout: 120)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, _) = try await HTTP.send(request, on: session)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String
        else { throw .badResponse }
        return text
    }

    /// The endpoint's model names, sorted.
    func models() async throws(EngineError) -> [String] {
        let (data, _) = try await HTTP.send(request("models", method: "GET", timeout: 15), on: session)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]]
        else { throw .badResponse }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    private func request(_ path: String, method: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }
}

/// Audio ready for upload.
struct EncodedAudio: Sendable {
    let data: Data
    let filename: String
    let mimeType: String
}

/// Chat over an OpenAI-compatible endpoint in the vendor's dialect. Servers differ in the parameters they accept, so
/// when one rejects the tuned request the model retries with a plain one and stays plain if that works.
actor CloudChatModel: ChatModel {
    private let transport: OpenAICompatible
    private let model: String
    private var dialect: ChatDialect?

    init(transport: OpenAICompatible, model: String, dialect: ChatDialect) {
        self.transport = transport
        self.model = model
        self.dialect = dialect
    }

    func reply(to prompt: Prompt) async throws(EngineError) -> String {
        do {
            return try await transport.chat(model: model, prompt, dialect: dialect)
        } catch {
            guard case .rejected = error, dialect != nil else { throw error }
            let reply = try await transport.chat(model: model, prompt, dialect: nil)
            dialect = nil
            return reply
        }
    }

    func models() async throws(EngineError) -> [String] { try await transport.models() }
}

struct CloudTranscriber: Transcriber {
    let transport: OpenAICompatible
    let model: String

    func transcribe(_ audio: AudioSamples, hints: RecognitionHints) async throws(EngineError) -> String {
        let encoded: EncodedAudio
        if let m4a = try? AudioCodec.m4a(audio) {
            encoded = EncodedAudio(data: m4a, filename: "audio.m4a", mimeType: "audio/mp4")
        } else {
            encoded = EncodedAudio(data: audio.wavData(), filename: "audio.wav", mimeType: "audio/wav")
        }
        return try await transport.transcribe(model: model, audio: encoded, hints: hints)
    }
}
