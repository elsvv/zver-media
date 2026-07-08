import Testing
import Foundation
@testable import ZverBrain

/// Тесты ротации категорий (пайплайн refresh, шаг 1): чистая функция —
/// одинаковый вход всегда даёт одинаковый заказ; изменчивое состояние
/// (offset из UserDefaults `home.categoryRotation`) передаётся параметром.
@Suite struct DiscoveryRotationTests {

    // MARK: - Обязательные и условные категории

    @Test func alwaysIncludesDeeperDiscography() {
        for hasObsessions in [false, true] {
            for webSearch in [false, true] {
                let plan = DiscoveryRotation.plan(
                    hasObsessions: hasObsessions, webSearch: webSearch, offset: 0)
                #expect(plan.categories.contains(.deeperDiscography))
            }
        }
    }

    @Test func similarToObsessionOnlyWhenObsessed() {
        #expect(DiscoveryRotation.plan(hasObsessions: true, webSearch: false, offset: 0)
            .categories.contains(.similarToObsession))
        #expect(!DiscoveryRotation.plan(hasObsessions: false, webSearch: false, offset: 0)
            .categories.contains(.similarToObsession))
    }

    @Test func freshReleasesOnlyWithWebSearch() {
        #expect(DiscoveryRotation.plan(hasObsessions: true, webSearch: true, offset: 0)
            .categories.contains(.freshReleases))
        #expect(!DiscoveryRotation.plan(hasObsessions: true, webSearch: false, offset: 0)
            .categories.contains(.freshReleases))
    }

    // MARK: - Размер и уникальность заказа

    @Test func totalIsFourOrFiveWithoutDuplicates() {
        for hasObsessions in [false, true] {
            for webSearch in [false, true] {
                for offset in 0..<7 {
                    let categories = DiscoveryRotation.plan(
                        hasObsessions: hasObsessions, webSearch: webSearch,
                        offset: offset).categories
                    #expect((4...5).contains(categories.count))
                    #expect(Set(categories).count == categories.count)
                }
            }
        }
    }

    // MARK: - Round-robin окно

    @Test func rotationWindowStartsAtOffsetAndAdvances() {
        // Полный набор: якоря + fresh → в ротации остаётся 2 места.
        let first = DiscoveryRotation.plan(hasObsessions: true, webSearch: true, offset: 0)
        #expect(first.categories == [.similarToObsession, .deeperDiscography,
                                     .missedClassics, .digDeeper, .freshReleases])
        #expect(first.nextOffset == 2)

        let second = DiscoveryRotation.plan(hasObsessions: true, webSearch: true,
                                            offset: first.nextOffset)
        #expect(second.categories == [.similarToObsession, .deeperDiscography,
                                      .sideways, .sceneDive, .freshReleases])
    }

    @Test func rotationWrapsAroundPool() {
        // Пул ротации — 5 категорий; offset 4 выходит за край и заворачивается.
        let plan = DiscoveryRotation.plan(hasObsessions: false, webSearch: false, offset: 4)
        #expect(plan.categories == [.deeperDiscography, .timeTravel,
                                    .missedClassics, .digDeeper])
        #expect(plan.nextOffset == 2)
    }

    @Test func offsetIsNormalizedModuloPool() {
        let base = DiscoveryRotation.plan(hasObsessions: false, webSearch: false, offset: 1)
        let wrapped = DiscoveryRotation.plan(hasObsessions: false, webSearch: false, offset: 6)
        #expect(base.categories == wrapped.categories)
        #expect(base.nextOffset == wrapped.nextOffset)
    }

    @Test func planIsDeterministic() {
        let a = DiscoveryRotation.plan(hasObsessions: true, webSearch: false, offset: 3)
        let b = DiscoveryRotation.plan(hasObsessions: true, webSearch: false, offset: 3)
        #expect(a.categories == b.categories)
        #expect(a.nextOffset == b.nextOffset)
    }
}
