import Foundation
import Testing
@testable import SaidDoneCore

struct CloudProviderRegistryTests {
    @Test func requiredProviderPresets() {
        let ids = Set(CloudProviderRegistry.builtIn.map(\.id))
        for id in ["openai", "deepseek", "moonshot", "zhipu", "siliconflow"] {
            #expect(ids.contains(id), "missing provider: \(id)")
        }
    }

    @Test func builtInIDsUniqueAndURLsValid() {
        let ids = CloudProviderRegistry.builtIn.map(\.id)
        #expect((Set(ids).count) == ids.count)
        for p in CloudProviderRegistry.builtIn {
            #expect(URL(string: p.baseURL) != nil, "\(p.baseURL)")
        }
    }
}
