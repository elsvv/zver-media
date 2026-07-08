import Testing
import Foundation
@testable import ZverBrain

/// Мок-сессия с перехватом через ``MockURLProtocol`` (локальная копия хелпера
/// из BrainNetworkTests.swift — он private там; file-scope, конфликта нет).
private func mockSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: cfg)
}

// Сетевые тесты Deezer живут ПОД зонтиком BrainNetworkTests: MockURLProtocol
// держит стабы в статике, все его потребители сериализуются одним
// `.serialized`-родителем (см. шапку BrainNetworkTests.swift).
extension BrainNetworkTests {
    @Suite struct DeezerRelated {
        private static let searchBody =
            #"{"data":[{"id":27,"name":"Daft Punk","type":"artist"}],"total":1}"#
        private static let relatedBody = """
        {"data":[
          {"id":1,"name":"Justice"},
          {"id":2,"name":"Air"},
          {"id":3,"name":"Cassius"}
        ],"total":3}
        """

        // MARK: - Запросы

        @Test func buildsSearchRequest() async throws {
            // Пустая выдача поиска: второй запрос не уходит, последний URL —
            // это и есть поисковый.
            MockURLProtocol.setStub(.init(body: Data(#"{"data":[]}"#.utf8)))

            let names = await DeezerRelatedFetcher.relatedArtists(
                to: "Daft Punk", session: mockSession())

            #expect(names.isEmpty)
            let url = try #require(MockURLProtocol.lastRequestURL())
            #expect(url.host() == "api.deezer.com")
            #expect(url.path() == "/search/artist")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            #expect(items.first { $0.name == "q" }?.value == "Daft Punk")
            #expect(items.first { $0.name == "limit" }?.value == "1")
        }

        @Test func resolvesIdThenFetchesRelatedNames() async throws {
            MockURLProtocol.setRoutes([
                ("/search/artist", .init(body: Data(Self.searchBody.utf8))),
                ("/artist/27/related", .init(body: Data(Self.relatedBody.utf8))),
            ])

            let names = await DeezerRelatedFetcher.relatedArtists(
                to: "Daft Punk", session: mockSession())

            #expect(names == ["Justice", "Air", "Cassius"])
            // Второй (и последний) запрос — related по найденному id.
            #expect(MockURLProtocol.lastRequestURL()?.path() == "/artist/27/related")
        }

        @Test func limitTrimsRelatedNames() async {
            MockURLProtocol.setRoutes([
                ("/search/artist", .init(body: Data(Self.searchBody.utf8))),
                ("/artist/27/related", .init(body: Data(Self.relatedBody.utf8))),
            ])

            let names = await DeezerRelatedFetcher.relatedArtists(
                to: "Daft Punk", limit: 2, session: mockSession())

            #expect(names == ["Justice", "Air"])
        }

        @Test func skipsEntriesWithoutName() async {
            // Запись без имени не роняет разбор соседних (lossy-декод).
            let body = #"{"data":[{"id":1},{"id":2,"name":"Air"},"мусор"]}"#
            MockURLProtocol.setRoutes([
                ("/search/artist", .init(body: Data(Self.searchBody.utf8))),
                ("/related", .init(body: Data(body.utf8))),
            ])

            let names = await DeezerRelatedFetcher.relatedArtists(
                to: "Daft Punk", session: mockSession())

            #expect(names == ["Air"])
        }

        // MARK: - Ошибки: любые → пустой результат, не throw

        @Test func httpErrorReturnsEmpty() async {
            MockURLProtocol.setStub(.init(statusCode: 503, body: Data()))

            let names = await DeezerRelatedFetcher.relatedArtists(
                to: "Daft Punk", session: mockSession())

            #expect(names.isEmpty)
        }

        @Test func transportErrorReturnsEmpty() async {
            MockURLProtocol.setStub(.init(error: URLError(.notConnectedToInternet)))

            let names = await DeezerRelatedFetcher.relatedArtists(
                to: "Daft Punk", session: mockSession())

            #expect(names.isEmpty)
        }

        @Test func malformedJSONReturnsEmpty() async {
            // Deezer отдаёт ошибки телом {"error":…} со статусом 200 —
            // отсутствие ключа data тоже тихое «пусто».
            MockURLProtocol.setStub(.init(body: Data(#"{"error":{"code":4}}"#.utf8)))

            let names = await DeezerRelatedFetcher.relatedArtists(
                to: "Daft Punk", session: mockSession())

            #expect(names.isEmpty)
        }

        @Test func relatedFailureReturnsEmpty() async {
            MockURLProtocol.setRoutes([
                ("/search/artist", .init(body: Data(Self.searchBody.utf8))),
                ("/artist/27/related", .init(statusCode: 500, body: Data())),
            ])

            let names = await DeezerRelatedFetcher.relatedArtists(
                to: "Daft Punk", session: mockSession())

            #expect(names.isEmpty)
        }

        // MARK: - Батч для снапшота

        @Test func batchCollectsPerArtistAndDropsFailures() async {
            MockURLProtocol.setRoutes([
                ("q=Alpha", .init(body: Data(#"{"data":[{"id":1,"name":"Alpha"}]}"#.utf8))),
                ("q=Beta", .init(body: Data(#"{"data":[{"id":2,"name":"Beta"}]}"#.utf8))),
                ("/artist/1/related",
                 .init(body: Data(#"{"data":[{"id":10,"name":"X"},{"id":11,"name":"Y"}]}"#.utf8))),
                ("/artist/2/related", .init(statusCode: 500, body: Data())),
            ])

            let hints = await DeezerRelatedFetcher.similarArtistsHints(
                for: ["Alpha", "Beta"], session: mockSession())

            // Beta упал → выпал из словаря целиком, не пустым значением.
            #expect(hints == ["Alpha": ["X", "Y"]])
        }
    }
}

/// Кредит «по данным Deezer» — чистая логика, сети не касается.
@Suite struct DeezerCreditTests {
    private let hints = ["Boards of Canada": ["Autechre", "Plaid"],
                         "Portishead": ["Massive Attack"]]

    @Test func appendsCreditWhenSectionArtistIsHinted() {
        let subtitle = DeezerRelatedFetcher.credited(
            subtitle: "Соседние вселенные",
            artists: ["Autechre", "Кто-то ещё"],
            hints: hints)
        #expect(subtitle == "Соседние вселенные · по данным Deezer")
    }

    @Test func matchIsCaseInsensitiveAndTrimmed() {
        let subtitle = DeezerRelatedFetcher.credited(
            subtitle: "Подборка",
            artists: ["  massive attack "],
            hints: hints)
        #expect(subtitle == "Подборка · по данным Deezer")
    }

    @Test func noHintedArtistsLeaveSubtitleUntouched() {
        let subtitle = DeezerRelatedFetcher.credited(
            subtitle: "Подборка", artists: ["Кто-то ещё"], hints: hints)
        #expect(subtitle == "Подборка")
    }

    @Test func emptyHintsLeaveSubtitleUntouched() {
        let subtitle = DeezerRelatedFetcher.credited(
            subtitle: "Подборка", artists: ["Autechre"], hints: [:])
        #expect(subtitle == "Подборка")
    }

    @Test func nilSubtitleBecomesStandaloneCredit() {
        let subtitle = DeezerRelatedFetcher.credited(
            subtitle: nil, artists: ["Plaid"], hints: hints)
        #expect(subtitle == "По данным Deezer")
    }

    @Test func doesNotDuplicateExistingCredit() {
        let subtitle = DeezerRelatedFetcher.credited(
            subtitle: "Уже по данным Deezer", artists: ["Plaid"], hints: hints)
        #expect(subtitle == "Уже по данным Deezer")
    }
}
