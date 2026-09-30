import AppKit
import Foundation
import Observation

/// Tells the user when GitHub has a newer release, checked at launch and then daily. SaidDone isn't signed with a
/// Developer ID, so it can't update itself; it links to the release page instead.
@MainActor @Observable
final class Updates {
    struct Release: Equatable, Sendable {
        let version: String
        let page: URL
    }

    private(set) var available: Release?

    /// nil in development builds, which have no version to compare.
    private let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    private static let latest = URL(string: "https://api.github.com/repos/Chaoqi31/saiddone/releases/latest")!

    func start() {
        guard current != nil else { return }
        Task {
            while !Task.isCancelled {
                await check()
                try? await Task.sleep(for: .seconds(86_400))
            }
        }
    }

    func open() {
        if let available { NSWorkspace.shared.open(available.page) }
    }

    private func check() async {
        var request = URLRequest(url: Self.latest, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let current,
              let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = Self.release(from: data), Self.isNewer(release.version, than: current)
        else { return }
        available = release
    }

    nonisolated static func release(from data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page)
    }

    /// "2.0.10" is newer than "2.0.9".
    nonisolated static func isNewer(_ version: String, than current: String) -> Bool {
        version.compare(current, options: .numeric) == .orderedDescending
    }
}
