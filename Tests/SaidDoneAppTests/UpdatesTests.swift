import Foundation
import Testing
@testable import SaidDoneApp

struct UpdatesTests {
    @Test func versionsCompareNumerically() {
        #expect(Updates.isNewer("2.0.10", than: "2.0.9"))
        #expect(Updates.isNewer("2.1", than: "2.0.9"))
        #expect(!Updates.isNewer("2.0.0", than: "2.0.0"))
        #expect(!Updates.isNewer("1.9.9", than: "2.0.0"))
    }

    @Test func readsTheLatestReleaseAndSkipsPrereleases() throws {
        let release = #"{"tag_name": "v2.1.0", "html_url": "https://github.com/Chaoqi31/saiddone/releases/tag/v2.1.0", "draft": false, "prerelease": false}"#
        #expect(Updates.release(from: Data(release.utf8))
                == .init(version: "2.1.0", page: URL(string: "https://github.com/Chaoqi31/saiddone/releases/tag/v2.1.0")!))
        let beta = #"{"tag_name": "v2.2.0-beta", "html_url": "https://github.com/x", "prerelease": true}"#
        #expect(Updates.release(from: Data(beta.utf8)) == nil)
        #expect(Updates.release(from: Data("{}".utf8)) == nil)
    }
}
