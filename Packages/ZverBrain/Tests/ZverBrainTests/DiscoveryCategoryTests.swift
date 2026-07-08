import Testing
import Foundation
@testable import ZverBrain

/// Тесты пула категорий discovery: слаги совпадают с дизайн-доком, у каждой
/// категории непустые title и инструкция для промпта, Codable ходит по слагу.
@Suite struct DiscoveryCategoryTests {
    @Test func hasExactlyEightCategories() {
        #expect(DiscoveryCategory.allCases.count == 8)
    }

    @Test func rawValuesMatchDesignSlugs() {
        #expect(DiscoveryCategory.allCases.map(\.rawValue) == [
            "similar-to-obsession",
            "deeper-discography",
            "missed-classics",
            "dig-deeper",
            "fresh-releases",
            "sideways",
            "scene-dive",
            "time-travel",
        ])
    }

    @Test func titlesAreNonEmptyAndUnique() {
        let titles = DiscoveryCategory.allCases.map(\.title)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == titles.count)
    }

    @Test func instructionsAreNonEmptyAndUnique() {
        let instructions = DiscoveryCategory.allCases.map(\.promptInstruction)
        #expect(instructions.allSatisfy { !$0.isEmpty })
        #expect(Set(instructions).count == instructions.count)
    }

    @Test func codableRoundTripsBySlug() throws {
        let encoded = try JSONEncoder().encode([DiscoveryCategory.digDeeper])
        #expect(String(data: encoded, encoding: .utf8) == #"["dig-deeper"]"#)
        let decoded = try JSONDecoder().decode([DiscoveryCategory].self, from: encoded)
        #expect(decoded == [.digDeeper])
    }

    @Test func freshReleasesInstructionDemandsWebSearch() {
        // Категория живёт только при webSearch — инструкция должна гнать в веб.
        #expect(DiscoveryCategory.freshReleases.promptInstruction.contains("веб"))
    }

    @Test func digDeeperInstructionIsAntiCanon() {
        #expect(DiscoveryCategory.digDeeper.promptInstruction.contains("АНТИ-КАНОН"))
    }
}
