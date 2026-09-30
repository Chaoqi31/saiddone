import Foundation
import SaidDoneCore
import Testing

/// The engine error `body` throws, or nil if it succeeds.
func failure(_ body: () async throws -> Void) async -> EngineError? {
    do {
        try await body()
        return nil
    } catch let error as EngineError {
        return error
    } catch {
        Issue.record("unexpected error \(error)")
        return nil
    }
}

/// A fake HTTP server. Each instance answers only its own random host, so tests using it can run in parallel.
final class StubServer: @unchecked Sendable {
    enum Reply {
        case http(Int, headers: [String: String] = [:], body: Data = Data())
        case failure(URLError.Code)

        static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            .http(status, headers: headers, body: try! JSONSerialization.data(withJSONObject: object))
        }
    }

    struct Received {
        let request: URLRequest
        let body: Data

        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    let host = "\(UUID().uuidString.lowercased()).test"
    var baseURL: URL { URL(string: "https://\(host)/v1")! }
    let session: URLSession

    private let lock = NSLock()
    private let respond: @Sendable (Received) -> Reply
    private var log: [Received] = []

    var received: [Received] { lock.withLock { log } }

    init(_ respond: @escaping @Sendable (Received) -> Reply) {
        self.respond = respond
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
        StubProtocol.register(self)
    }

    fileprivate func handle(_ request: URLRequest, body: Data) -> Reply {
        let received = Received(request: request, body: body)
        lock.withLock { log.append(received) }
        return respond(received)
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]

    static func register(_ server: StubServer) { lock.withLock { servers[server.host] = server } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let host = request.url?.host, let server = Self.lock.withLock({ Self.servers[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch server.handle(request, body: request.httpBody ?? Self.read(request.httpBodyStream)) {
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case let .http(status, headers, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    /// URLSession hands a request body to protocols as a stream.
    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
