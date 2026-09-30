import Foundation
import SaidDoneCore

/// HTTP plumbing shared by the cloud engines: sessions, retries, and mapping failures to `EngineError`.
enum HTTP {
    static func session(proxy: Proxy?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        if let proxy {
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: proxy.host,
                kCFNetworkProxiesHTTPPort as String: proxy.port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: proxy.host,
                kCFNetworkProxiesHTTPSPort as String: proxy.port,
            ]
        }
        return URLSession(configuration: configuration)
    }

    /// Returns the body of a 2xx response. Retries dropped connections, 408, 429 and 5xx twice with backoff;
    /// every other failure is thrown at once.
    static func send(_ request: URLRequest, on session: URLSession) async throws(EngineError) -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            let failure: EngineError
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw EngineError.badResponse }
                if (200..<300).contains(http.statusCode) { return (data, http) }
                failure = error(status: http.statusCode, body: data)
            } catch let error as URLError {
                failure = Self.error(error)
            } catch {
                throw Task.isCancelled ? .cancelled : .badResponse
            }
            guard attempt < 2, failure.isTransient, !Task.isCancelled else { throw failure }
            attempt += 1
            do { try await Task.sleep(for: .milliseconds(400 * attempt * attempt)) } catch { throw .cancelled }
        }
    }

    static func error(status: Int, body: Data) -> EngineError {
        switch status {
        case 401, 403: .unauthorized
        case 408: .timedOut
        case 429: .rateLimited
        case 500...599: .serverBusy
        default: .rejected(message(in: body) ?? "HTTP \(status)")
        }
    }

    static func error(_ error: URLError) -> EngineError {
        switch error.code {
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        default: .offline
        }
    }

    /// The human-readable part of an error body: OpenAI's `{"error": {"message"}}` and its common variants.
    static func message(in body: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let candidates: [Any?] = [
            (json?["error"] as? [String: Any])?["message"], json?["error"], json?["message"], json?["detail"],
        ]
        if let message = candidates.lazy.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) {
            return message
        }
        let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

extension EngineError {
    /// Worth retrying after a short wait.
    var isTransient: Bool {
        switch self {
        case .offline, .timedOut, .rateLimited, .serverBusy: true
        default: false
        }
    }
}
