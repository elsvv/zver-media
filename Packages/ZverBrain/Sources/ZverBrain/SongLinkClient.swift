import Foundation

/// Точные ссылки релиза на площадках по данным Odesli — то, что кэшируется
/// в `recommendation.links` (Codable = формат кэша, менять поля аддитивно).
///
/// Поля — только площадки, нужные шиту «Открыть в…» (дизайн, этап 2):
/// Яндекс/Bandcamp заменяют поисковые URL, Tidal/Deezer — бонусные кнопки.
/// `nil` — площадка в ответе не нашлась (фоллбэк на поиск у вызывающего).
public struct SongLinks: Codable, Equatable, Sendable {
    public let yandex: String?
    public let bandcamp: String?
    public let tidal: String?
    public let deezer: String?

    public init(yandex: String? = nil, bandcamp: String? = nil,
                tidal: String? = nil, deezer: String? = nil) {
        self.yandex = yandex
        self.bandcamp = bandcamp
        self.tidal = tidal
        self.deezer = deezer
    }

    /// Ни одной точной ссылки. Это ЧЕСТНЫЙ ответ Odesli («нигде больше
    /// нет»), а не ошибка — кэшируется, чтобы не переспрашивать.
    public var isEmpty: Bool {
        yandex == nil && bandcamp == nil && tidal == nil && deezer == nil
    }
}

/// Клиент Odesli (song.link): точные ссылки на площадки по Apple Music-URL
/// рекомендации. Без ключа, лимит 10/мин — потому ходим ТОЛЬКО по тапу
/// (открытие шита), с кэшем в памяти рекомендаций.
///
/// Пустой `linksByPlatform` — честное «не нашлось» (кэшируется), а
/// сеть/статус — ошибки (`BrainError`): их кэшировать нельзя, иначе
/// временный сбой похоронит точные ссылки навсегда (паттерн
/// ``ITunesSearchClient``). Троттлинг/кэш — забота вызывающего:
/// клиент остаётся тупым и тестируемым.
public struct SongLinkClient: Sendable {
    /// Таймаут одного запроса: шит уже показал поисковые URL, точные —
    /// апгрейд; дольше ждать незачем.
    public static let timeout: TimeInterval = 8

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// GET `api.song.link/v1-alpha.1/links?url=<AM>&userCountry=RU`.
    public func links(appleMusicURL: String,
                      userCountry: String = "RU") async throws -> SongLinks {
        var components = URLComponents(string: "https://api.song.link/v1-alpha.1/links")!
        components.queryItems = [
            .init(name: "url", value: appleMusicURL),
            .init(name: "userCountry", value: userCountry),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = Self.timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BrainError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw BrainError.badResponse("Odesli: не-HTTP ответ")
        }
        guard http.statusCode != 429 else { throw BrainError.rateLimited }
        guard (200..<300).contains(http.statusCode) else {
            throw BrainError.badResponse("Odesli: HTTP \(http.statusCode)")
        }
        guard let parsed = try? JSONDecoder().decode(LinksResponse.self, from: data) else {
            throw BrainError.badResponse("Odesli: не разобрался JSON")
        }
        return parsed.songLinks
    }

    // MARK: - Разбор

    /// `{"linksByPlatform": {"yandex": {"url": …}, …}}` — берём только нужные
    /// площадки; запись без `url` не роняет соседние (lossy-декод, паттерн
    /// ``ITunesSearchClient``).
    private struct LinksResponse: Decodable {
        struct Platform: Decodable {
            let url: String?
            init(from decoder: any Decoder) throws {
                url = try? Raw(from: decoder).url
            }
            private struct Raw: Decodable { let url: String }
        }

        let linksByPlatform: [String: Platform]

        var songLinks: SongLinks {
            SongLinks(yandex: linksByPlatform["yandex"]?.url,
                      bandcamp: linksByPlatform["bandcamp"]?.url,
                      tidal: linksByPlatform["tidal"]?.url,
                      deezer: linksByPlatform["deezer"]?.url)
        }
    }
}
