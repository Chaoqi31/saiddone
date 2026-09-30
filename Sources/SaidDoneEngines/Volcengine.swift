import Foundation
import SaidDoneCore

/// Volcengine (Doubao) large-model file recognition, "flash" tier: one synchronous request per recording.
struct VolcengineTranscriber: Transcriber {
    static let flash = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash")!
    static let resource = "volc.bigasr.auc_turbo"

    /// Empty for consoles that issue a single API key.
    let appID: String
    let key: String
    let session: URLSession
    var endpoint = VolcengineTranscriber.flash

    func transcribe(_ audio: AudioSamples, hints: RecognitionHints) async throws(EngineError) -> String {
        guard !key.isEmpty else { throw .missingCredential }
        let (data, response) = try await HTTP.send(request(audio, hints: hints), on: session)
        switch response.value(forHTTPHeaderField: "X-Api-Status-Code") ?? "20000000" {
        case "20000000":
            break
        case "20000003", "45000002":
            return ""   // silence, or no audio at all
        case let code:
            let message = response.value(forHTTPHeaderField: "X-Api-Message") ?? code
            throw code.hasPrefix("55") ? .serverBusy : .rejected(message)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let text = result["text"] as? String
        else { throw .badResponse }
        return text
    }

    func request(_ audio: AudioSamples, hints: RecognitionHints) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if appID.isEmpty {
            request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        } else {
            request.setValue(appID, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(key, forHTTPHeaderField: "X-Api-Access-Key")
        }
        request.setValue(Self.resource, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")

        var options: [String: Any] = ["model_name": "bigmodel", "enable_itn": true, "enable_punc": true]
        if !hints.vocabulary.isEmpty,
           let context = try? JSONSerialization.data(withJSONObject: ["hotwords": hints.vocabulary.map { ["word": $0] }]) {
            options["corpus"] = ["context": String(decoding: context, as: UTF8.self)]
        }
        let body: [String: Any] = [
            "user": ["uid": appID.isEmpty ? "SaidDone" : appID],
            "audio": ["format": "wav", "data": audio.wavData().base64EncodedString()],
            "request": options,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }
}
