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

// Сетевые тесты Odesli живут ПОД зонтиком BrainNetworkTests: MockURLProtocol
// держит стаб в статике, все его потребители сериализуются одним
// `.serialized`-родителем (см. шапку BrainNetworkTests.swift).
extension BrainNetworkTests {
    @Suite struct SongLink {
        private func makeClient() -> SongLinkClient {
            SongLinkClient(session: mockSession())
        }

        private static let amURL = "https://music.apple.com/us/album/geogaddi/280219224"

        private static let okBody = """
        {"entityUniqueId":"ITUNES_ALBUM::280219224",
         "linksByPlatform":{
           "yandex":{"url":"https://music.yandex.ru/album/12345"},
           "bandcamp":{"url":"https://boardsofcanada.bandcamp.com/album/geogaddi"},
           "tidal":{"url":"https://listen.tidal.com/album/676532"},
           "deezer":{"url":"https://www.deezer.com/album/300186"},
           "spotify":{"url":"https://open.spotify.com/album/x"}
         }}
        """

        // MARK: - Запрос

        @Test func buildsLinksRequestWithURLAndCountry() async throws {
            MockURLProtocol.setStub(.init(body: Data(Self.okBody.utf8)))

            _ = try await makeClient().links(appleMusicURL: Self.amURL)

            let url = try #require(MockURLProtocol.lastRequestURL())
            #expect(url.host() == "api.song.link")
            #expect(url.path() == "/v1-alpha.1/links")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            func value(_ name: String) -> String? {
                items.first { $0.name == name }?.value
            }
            #expect(value("url") == Self.amURL)
            #expect(value("userCountry") == "RU")
        }

        // MARK: - Разбор

        @Test func parsesKnownPlatformsIgnoringOthers() async throws {
            MockURLProtocol.setStub(.init(body: Data(Self.okBody.utf8)))

            let links = try await makeClient().links(appleMusicURL: Self.amURL)

            #expect(links.yandex == "https://music.yandex.ru/album/12345")
            #expect(links.bandcamp
                    == "https://boardsofcanada.bandcamp.com/album/geogaddi")
            #expect(links.tidal == "https://listen.tidal.com/album/676532")
            #expect(links.deezer == "https://www.deezer.com/album/300186")
            #expect(!links.isEmpty)
        }

        @Test func missingPlatformsDecodeAsNil() async throws {
            let body = #"{"linksByPlatform":{"yandex":{"url":"https://music.yandex.ru/album/1"}}}"#
            MockURLProtocol.setStub(.init(body: Data(body.utf8)))

            let links = try await makeClient().links(appleMusicURL: Self.amURL)

            #expect(links.yandex == "https://music.yandex.ru/album/1")
            #expect(links.bandcamp == nil)
            #expect(links.tidal == nil)
            #expect(links.deezer == nil)
        }

        @Test func emptyPlatformsAreValidEmptyAnswer() async throws {
            // Пустой linksByPlatform — честное «нигде больше нет», НЕ ошибка:
            // вызывающий вправе закэшировать и не ходить в сеть повторно.
            MockURLProtocol.setStub(.init(body: Data(#"{"linksByPlatform":{}}"#.utf8)))

            let links = try await makeClient().links(appleMusicURL: Self.amURL)

            #expect(links.isEmpty)
        }

        @Test func platformEntryWithoutUrlIsSkipped() async throws {
            // Кривая запись платформы (нет url) не роняет разбор соседних.
            let body = """
            {"linksByPlatform":{
               "yandex":{"entityUniqueId":"x"},
               "tidal":{"url":"https://listen.tidal.com/album/7"}
            }}
            """
            MockURLProtocol.setStub(.init(body: Data(body.utf8)))

            let links = try await makeClient().links(appleMusicURL: Self.amURL)

            #expect(links.yandex == nil)
            #expect(links.tidal == "https://listen.tidal.com/album/7")
        }

        // MARK: - Ошибки: сеть/статус — throw (кэшировать нельзя)

        @Test func throwsOnHTTPErrorStatus() async {
            MockURLProtocol.setStub(.init(statusCode: 503, body: Data()))

            await #expect(throws: BrainError.self) {
                _ = try await makeClient().links(appleMusicURL: Self.amURL)
            }
        }

        @Test func throwsRateLimitedOn429() async {
            // Лимит Odesli 10/мин без ключа — 429 должен быть различим.
            MockURLProtocol.setStub(.init(statusCode: 429, body: Data()))

            await #expect(throws: BrainError.rateLimited) {
                _ = try await makeClient().links(appleMusicURL: Self.amURL)
            }
        }

        @Test func throwsOnTransportError() async {
            MockURLProtocol.setStub(.init(error: URLError(.timedOut)))

            await #expect(throws: BrainError.self) {
                _ = try await makeClient().links(appleMusicURL: Self.amURL)
            }
        }

        @Test func throwsOnUndecodableBody() async {
            MockURLProtocol.setStub(.init(body: Data("не json".utf8)))

            await #expect(throws: BrainError.self) {
                _ = try await makeClient().links(appleMusicURL: Self.amURL)
            }
        }
    }
}

/// `SongLinks` — формат кэша `recommendation.links`: round-trip Codable
/// обязан быть стабильным (записали по тапу — прочитали при повторном
/// открытии шита без сети).
@Suite struct SongLinksCacheFormatTests {
    @Test func codableRoundTripPreservesLinks() throws {
        let links = SongLinks(yandex: "https://music.yandex.ru/album/1",
                              bandcamp: nil,
                              tidal: "https://listen.tidal.com/album/7",
                              deezer: nil)

        let data = try JSONEncoder().encode(links)
        let decoded = try JSONDecoder().decode(SongLinks.self, from: data)

        #expect(decoded == links)
    }

    @Test func isEmptyOnlyWhenAllPlatformsMissing() {
        #expect(SongLinks(yandex: nil, bandcamp: nil, tidal: nil, deezer: nil).isEmpty)
        #expect(!SongLinks(yandex: nil, bandcamp: "b", tidal: nil, deezer: nil).isEmpty)
    }
}
