import Foundation
import ZverBrain
import ZverCore

/// Секция ленты «Главной» после резолва: короткие id промпта (`A17`)
/// превращены в переносимые ключи альбомов (относительные пути) — кэш ленты
/// переживает перегенерацию снапшота, где нумерация другая.
struct ResolvedHomeSection: Codable, Equatable, Identifiable, Sendable {
    /// Стабильный id в рамках одной ленты — ИНДЕКСНЫЙ (`sec3`), не title:
    /// модель может вернуть две секции с одинаковым названием, а дубликат id
    /// в ForEach молча роняет вторую секцию.
    let id: String
    let title: String
    let subtitle: String?
    let tags: [String]?
    /// Ключи альбомов библиотеки (kind=albums); пуст у внешних секций.
    let albumKeys: [String]
    /// Внешние рекомендации «что скачать» (kind=external); пуст у альбомных.
    let external: [ExternalSuggestion]
}

/// Внешняя рекомендация: альбом вне библиотеки + почему он зайдёт.
///
/// Поля от `genre` и ниже — из валидации через iTunes (Предложка v2). Все
/// опциональные: старый `homefeed.json` без них ЧИТАЕТСЯ (декодятся в nil).
struct ExternalSuggestion: Codable, Equatable, Identifiable, Sendable {
    /// Индексный id (`sec5-ext2`) — пара артист+альбом может повториться.
    let id: String
    let artist: String
    let album: String
    let year: Int?
    let reason: String
    /// Жанр по iTunes — бейдж на карточке.
    let genre: String?
    /// Прямая ссылка на релиз в Apple Music (`collectionViewUrl`).
    let appleMusicURL: String?
    /// Готовый URL обложки 600×600 — карточка не ходит в поиск второй раз.
    let artworkURL: String?
    /// Слаг категории discovery (эхо от модели через секцию).
    let category: String?
    /// Ключ релиза (`ReleaseNorm.key`) — связь с памятью рекомендаций
    /// (фидбек ♥/✕/«уже есть» из шита пишется по нему).
    let normKey: String?

    init(id: String, artist: String, album: String, year: Int?, reason: String,
         genre: String? = nil, appleMusicURL: String? = nil, artworkURL: String? = nil,
         category: String? = nil, normKey: String? = nil) {
        self.id = id
        self.artist = artist
        self.album = album
        self.year = year
        self.reason = reason
        self.genre = genre
        self.appleMusicURL = appleMusicURL
        self.artworkURL = artworkURL
        self.category = category
        self.normKey = normKey
    }
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
        /// Валидация кандидатов через iTunes: баннер «Проверяю рекомендации… N/M».
        case validating(done: Int, total: Int)
        case failed(String)

