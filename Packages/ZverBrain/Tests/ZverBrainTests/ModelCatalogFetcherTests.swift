import Testing
import Foundation
@testable import ZverBrain

// Тесты сетевого поведения ModelCatalogFetcher живут ВНУТРИ
// BrainNetworkTests (вложенный @Suite ModelCatalog) — они делят мок
// MockURLProtocol с адаптерами и должны сериализоваться с ними под одним
// зонтиком (см. комментарий в шапке BrainNetworkTests.swift). Здесь —
// только чистая статика, не трогающая сеть.

@Suite struct BrainProviderPresetTests {
    @Test func allPresetsHaveHTTPBaseURL() {
        for preset in BrainProviderPreset.all {
            #expect(preset.baseURL.scheme?.hasPrefix("http") == true)
            #expect(!preset.name.isEmpty)
        }
    }

    @Test func presetNamesAreUnique() {
        let names = Set(BrainProviderPreset.all.map(\.name))
        #expect(names.count == BrainProviderPreset.all.count)
    }
}
