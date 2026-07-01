import Foundation
import SaidDoneCore

/// Reuses URLSessions for cloud providers (TLS + HTTP/2 warm) instead of .shared per call.
final class CloudSessionPool: @unchecked Sendable {
  static let shared = CloudSessionPool()
  private let lock = NSLock()
  private var sessions: [String: URLSession] = [:]

  func session(for cloud: CloudConfig) -> URLSession {
    let key = "\(cloud.proxyHost):\(cloud.proxyPort)"
    lock.lock()
    defer { lock.unlock() }
    if let existing = sessions[key] { return existing }
    let config = URLSessionConfiguration.default
    config.httpMaximumConnectionsPerHost = 6
    config.timeoutIntervalForRequest = 60
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    if !cloud.proxyHost.isEmpty, cloud.proxyPort > 0 {
      config.connectionProxyDictionary = [
        kCFNetworkProxiesHTTPEnable as String: 1,
        kCFNetworkProxiesHTTPProxy as String: cloud.proxyHost,
        kCFNetworkProxiesHTTPPort as String: cloud.proxyPort,
        kCFNetworkProxiesHTTPSEnable as String: 1,
        kCFNetworkProxiesHTTPSProxy as String: cloud.proxyHost,
        kCFNetworkProxiesHTTPSPort as String: cloud.proxyPort,
      ]
    }
    let session = URLSession(configuration: config)
    sessions[key] = session
    return session
  }

  /// Lightweight GET to prime TLS + connection pool before the first dictation.
  func warm(config: AppConfig) async {
    if config.asr.location == .cloud, !config.cloud.asrKey.isEmpty,
       let base = URL(string: config.cloud.asrBaseURL) {
      var req = URLRequest(url: base.appendingPathComponent("models"))
      req.httpMethod = "GET"
      req.timeoutInterval = 8
      req.setValue("Bearer \(config.cloud.asrKey)", forHTTPHeaderField: "Authorization")
      _ = try? await session(for: config.cloud).data(for: req)
    }
    if config.llm.location == .cloud, !config.cloud.llmKey.isEmpty,
       let base = URL(string: config.cloud.llmBaseURL) {
      var req = URLRequest(url: base.appendingPathComponent("models"))
      req.httpMethod = "GET"
      req.timeoutInterval = 8
      req.setValue("Bearer \(config.cloud.llmKey)", forHTTPHeaderField: "Authorization")
      _ = try? await session(for: config.cloud).data(for: req)
    }
  }
}
