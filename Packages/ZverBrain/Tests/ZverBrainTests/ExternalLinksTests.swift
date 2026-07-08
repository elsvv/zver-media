import Foundation
import Testing
@testable import ZverBrain

@Suite struct ExternalLinksTests {
    // MARK: - Яндекс.Музыка

    @Test func yandexMusicBuildsSearchURL() {
        let url = ExternalLinks.yandexMusic(artist: "Radiohead", album: "OK Computer")

        #expect(url.absoluteString
                == "https://music.yandex.ru/search?text=Radiohead%20OK%20Computer")
    }

    // MARK: - Bandcamp

    @Test func bandcampBuildsAlbumSearchURL() {
        let url = ExternalLinks.bandcamp(artist: "Boards of Canada",
                                         album: "Geogaddi")

        #expect(url.absoluteString
                == "https://bandcamp.com/search?q=Boards%20of%20Canada%20Geogaddi&item_type=a")
    }

    // MARK: - YouTube

    @Test func youtubeAppendsFullAlbumToQuery() {
        let url = ExternalLinks.youtube(artist: "Can", album: "Tago Mago")

        #expect(url.absoluteString
                == "https://www.youtube.com/results?search_query=Can%20Tago%20Mago%20full%20album")
    }

    // MARK: - Экранирование

    @Test func encodesQueryDelimitersInsideValues() {
        // «&» внутри значения обязан экранироваться — иначе хвост запроса
        // превратится в отдельный параметр и поиск потеряет альбом.
        let url = ExternalLinks.yandexMusic(artist: "Simon & Garfunkel",
                                            album: "Bookends")

        #expect(url.absoluteString
                == "https://music.yandex.ru/search?text=Simon%20%26%20Garfunkel%20Bookends")
    }

    @Test func keepsUnicodeArtistsSearchable() {
        // Диакритика/юникод — валидный percent-encoded запрос, а не мусор.
        let url = ExternalLinks.bandcamp(artist: "Sigur Rós", album: "Ágætis byrjun")

        #expect(url.host() == "bandcamp.com")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems?.first { $0.name == "q" }?.value
        #expect(query == "Sigur Rós Ágætis byrjun")
        #expect(components?.queryItems?.contains(.init(name: "item_type", value: "a")) == true)
    }
}
