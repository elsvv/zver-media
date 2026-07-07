import Foundation
import ZverBrain
import ZverCore

/// Секция ленты «Главной» после резолва: короткие id промпта (`A17`)
/// превращены в переносимые ключи альбомов (относительные пути) — кэш ленты
/// переживает перегенерацию снапшота, где нумерация другая.
struct ResolvedHomeSection: Codable, Equatable, Identifiable, Sendable {
    var id: String { title }
    let title: String
    let subtitle: String?
    let tags: [String]?
    /// Ключи альбомов библиотеки (kind=albums); пуст у внешних секций.
    let albumKeys: [String]
    /// Внешние рекомендации «что скачать» (kind=external); пуст у альбомных.
    let external: [ExternalSuggestion]
}

/// Внешняя рекомендация: альбом вне библиотеки + почему он зайдёт.
struct ExternalSuggestion: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(artist) — \(album)" }
    let artist: String
    let album: String
    let year: Int?
    let reason: String
}

/// Кэш ленты на диске: сама лента + когда сгенерирована.
struct CachedHomeFeed: Codable, Equatable, Sendable {
    let sections: [ResolvedHomeSection]
    let updatedAt: Date
}

/// Сервис AI-ленты «Главной»: собирает `LibrarySnapshot`, зовёт LLM через
/// `ZverBrain`, резолвит id → ключи альбомов, кэширует в Application Support.
/// Обновление ТОЛЬКО ручное (три точки → конфирм) — никаких фоновых трат
/// токенов API.
@MainActor
final class HomeFeedService: ObservableObject {
    enum FeedState: Equatable {
        case idle
        case loading
        case failed(String)
    }

    @Published private(set) var feed: CachedHomeFeed?
    @Published private(set) var state: FeedState = .idle

    private let library: LibraryStore
    private let account: BrainAccount
    private let cacheURL: URL

    init(library: LibraryStore, account: BrainAccount,
         cacheURL: URL = URL.applicationSupportDirectory
             .appendingPathComponent("homefeed.json")) {
        self.library = library
        self.account = account
        self.cacheURL = cacheURL
        loadCache()
    }

    /// Сколько альбомов влезает в промпт: больше — режем с приоритетом
    /// избранного/прослушиваемого/недавнего (см. snapshot()).
    private static let promptAlbumLimit = 300

    // MARK: - Генерация

    /// Перегенерация ленты по кнопке. Ошибки — в `state` (UI показывает
    /// строку), успех перезаписывает кэш. Повторный вызов при `loading` — no-op.
    func refresh() async {
        guard state != .loading else { return }
        guard let config = account.config, account.isConfigured else {
            state = .failed("Укажи ключ, base URL и модель в Настройках → Интеллект.")
            return
        }
        state = .loading

        // Снапшот собирается на MainActor (читает published-библиотеку),
        // сеть и парсинг — вне.
        let (snapshot, keysById) = await snapshot()
        guard !snapshot.albums.isEmpty else {
            state = .failed("Библиотека пуста — ленте не из чего собираться.")
            return
        }
        let client = OpenAICompatibleClient(config: config,
                                            tokenProvider: account.tokenProvider)
        do {
            let (system, user) = HomeFeedPrompt.build(snapshot: snapshot)
            let text = try await client.complete(system: system, user: user)
            let parsed = try HomeFeedParser.parse(text, validAlbumIds: Set(keysById.keys))
            let resolved = Self.resolve(parsed, keysById: keysById)
            guard !resolved.isEmpty else {
                state = .failed("Модель вернула пустую ленту — попробуй ещё раз.")
                return
            }
            let cached = CachedHomeFeed(sections: resolved, updatedAt: Date())
            feed = cached
            saveCache(cached)
            state = .idle
        } catch let error as BrainError {
            state = .failed(Self.describe(error))
        } catch {
            state = .failed("Не получилось: \(error.localizedDescription)")
        }
    }

