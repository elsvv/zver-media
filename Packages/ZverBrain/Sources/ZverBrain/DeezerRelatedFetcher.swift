import Foundation

/// Скелет «похожих артистов» от Deezer — необязательная подсказка промпту
/// (снапшот-поле `similarArtistsHints` → блок «РОДСТВЕННЫЕ АРТИСТЫ»).
///
/// Паттерн ``ModelCatalogFetcher``: без ключа, короткий таймаут, ЛЮБАЯ ошибка
/// (сеть/статус/парсинг/не нашёлся артист) — тихий откат к пустому результату.
/// Скелет — вспомогательный: лента обязана строиться и без него (дизайн:
/// «доступность api.deezer.com из RU-сети не гарантирована — деградирует
/// молча»). LLM остаётся куратором; в UI Deezer виден только как
/// подпись-кредит в subtitle секций (``credited(subtitle:artists:hints:)``).
///
/// Два шага на артиста: `search/artist?q=<имя>` → id первого совпадения →
/// `artist/{id}/related` → имена родственных артистов.
public enum DeezerRelatedFetcher {
    /// Короткий таймаут каждого запроса: скелет не должен задерживать ручное
    /// обновление ленты дольше, чем пользователь готов ждать.
    static let timeout: TimeInterval = 8
    /// Родственных на одного топ-артиста — до 10 (бюджет промпта).
    public static let defaultRelatedLimit = 10

    /// Родственные артисты для одного имени. Пустой список — «не нашлось»
    /// ИЛИ любая ошибка: различать вызывающему незачем, скелет опционален.
    public static func relatedArtists(
        to artist: String,
        limit: Int = defaultRelatedLimit,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) async -> [String] {
        guard let id = await searchArtistId(artist, session: session),
              let url = URL(string: "https://api.deezer.com/artist/\(id)/related"),
              let list = await fetchList(url, session: session)
        else { return [] }
        let names = list.data
            .compactMap(\.entry?.name)
            .filter { !$0.isEmpty }
        return Array(names.prefix(limit))
    }

    /// Батч для снапшота: топ-артисты слушателя → словарь подсказок.
    /// Артисты опрашиваются параллельно; неудачники (пустой результат)
    /// в словарь не попадают — промпт-блок не тратит токены на пустые строки.
    public static func similarArtistsHints(
        for artists: [String],
        perArtistLimit: Int = defaultRelatedLimit,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) async -> [String: [String]] {
        await withTaskGroup(of: (String, [String]).self) { group in
            for artist in artists {
                group.addTask {
                    (artist, await relatedArtists(to: artist, limit: perArtistLimit,
                                                  session: session))
                }
            }
            var hints: [String: [String]] = [:]
            for await (artist, related) in group where !related.isEmpty {
                hints[artist] = related
            }
            return hints
        }
    }

    // MARK: - Кредит источника (чистая логика)

    /// Приписка к subtitle секции, где скелет использовался.
    static let creditNote = "по данным Deezer"

    /// Subtitle секции с кредитом Deezer, если секция скелетом пользовалась:
    /// хотя бы один из её артистов встречается среди родственных подсказок
    /// (без учёта регистра и краевых пробелов). Иначе — subtitle как был.
    /// Детерминированная чистая функция — вызывающему безопасно в пайплайне.
    public static func credited(
        subtitle: String?,
        artists: [String],
        hints: [String: [String]]
    ) -> String? {
        guard !hints.isEmpty else { return subtitle }
        let hinted = Set(hints.values.joined().map(normalize))
        guard artists.contains(where: { hinted.contains(normalize($0)) }) else {
            return subtitle
        }
        guard let subtitle, !subtitle.isEmpty else { return "По данным Deezer" }
        // Модель могла сама упомянуть источник — не дублируем кредит.
        guard !subtitle.localizedCaseInsensitiveContains("deezer") else { return subtitle }
        return subtitle + " · " + creditNote
    }

    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Сеть

    /// Id первого совпадения `search/artist?q=<имя>&limit=1` или nil.
    private static func searchArtistId(_ artist: String,
                                       session: URLSession) async -> Int64? {
        var components = URLComponents(string: "https://api.deezer.com/search/artist")!
        components.queryItems = [
            .init(name: "q", value: artist),
            .init(name: "limit", value: "1"),
        ]
        guard let url = components.url,
              let list = await fetchList(url, session: session)
        else { return nil }
        return list.data.compactMap(\.entry?.id).first
    }

    /// GET списка Deezer; nil на любой ошибке. Ошибки Deezer приходят и телом
    /// `{"error":…}` со статусом 200 — тогда ключа `data` нет и декод падает
    /// в тот же тихий nil.
    private static func fetchList(_ url: URL,
                                  session: URLSession) async -> ListResponse? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let list = try? JSONDecoder().decode(ListResponse.self, from: data)
        else { return nil }
        return list
    }

    /// `{"data": [{"id": …, "name": …}, …]}` — общая форма ответов
    /// `search/artist` (нужен id) и `artist/{id}/related` (нужно name).
    private struct ListResponse: Decodable {
        struct Entry: Decodable {
            let id: Int64?
            let name: String?
        }

        /// Кривая запись не роняет массив целиком (паттерн LossyEntry
        /// из ``ModelCatalogFetcher``).
        struct LossyEntry: Decodable {
            let entry: Entry?
            init(from decoder: any Decoder) throws {
                entry = try? Entry(from: decoder)
            }
        }

        let data: [LossyEntry]
    }
}
