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

// Сетевые тесты iTunes Search живут ПОД зонтиком BrainNetworkTests:
// MockURLProtocol держит стаб в статике, все его потребители должны
// сериализоваться одним `.serialized`-родителем (см. шапку BrainNetworkTests).
extension BrainNetworkTests {
    @Suite struct ITunesSearch {
        private func makeClient() -> ITunesSearchClient {
            ITunesSearchClient(session: mockSession())
        }

        private static let okBody = """
        {"resultCount":2,"results":[
          {"collectionId":280219224,
           "artistName":"Boards of Canada",
           "collectionName":"Geogaddi",
           "collectionViewUrl":"https://music.apple.com/us/album/geogaddi/280219224",
           "artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/a/100x100bb.jpg",
           "primaryGenreName":"Electronic",
           "releaseDate":"2002-02-18T08:00:00Z"},
          {"collectionId":1443539591,
           "artistName":"Boards of Canada",
           "collectionName":"Music Has the Right to Children"}
        ]}
        """

        // MARK: - Запрос

        @Test func buildsSearchRequestForAlbumEntity() async throws {
            MockURLProtocol.setStub(.init(body: Data(Self.okBody.utf8)))

            _ = try await makeClient().search(artist: "Boards of Canada",
                                              album: "Geogaddi")

            let url = try #require(MockURLProtocol.lastRequestURL())
            #expect(url.host() == "itunes.apple.com")
            #expect(url.path() == "/search")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            func value(_ name: String) -> String? {
                items.first { $0.name == name }?.value
            }
            #expect(value("media") == "music")
            #expect(value("entity") == "album")
            #expect(value("limit") == "5")
            #expect(value("term") == "Boards of Canada Geogaddi")
        }

        // MARK: - Разбор

        @Test func parsesResultsWithYearAndBigArtwork() async throws {
            MockURLProtocol.setStub(.init(body: Data(Self.okBody.utf8)))

            let results = try await makeClient().search(artist: "Boards of Canada",
                                                        album: "Geogaddi")

            #expect(results.count == 2)
            let first = try #require(results.first)
            #expect(first.collectionId == 280_219_224)
            #expect(first.artistName == "Boards of Canada")
            #expect(first.collectionName == "Geogaddi")
            #expect(first.collectionViewUrl
                    == "https://music.apple.com/us/album/geogaddi/280219224")
            #expect(first.primaryGenreName == "Electronic")
            #expect(first.year == 2002)
            // 100×100 → 600×600 — тот же CDN-трюк, что у обложек.
            #expect(first.artworkUrl600
                    == "https://is1-ssl.mzstatic.com/image/thumb/a/600x600bb.jpg")
            // Поля второй записи опциональны: нет даты/обложки — nil, не падение.
            #expect(results[1].year == nil)
            #expect(results[1].artworkUrl600 == nil)
        }

        @Test func emptyResultsAreNotFoundNotError() async throws {
            MockURLProtocol.setStub(.init(body: Data(#"{"resultCount":0,"results":[]}"#.utf8)))

            let results = try await makeClient().search(artist: "Никто", album: "Ничего")

            #expect(results.isEmpty)
        }

        @Test func skipsResultsWithoutCollectionId() async throws {
            // Запись без id не должна ронять разбор соседних (lossy-декод).
            let body = """
            {"results":[
              {"artistName":"X","collectionName":"NoId"},
              {"collectionId":7,"artistName":"Y","collectionName":"Ok"}
            ]}
            """
            MockURLProtocol.setStub(.init(body: Data(body.utf8)))

            let results = try await makeClient().search(artist: "Y", album: "Ok")

            #expect(results.map(\.collectionId) == [7])
        }

        // MARK: - Ошибки: сеть/статус — throw, НЕ «не нашлось»

        @Test func throwsOnHTTPErrorStatus() async {
            MockURLProtocol.setStub(.init(statusCode: 503, body: Data()))

            await #expect(throws: BrainError.self) {
                _ = try await makeClient().search(artist: "A", album: "B")
            }
        }

        @Test func throwsOnTransportError() async {
            MockURLProtocol.setStub(.init(error: URLError(.notConnectedToInternet)))

            await #expect(throws: BrainError.self) {
                _ = try await makeClient().search(artist: "A", album: "B")
            }
        }
    }
}

/// Политика троттлинга — чистая функция (дизайн: «троттлинг не тестируем
/// таймерами — выносим политику в чистую функцию»). 3.5с между сетевыми
/// запросами; попадания в кэш её не трогают (это забота вызывающего).
@Suite struct ITunesThrottleTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test func firstRequestGoesImmediately() {
        let (delay, next) = ITunesThrottle.schedule(now: now, nextAllowedAt: nil,
                                                    minInterval: 3.5)
        #expect(delay == 0)
        #expect(next == now.addingTimeInterval(3.5))
    }

    @Test func rapidSecondRequestWaitsRemainder() {
        let allowedAt = now.addingTimeInterval(2)
        let (delay, next) = ITunesThrottle.schedule(now: now, nextAllowedAt: allowedAt,
                                                    minInterval: 3.5)
        #expect(delay == 2)
        #expect(next == allowedAt.addingTimeInterval(3.5))
    }

    @Test func requestAfterQuietPeriodGoesImmediately() {
        let (delay, next) = ITunesThrottle.schedule(
            now: now, nextAllowedAt: now.addingTimeInterval(-100), minInterval: 3.5)
        #expect(delay == 0)
        #expect(next == now.addingTimeInterval(3.5))
    }
}
