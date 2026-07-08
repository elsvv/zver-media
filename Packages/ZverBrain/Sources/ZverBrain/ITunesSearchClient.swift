import Foundation

/// Один альбом из ответа iTunes Search — сырьё валидации внешних рекомендаций
/// (пайплайн refresh, шаг 4). Из того же запроса берём и ссылку Apple Music
/// (`collectionViewUrl`), и обложку, и жанр с годом — второй поход не нужен.
public struct ITunesAlbum: Equatable, Sendable {
    /// iTunes collectionId — стабильный идентификатор релиза у Apple.
    public let collectionId: Int64
    public let artistName: String
    public let collectionName: String
    /// Готовая ссылка на релиз в Apple Music.
    public let collectionViewUrl: String?
    public let artworkUrl100: String?
    public let primaryGenreName: String?
    /// ISO-дата релиза как строка (`2002-02-18T08:00:00Z`).
    public let releaseDate: String?

    public init(collectionId: Int64, artistName: String, collectionName: String,
                collectionViewUrl: String? = nil, artworkUrl100: String? = nil,
                primaryGenreName: String? = nil, releaseDate: String? = nil) {
        self.collectionId = collectionId
        self.artistName = artistName
        self.collectionName = collectionName
        self.collectionViewUrl = collectionViewUrl
        self.artworkUrl100 = artworkUrl100
        self.primaryGenreName = primaryGenreName
        self.releaseDate = releaseDate
    }

    /// Год релиза — первые четыре цифры ISO-даты (полный парсинг даты не нужен).
    public var year: Int? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return Int(releaseDate.prefix(4))
    }

    /// Обложка 600×600: iTunes CDN отдаёт любой размер подменой суффикса
    /// в имени файла (стандартный трюк, тот же, что в загрузчике обложек).
    public var artworkUrl600: String? {
        artworkUrl100?.replacingOccurrences(of: "100x100", with: "600x600")
    }
}

/// Клиент iTunes Search API (бесплатный, без ключа): поиск релиза по паре
/// «артист + альбом». Пустой список — честное «не нашлось» (кэшируется
/// негативно), а сеть/статус — ошибки (`BrainError`): их кэшировать нельзя,
/// иначе временный сбой сети похоронит кандидата на 30 дней.
///
/// Троттлинг здесь НЕ живёт — это политика вызывающего (`ITunesThrottle` +
/// актор-кэш в аппе): клиент должен оставаться тупым и тестируемым.
public struct ITunesSearchClient: Sendable {
    /// Кандидатов в ответе больше одного: fuzzy-матч выбирает подходящего,
    /// а не слепо первого (переиздания и трибьюты любят вылезать вперёд).
    public static let defaultLimit = 5

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func search(artist: String, album: String,
                       limit: Int = ITunesSearchClient.defaultLimit) async throws -> [ITunesAlbum] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "media", value: "music"),
            .init(name: "entity", value: "album"),
            .init(name: "limit", value: String(limit)),
            .init(name: "term", value: "\(artist) \(album)"),
        ]
        let url = components.url!

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw BrainError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw BrainError.badResponse("iTunes Search: не-HTTP ответ")
        }
        guard http.statusCode != 429 else { throw BrainError.rateLimited }
        guard (200..<300).contains(http.statusCode) else {
            throw BrainError.badResponse("iTunes Search: HTTP \(http.statusCode)")
        }
        guard let list = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            throw BrainError.badResponse("iTunes Search: не разобрался JSON")
        }
        return list.results.compactMap(\.album)
    }

    // MARK: - Разбор

    private struct SearchResponse: Decodable {
        /// Одна запись, которая МОЖЕТ не разобраться (нет collectionId и т.п.) —
        /// не роняет массив целиком (паттерн LossyEntry из ModelCatalogFetcher).
        struct LossyItem: Decodable {
            let album: ITunesAlbum?
            init(from decoder: any Decoder) throws {
                album = try? Raw(from: decoder).album
            }
        }

        struct Raw: Decodable {
            let collectionId: Int64
            let artistName: String
            let collectionName: String
            let collectionViewUrl: String?
            let artworkUrl100: String?
            let primaryGenreName: String?
            let releaseDate: String?

            var album: ITunesAlbum {
                ITunesAlbum(collectionId: collectionId, artistName: artistName,
                            collectionName: collectionName,
                            collectionViewUrl: collectionViewUrl,
                            artworkUrl100: artworkUrl100,
                            primaryGenreName: primaryGenreName,
                            releaseDate: releaseDate)
            }
        }

        let results: [LossyItem]
    }
}

/// Политика троттлинга iTunes Search: 3.5с между СЕТЕВЫМИ запросами (попадания
/// в кэш её не трогают). Чистая функция — тесты без таймеров: актор-вызывающий
/// хранит `nextAllowedAt`, спит `delay` и записывает новый `nextAllowedAt`.
public enum ITunesThrottle {
    public static func schedule(
        now: Date,
        nextAllowedAt: Date?,
        minInterval: TimeInterval
    ) -> (delay: TimeInterval, nextAllowedAt: Date) {
        let start = max(now, nextAllowedAt ?? now)
        return (delay: start.timeIntervalSince(now),
                nextAllowedAt: start.addingTimeInterval(minInterval))
    }
}
