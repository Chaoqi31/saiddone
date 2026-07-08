import XCTest
@testable import SaidDoneCore

final class CloudProviderRegistryTests: XCTestCase {
    func testRequiredProviderPresets() {
        let ids = Set(CloudProviderRegistry.builtIn.map(\.id))
        for id in ["openai", "deepseek", "moonshot", "zhipu", "siliconflow"] {
            XCTAssertTrue(ids.contains(id), "missing provider: \(id)")
        }
    }

    func testBuiltInIDsUniqueAndURLsValid() {
        let ids = CloudProviderRegistry.builtIn.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for p in CloudProviderRegistry.builtIn {
            XCTAssertNotNil(URL(string: p.baseURL), p.baseURL)
        }
    }
}