    /// Снапшот библиотеки для промпта + маппинг короткий id → ключ альбома.
    /// Приоритет при обрезке до лимита: избранное → прослушиваемое (90 дней) →
    /// недавно добавленное → остальное по порядку библиотеки.
    private func snapshot() async -> (LibrarySnapshot, [String: String]) {
        let albums = library.albums.filter { $0.id != AlbumGroup.noAlbumTitle }
        let stats = await library.listeningStats(
            since: Date().addingTimeInterval(-90 * 24 * 3600))
        let recentlyPlayedKeys = await library.recentlyPlayedAlbums(limit: 15)
            .compactMap { library.albumKey(of: $0) }

        // Отбор с приоритетом, сохраняя стабильный порядок библиотеки внутри
        // одного приоритета.
        let favoriteKeySet = library.favoriteAlbumKeys
        let playedKeySet = Set(stats?.albums.map(\.albumKey) ?? [])
        let recentCutoff = Date().addingTimeInterval(-60 * 24 * 3600)
        func priority(_ group: AlbumGroup) -> Int {
            guard let key = library.albumKey(of: group) else { return 3 }
            if favoriteKeySet.contains(key) { return 0 }
            if playedKeySet.contains(key) { return 1 }
            if (group.tracks.compactMap(\.addedAt).max() ?? .distantPast) > recentCutoff {
                return 2
            }
            return 3
        }
        let selected = albums.enumerated()
            .sorted { lhs, rhs in
                let lp = priority(lhs.element), rp = priority(rhs.element)
                return lp != rp ? lp < rp : lhs.offset < rhs.offset
            }
            .prefix(Self.promptAlbumLimit)
            .map(\.element)

        var entries: [LibrarySnapshot.AlbumEntry] = []
        var keysById: [String: String] = [:]
        var idByKey: [String: String] = [:]
        for (index, group) in selected.enumerated() {
            guard let key = library.albumKey(of: group) else { continue }
            let id = "A\(index + 1)"
            keysById[id] = key
            idByKey[key] = id
            entries.append(.init(id: id,
                                 artist: group.artist,
                                 album: group.album,
                                 year: group.tracks.compactMap(\.year).first))
        }

        let snapshot = LibrarySnapshot(
            albums: entries,
            topArtists: (stats?.artists.prefix(20) ?? []).map {
                .init(name: $0.artist, plays: $0.count)
            },
            topAlbums: (stats?.albums.prefix(20) ?? []).compactMap { item in
                idByKey[item.albumKey].map { .init(id: $0, plays: item.count) }
            },
            favoriteAlbumIds: favoriteKeySet.compactMap { idByKey[$0] }.sorted(),
            favoriteTrackTitles: library.favoriteTracks.prefix(30).map(\.title),
            recentlyPlayedIds: recentlyPlayedKeys.compactMap { idByKey[$0] },
            recentlyAddedIds: selected
                .sorted {
                    ($0.tracks.compactMap(\.addedAt).max() ?? .distantPast)
                        > ($1.tracks.compactMap(\.addedAt).max() ?? .distantPast)
                }
                .prefix(15)
                .compactMap { library.albumKey(of: $0) }
                .compactMap { idByKey[$0] }
        )
        return (snapshot, keysById)
    }

    /// `HomeFeed` (короткие id) → резолвнутые секции (переносимые ключи).
    private static func resolve(_ feed: HomeFeed,
                                keysById: [String: String]) -> [ResolvedHomeSection] {
        feed.sections.compactMap { section in
            switch section.kind {
            case .albums:
                let keys = (section.albumIds ?? []).compactMap { keysById[$0] }
                guard !keys.isEmpty else { return nil }
                return ResolvedHomeSection(title: section.title,
                                           subtitle: section.subtitle,
                                           tags: section.tags,
                                           albumKeys: keys, external: [])
            case .external:
                let items = (section.items ?? []).map {
                    ExternalSuggestion(artist: $0.artist, album: $0.album,
                                       year: $0.year, reason: $0.reason)
                }
                guard !items.isEmpty else { return nil }
                return ResolvedHomeSection(title: section.title,
                                           subtitle: section.subtitle,
                                           tags: section.tags,
                                           albumKeys: [], external: items)
            }
        }
    }

    private static func describe(_ error: BrainError) -> String {
        switch error {
        case .missingToken: return "Ключ API не найден — задай его в Настройках → Интеллект."
        case .unauthorized: return "Ключ не подошёл (401) — проверь его в Настройках."
        case .rateLimited: return "Провайдер просит подождать (429) — попробуй позже."
        case .badResponse(let detail): return "Странный ответ провайдера: \(detail)"
        case .network(let detail): return "Сеть: \(detail)"
        }
    }

    // MARK: - Кэш

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CachedHomeFeed.self, from: data)
        else { return }
        feed = cached
    }

    private func saveCache(_ cached: CachedHomeFeed) {
        let url = cacheURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(cached) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
