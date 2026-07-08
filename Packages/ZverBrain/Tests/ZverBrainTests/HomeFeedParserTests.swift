import Testing
import Foundation
@testable import ZverBrain

/// Тесты устойчивости ``HomeFeedParser``: обёртки/преамбулы срезаются,
/// галлюцинированные id отсеиваются, пустые секции дропаются, лишние схлопываются,
/// мусор → типизированная ошибка.
@Suite struct HomeFeedParserTests {
    private let valid: Set<String> = ["A1", "A2", "A3", "A4"]

    // MARK: - Успешный разбор

    @Test func parsesCleanJSON() throws {
        let text = #"""
        {"sections":[
          {"title":"Ночь","subtitle":"тьма","kind":"albums","albumIds":["A1","A2"]}
        ]}
        """#
        let feed = try HomeFeedParser.parse(text, validAlbumIds: valid)
        #expect(feed.sections.count == 1)
        #expect(feed.sections[0].title == "Ночь")
        #expect(feed.sections[0].albumIds == ["A1", "A2"])
    }

    @Test func stripsJSONCodeFence() throws {
        let text = """
        ```json
        {"sections":[{"title":"T","subtitle":null,"kind":"albums","albumIds":["A1"]}]}
        ```
        """
        let feed = try HomeFeedParser.parse(text, validAlbumIds: valid)
        #expect(feed.sections.count == 1)
        #expect(feed.sections[0].albumIds == ["A1"])
    }

    @Test func stripsProsePreamble() throws {
        let text = """
        Вот ваша лента:
        {"sections":[{"title":"T","kind":"albums","albumIds":["A2","A3"]}]}
        Приятного прослушивания!
        """
        let feed = try HomeFeedParser.parse(text, validAlbumIds: valid)
        #expect(feed.sections[0].albumIds == ["A2", "A3"])
    }

    // MARK: - Галлюцинации и пустые секции

    @Test func filtersHallucinatedAlbumIds() throws {
        let text = #"{"sections":[{"title":"T","kind":"albums","albumIds":["A1","ZZZ","A3","QQ"]}]}"#
        let feed = try HomeFeedParser.parse(text, validAlbumIds: valid)
        #expect(feed.sections[0].albumIds == ["A1", "A3"])
    }

    @Test func dropsSectionThatBecomesEmptyAfterFilter() throws {
        // Первая секция целиком из выдуманных id → выкидывается; остаётся вторая.
        let text = #"""
        {"sections":[
          {"title":"Мусор","kind":"albums","albumIds":["ZZZ","QQ"]},
          {"title":"Живая","kind":"albums","albumIds":["A1"]}
        ]}
        """#
        let feed = try HomeFeedParser.parse(text, validAlbumIds: valid)
        #expect(feed.sections.count == 1)
        #expect(feed.sections[0].title == "Живая")
    }

    @Test func keepsExternalSectionWithItems() throws {
        let text = #"""
        {"sections":[
          {"title":"Скачать","kind":"external","items":[
            {"artist":"X","album":"Y","year":2004,"reason":"зайдёт"}
          ]}
        ]}
        """#
        let feed = try HomeFeedParser.parse(text, validAlbumIds: valid)
        #expect(feed.sections.count == 1)
        #expect(feed.sections[0].kind == .external)
        #expect(feed.sections[0].items?.count == 1)
        #expect(feed.sections[0].items?.first?.artist == "X")
    }

    @Test func dropsExternalSectionWithoutItems() {
        let text = #"""
        {"sections":[{"title":"Пусто","kind":"external","items":[]}]}
        """#
        #expect(throws: BrainError.self) {
            try HomeFeedParser.parse(text, validAlbumIds: valid)
        }
    }

    // MARK: - Схлопывание

    @Test func collapsesToEightSections() throws {
        // 10 валидных albums-секций → оставляем первые 8.
        let sections = (0..<10).map {
            #"{"title":"S\#($0)","kind":"albums","albumIds":["A1"]}"#
        }.joined(separator: ",")
        let text = "{\"sections\":[\(sections)]}"
        let feed = try HomeFeedParser.parse(text, validAlbumIds: valid)
        #expect(feed.sections.count == 8)
        #expect(feed.sections.first?.title == "S0")
        #expect(feed.sections.last?.title == "S7")
    }

    // MARK: - Мусор и пустота

    @Test func throwsWhenNoJSONObject() {
        #expect(throws: BrainError.self) {
            try HomeFeedParser.parse("совсем не json, только текст", validAlbumIds: valid)
        }
    }

    @Test func throwsWhenAllSectionsFilteredOut() {
        let text = #"{"sections":[{"title":"T","kind":"albums","albumIds":["ZZZ"]}]}"#
        #expect(throws: BrainError.self) {
            try HomeFeedParser.parse(text, validAlbumIds: valid)
        }
    }

    @Test func throwsOnStructurallyBrokenJSON() {
        // Незакрытая скобка — сбалансированного объекта нет.
        #expect(throws: BrainError.self) {
            try HomeFeedParser.parse(#"{"sections":[{"title":"T""#, validAlbumIds: valid)
        }
    }

    // MARK: - Точечно: вырезание объекта

    @Test func extractIgnoresBracesInsideStrings() {
        // Скобка внутри строкового литерала не должна закрывать объект раньше времени.
        let text = #"prefix {"title":"a } b","kind":"albums"} suffix"#
        let json = HomeFeedParser.extractFirstJSONObject(text)
        #expect(json == #"{"title":"a } b","kind":"albums"}"#)
    }

    @Test func extractReturnsNilWhenNoBrace() {
        #expect(HomeFeedParser.extractFirstJSONObject("no braces here") == nil)
    }

    // MARK: - Category-эхо

    @Test func externalSectionKeepsCategoryEcho() throws {
        let text = #"""
        {"sections":[
          {"title":"Копни","kind":"external","category":"dig-deeper","items":[
            {"artist":"X","album":"Y","year":2004,"reason":"зайдёт"}
          ]}
        ]}
        """#
        let feed = try HomeFeedParser.parse(text, validAlbumIds: valid)
        #expect(feed.sections[0].category == "dig-deeper")
    }

    @Test func externalSectionWithoutCategorySurvives() throws {
        // Старый ответ модели / легаси-кэш: category нет — секция живёт без слага.
        let text = #"""
        {"sections":[
          {"title":"Скачать","kind":"external","items":[
            {"artist":"X","album":"Y","year":null,"reason":"зайдёт"}
          ]}
        ]}
        """#
        let feed = try HomeFeedParser.parse(text, validAlbumIds: valid)
        #expect(feed.sections.count == 1)
        #expect(feed.sections[0].category == nil)
    }

    @Test func categorySurvivesAlbumIdFiltering() throws {
        // sanitize пересобирает секции — слаг не должен теряться по дороге.
        let text = #"""
        {"sections":[
          {"title":"T","kind":"albums","category":"whatever","albumIds":["A1","ZZZ"]}
        ]}
        """#
        let feed = try HomeFeedParser.parse(text, validAlbumIds: valid)
        #expect(feed.sections[0].albumIds == ["A1"])
        #expect(feed.sections[0].category == "whatever")
    }
}

/// Обратная совместимость дискового кэша `homefeed.json`: старый формат без
/// `category` читается, новый (со слагом) ходит по кругу encode → decode.
@Suite struct HomeFeedCacheCompatibilityTests {
    @Test func legacyCacheWithoutCategoryDecodes() throws {
        let legacy = #"""
        {"sections":[
          {"title":"Ночь","subtitle":"тьма","tags":["ночь"],"kind":"albums","albumIds":["A1"]},
          {"title":"Скачать","subtitle":null,"kind":"external",
           "items":[{"artist":"X","album":"Y","year":2004,"reason":"зайдёт"}]}
        ]}
        """#
        let feed = try JSONDecoder().decode(HomeFeed.self, from: Data(legacy.utf8))
        #expect(feed.sections.count == 2)
        #expect(feed.sections[0].category == nil)
        #expect(feed.sections[1].category == nil)
    }

    @Test func categoryRoundTripsThroughCodable() throws {
        let feed = HomeFeed(sections: [
            HomeSection(
                title: "Копни",
                subtitle: nil,
                tags: nil,
                kind: .external,
                category: "dig-deeper",
                albumIds: nil,
                items: [ExternalItem(artist: "X", album: "Y", year: nil, reason: "r")]
            ),
        ])
        let data = try JSONEncoder().encode(feed)
        let decoded = try JSONDecoder().decode(HomeFeed.self, from: data)
        #expect(decoded == feed)
        #expect(decoded.sections[0].category == "dig-deeper")
    }
}