        /// Идёт работа (генерация или валидация) — повторный refresh запрещён.
        var isBusy: Bool {
            switch self {
            case .loading, .validating: return true
            case .idle, .failed: return false
            }
        }
    }

    @Published private(set) var feed: CachedHomeFeed?
    @Published private(set) var state: FeedState = .idle

    private let library: LibraryStore
    private let profiles: BrainProfilesStore
    private let cacheURL: URL

    init(library: LibraryStore, profiles: BrainProfilesStore,
         cacheURL: URL = URL.applicationSupportDirectory
             .appendingPathComponent("homefeed.json")) {
        self.library = library
        self.profiles = profiles
        self.cacheURL = cacheURL
        loadCache()
    }

    /// Сколько альбомов влезает в промпт: больше — режем с приоритетом
    /// избранного/прослушиваемого/недавнего (см. snapshot()).
    private static let promptAlbumLimit = 300

    /// UserDefaults-ключ offset ротации категорий (round-robin окно;
    /// сдвигается только после УСПЕШНОГО refresh — ошибки не крутят пул).
    static let rotationKey = "home.categoryRotation"

    /// Одержимость: ≥5 прослушиваний альбома за 14 дней; берём топ-3.
    private static let obsessionWindowDays: TimeInterval = 14
    private static let obsessionMinPlays = 5
    private static let obsessionLimit = 3

    /// Анти-сигнал скипов: ≥3 быстрых скипа артиста за 90 дней, топ-10 в промпт.
    private static let skipWindowDays: TimeInterval = 90
    private static let skipMinCount = 3
    private static let skippedArtistsLimit = 10

    /// Окно памяти показанного: и для дедупа, и для блока «УЖЕ ПРЕДЛАГАЛИ».
    private static let shownWindowDays: TimeInterval = 90
    private static let feedbackLimit = 20

    /// Обрезка external-секции: максимум 4 прошедших валидацию кандидата.
    private static let maxPerSection = 4

    // MARK: - Генерация

    /// Перегенерация ленты по кнопке. Ошибки — в `state` (UI показывает
    /// строку), успех перезаписывает кэш. Повторный вызов при работе — no-op.
    func refresh() async {
        guard !state.isBusy else { return }
        guard let config = profiles.config, profiles.isConfigured else {
            state = .failed("Создай профиль с ключом в Настройках → ИИ.")
            return
        }
        // Снимаем ВСЁ от активного профиля ДО первого await: если пользователь
        // переключит профиль во время сборки снапшота, нельзя получить config
        // профиля A с ключом профиля B (секрет уехал бы на чужой endpoint).
        let tokenProvider = profiles.tokenProvider
        let customInstructions = profiles.customInstructions
        state = .loading

        // Снапшот собирается на MainActor (читает published-библиотеку),
        // сеть и парсинг — вне.
        let (snapshot, keysById) = await snapshot()
        guard !snapshot.albums.isEmpty else {
            state = .failed("Библиотека пуста — ленте не из чего собираться.")
            return
        }
        // Ротация категорий: выбор делает приложение (промпт детерминирован),
        // offset — из UserDefaults, «Свежие релизы» — только при webSearch.
        let rotation = DiscoveryRotation.plan(
            hasObsessions: !snapshot.obsessions.isEmpty,
            webSearch: config.webSearch,
            offset: UserDefaults.standard.integer(forKey: Self.rotationKey))
        // Адаптер под тип API активного профиля (chat completions /
        // OpenAI Responses / Anthropic Messages) — фабрика ZverBrain.
        let client = BrainClientFactory.make(config: config,
                                             tokenProvider: tokenProvider)
        do {
            let (system, user) = HomeFeedPrompt.build(
                snapshot: snapshot,
                categories: rotation.categories,
                customInstructions: customInstructions)
            let text = try await client.complete(system: system, user: user)
            let parsed = try HomeFeedParser.parse(text, validAlbumIds: Set(keysById.keys))
            let resolved = await validateAndResolve(parsed, keysById: keysById)
            guard !resolved.isEmpty else {
                state = .failed("Модель вернула пустую ленту — попробуй ещё раз.")
                return
            }
            let cached = CachedHomeFeed(sections: resolved, updatedAt: Date())
            feed = cached
            saveCache(cached)
            UserDefaults.standard.set(rotation.nextOffset, forKey: Self.rotationKey)
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

        // Сигналы вкуса (Предложка v2): одержимости — альбомы с аномальной
        // плотностью прослушиваний за 14 дней; скипы — анти-сигнал; фидбек
        // по прошлым рекомендациям — из памяти показанного.
        let obsessionStats = await library.listeningStats(
            since: Date().addingTimeInterval(-Self.obsessionWindowDays * 24 * 3600))
        let obsessions = (obsessionStats?.albums ?? [])
            .filter { $0.count >= Self.obsessionMinPlays }
            .prefix(Self.obsessionLimit)
            .compactMap { item in item.artist.map { "\($0) — \(item.album)" } }

        let skipped = await library.skippedArtists(
            since: Date().addingTimeInterval(-Self.skipWindowDays * 24 * 3600),
            minSkips: Self.skipMinCount)

        let feedback = await library.recommendationFeedback(
            likedLimit: Self.feedbackLimit,
            hiddenLimit: Self.feedbackLimit,
            shownWindow: Date().addingTimeInterval(-Self.shownWindowDays * 24 * 3600))

        let snapshot = LibrarySnapshot(
            albums: entries,
            topArtists: (stats?.artists.prefix(20) ?? []).map {
                .init(name: $0.artist, plays: $0.count)
            },
            topAlbums: (stats?.albums.prefix(20) ?? []).compactMap { item in
                idByKey[item.albumKey].map { .init(id: $0, plays: item.count) }
            },
            favoriteAlbumIds: favoriteKeySet.compactMap { idByKey[$0] }
                .sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) },
            favoriteTrackTitles: library.favoriteTracks.prefix(30).map(\.title),
            recentlyPlayedIds: recentlyPlayedKeys.compactMap { idByKey[$0] },
            recentlyAddedIds: selected
                .sorted {
                    ($0.tracks.compactMap(\.addedAt).max() ?? .distantPast)
                        > ($1.tracks.compactMap(\.addedAt).max() ?? .distantPast)
                }
                .prefix(15)
                .compactMap { library.albumKey(of: $0) }
                .compactMap { idByKey[$0] },
            obsessions: Array(obsessions),
            skippedArtists: Array(skipped.prefix(Self.skippedArtistsLimit)),
            recFeedback: feedback.map {
                .init(liked: $0.liked, hidden: $0.hidden, recentlyShown: $0.recentlyShown)
            } ?? .empty
        )
        return (snapshot, keysById)
    }

    /// `HomeFeed` (короткие id) → резолвнутые секции (переносимые ключи) +
    /// валидация external-кандидатов (пайплайн refresh, шаги 4–6):
    /// 1) каждый кандидат проверяется через `ITunesCatalog.resolve` — прогресс
    ///    в `state` («Проверяю рекомендации… N/M»), не нашёлся — отбрасывается;
    /// 2) дедуп по normKey: библиотека, показанное за 90 дней (кроме liked),
    ///    сама лента; канонические имена iTunes — «второй ключ» (ловит Deluxe);
    /// 3) обрезка до `maxPerSection`; прошедшие — `recordShown` в память.
    private func validateAndResolve(_ parsed: HomeFeed,
                                    keysById: [String: String]) async -> [ResolvedHomeSection] {
        // Дедуп-набор: нормализованные ключи библиотеки + показанного за окно
        // (liked не в счёт — понравившееся дозволено вернуть) + самой ленты.
        var seenKeys = Set(library.albums.compactMap { group -> String? in
            group.id == AlbumGroup.noAlbumTitle
                ? nil
                : ReleaseNorm.key(artist: group.artist ?? "", album: group.album)
        })
        seenKeys.formUnion(await library.shownRecommendationKeys(
            since: Date().addingTimeInterval(-Self.shownWindowDays * 24 * 3600),
            excluding: [.liked]))

        let totalCandidates = parsed.sections
            .reduce(0) { $0 + ($1.kind == .external ? ($1.items ?? []).count : 0) }
        var checked = 0
        if totalCandidates > 0 {
            state = .validating(done: 0, total: totalCandidates)
        }

        var sections: [ResolvedHomeSection] = []
        var passed: [Recommendation] = []
        let shownAt = Date()

        for (index, section) in parsed.sections.enumerated() {
            switch section.kind {
            case .albums:
                let keys = (section.albumIds ?? []).compactMap { keysById[$0] }
                guard !keys.isEmpty else { continue }
                sections.append(ResolvedHomeSection(id: "sec\(index)",
                                                    title: section.title,
                                                    subtitle: section.subtitle,
                                                    tags: section.tags,
                                                    albumKeys: keys, external: []))
            case .external:
                var kept: [ExternalSuggestion] = []
                for item in section.items ?? [] {
                    checked += 1
                    defer { state = .validating(done: checked, total: totalCandidates) }
                    // Секция уже набрана — остаток не жжёт троттлинг/API.
                    guard kept.count < Self.maxPerSection else { continue }

                    let normKey = ReleaseNorm.key(artist: item.artist, album: item.album)
                    guard !seenKeys.contains(normKey) else { continue }
                    guard let resolved = await ITunesCatalog.shared.resolve(
                        artist: item.artist, album: item.album) else { continue }
                    let canonicalKey = ReleaseNorm.key(artist: resolved.canonicalArtist,
                                                       album: resolved.canonicalAlbum)
                    guard !seenKeys.contains(canonicalKey) else { continue }
                    seenKeys.insert(normKey)
                    seenKeys.insert(canonicalKey)

                    kept.append(ExternalSuggestion(
                        id: "sec\(index)-ext\(kept.count)",
                        artist: item.artist, album: item.album,
                        year: item.year ?? resolved.year,
                        reason: item.reason,
                        genre: resolved.genre,
                        appleMusicURL: resolved.appleMusicURL,
                        artworkURL: resolved.artworkURL600,
                        category: section.category,
                        normKey: normKey))
                    passed.append(Recommendation(
                        artist: item.artist, album: item.album, normKey: normKey,
                        year: item.year ?? resolved.year,
                        category: section.category, reason: item.reason,
                        genre: resolved.genre,
                        appleMusicURL: resolved.appleMusicURL,
                        artworkURL: resolved.artworkURL600,
                        itunesId: resolved.itunesId,
                        shownAt: shownAt))
                }
                guard !kept.isEmpty else { continue }
                sections.append(ResolvedHomeSection(id: "sec\(index)",
                                                    title: section.title,
                                                    subtitle: section.subtitle,
                                                    tags: section.tags,
                                                    albumKeys: [], external: kept))
            }
        }

        // Память показанного: только реально попавшее в ленту.
        await library.recordShownRecommendations(passed)
        return sections
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
