import Foundation
import GRDB

/// Статус рекомендации. Хранится в `recommendation.status`.
public enum RecommendationStatus: String, Codable, Sendable {
    case shown    // показана в ленте, реакции нет
    case liked    // ♥ «Нравится»
    case hidden   // ✕ «Не моё» — анти-сигнал в промпт
    case owned    // «У меня уже есть» — страховка дедупа
}

/// Внешняя рекомендация — строка `recommendation`. Релиза нет в каталоге,
/// поэтому таблица без FK (см. миграцию v7); идентичность релиза — `normKey`
/// (`ReleaseNorm.key`, UNIQUE). `id` присваивается БД при вставке (autoincrement).
public struct Recommendation: Codable, Equatable, Sendable,
                              FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "recommendation"

    public var id: Int64?
    public var artist: String
    public var album: String
    /// Нормализованный ключ релиза (`ReleaseNorm.key`) — UNIQUE в БД.
    public var normKey: String
    public var year: Int?
    /// Слаг категории ленты (`DiscoveryCategory`), эхо от модели.
    public var category: String?
    /// Объяснение модели «почему рекомендовано» — показывается в шите.
    public var reason: String?
    public var status: RecommendationStatus
    public var genre: String?
    public var appleMusicURL: String?
    public var artworkURL: String?
    public var itunesId: Int64?
    /// JSON-кэш ссылок Odesli (заполняется по тапу, см. `cacheLinks`).
    public var links: String?
    /// Когда рекомендацию показали в ленте последний раз.
    public var shownAt: Date
    /// Когда менялся статус (фидбек); при вставке совпадает с `shownAt`.
    public var updatedAt: Date

    /// `normKey` по умолчанию считается из артиста/альбома — единственный
    /// источник правды `ReleaseNorm`; `updatedAt` по умолчанию равен `shownAt`.
    public init(id: Int64? = nil, artist: String, album: String, normKey: String? = nil,
                year: Int? = nil, category: String? = nil, reason: String? = nil,
                status: RecommendationStatus = .shown, genre: String? = nil,
                appleMusicURL: String? = nil, artworkURL: String? = nil,
                itunesId: Int64? = nil, links: String? = nil,
                shownAt: Date, updatedAt: Date? = nil) {
        self.id = id
        self.artist = artist
        self.album = album
        self.normKey = normKey ?? ReleaseNorm.key(artist: artist, album: album)
        self.year = year
        self.category = category
        self.reason = reason
        self.status = status
        self.genre = genre
        self.appleMusicURL = appleMusicURL
        self.artworkURL = artworkURL
        self.itunesId = itunesId
        self.links = links
        self.shownAt = shownAt
        self.updatedAt = updatedAt ?? shownAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Срез фидбека для промпта: блоки «ПОНРАВИЛОСЬ ИЗ РЕКОМЕНДАЦИЙ»,
/// «НЕ ЗАХОДИТ» и «УЖЕ ПРЕДЛАГАЛИ». Строки — «Артист — Альбом»
/// (формат одержимостей снапшота).
public struct RecFeedback: Equatable, Sendable {
    public let liked: [String]
    public let hidden: [String]
    /// Всё показанное за окно, независимо от статуса, — жёсткий запрет повтора.
    public let recentlyShown: [String]

    public init(liked: [String], hidden: [String], recentlyShown: [String]) {
        self.liked = liked
        self.hidden = hidden
        self.recentlyShown = recentlyShown
    }
}

/// Память показанных рекомендаций и фидбека поверх `Catalog`.
///
/// Методы синхронные и бросают ошибки GRDB — вызываются с фоновой очереди
/// (как `PlayHistoryStore`/`FavoriteStore`).
public final class RecommendationStore: Sendable {
    private let catalog: Catalog

    public init(catalog: Catalog) {
        self.catalog = catalog
    }

    /// Фиксирует показ рекомендации: upsert по `normKey`. Повторный показ
    /// обновляет `shownAt`/`updatedAt` и метаданные (модель могла уточнить
    /// reason/год/обложку), но СОХРАНЯЕТ `status` и `links` — фидбек
    /// пользователя и кэш ссылок переживают повторные показы.
    public func recordShown(_ rec: Recommendation) throws {
        try catalog.dbQueue.write { db in
            if var existing = try Recommendation
                .filter(Column("normKey") == rec.normKey).fetchOne(db) {
                existing.artist = rec.artist
                existing.album = rec.album
                existing.year = rec.year
                existing.category = rec.category
                existing.reason = rec.reason
                existing.genre = rec.genre
                existing.appleMusicURL = rec.appleMusicURL
                existing.artworkURL = rec.artworkURL
                existing.itunesId = rec.itunesId
                existing.shownAt = rec.shownAt
                existing.updatedAt = rec.updatedAt
                try existing.update(db)
            } else {
                var inserted = rec
                try inserted.insert(db)
            }
        }
    }

    /// Ставит статус (фидбек пользователя) и двигает `updatedAt`. Неизвестный
    /// `normKey` — no-op (рекомендация могла уйти из памяти). `at` — параметром
    /// ради тестируемости (дефолт — текущий момент).
    public func setStatus(normKey: String, status: RecommendationStatus,
                          at date: Date = Date()) throws {
        try catalog.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE recommendation SET status = ?, updatedAt = ? WHERE normKey = ?",
                arguments: [status.rawValue, date, normKey]
            )
        }
    }

    /// Срез фидбека для промпта. `liked`/`hidden` — свежие сверху (по
    /// `updatedAt`, тай-брейк `id` DESC) с лимитами; `recentlyShown` — всё
    /// показанное с `shownWindow`, независимо от статуса, новые сверху.
    public func feedback(likedLimit: Int, hiddenLimit: Int,
                         shownWindow: Date) throws -> RecFeedback {
        try catalog.dbQueue.read { db in
            RecFeedback(
                liked: try Self.labels(db, sql: """
                    SELECT artist, album FROM recommendation WHERE status = 'liked'
                    ORDER BY updatedAt DESC, id DESC LIMIT ?
                    """, arguments: [likedLimit]),
                hidden: try Self.labels(db, sql: """
                    SELECT artist, album FROM recommendation WHERE status = 'hidden'
                    ORDER BY updatedAt DESC, id DESC LIMIT ?
                    """, arguments: [hiddenLimit]),
                recentlyShown: try Self.labels(db, sql: """
                    SELECT artist, album FROM recommendation WHERE shownAt >= ?
                    ORDER BY shownAt DESC, id DESC
                    """, arguments: [shownWindow])
            )
        }
    }

    /// Ключи показанного с `since` — для дедупа ленты. По умолчанию любой
    /// статус; `excluding` вычитает статусы (дизайн: показанное за 90 дней
    /// КРОМЕ liked — понравившееся дозволено вернуть).
    public func shownKeys(since: Date,
                          excluding statuses: Set<RecommendationStatus> = []) throws -> Set<String> {
        try catalog.dbQueue.read { db in
            if statuses.isEmpty {
                return try String.fetchSet(
                    db,
                    sql: "SELECT normKey FROM recommendation WHERE shownAt >= ?",
                    arguments: [since]
                )
            }
            let placeholders = databaseQuestionMarks(count: statuses.count)
            return try String.fetchSet(
                db,
                sql: """
                SELECT normKey FROM recommendation
                WHERE shownAt >= ? AND status NOT IN (\(placeholders))
                """,
                arguments: StatementArguments([since])
                    + StatementArguments(statuses.map(\.rawValue).sorted())
            )
        }
    }

    /// Ключи рекомендаций с данным статусом. Нужны ленте для ♥-бейджей
    /// карточек (liked) — без окна по времени: лайк не протухает.
    public func keys(withStatus status: RecommendationStatus) throws -> Set<String> {
        try catalog.dbQueue.read { db in
            try String.fetchSet(
                db,
                sql: "SELECT normKey FROM recommendation WHERE status = ?",
                arguments: [status.rawValue]
            )
        }
    }

    /// Кэширует JSON ссылок Odesli. Чистый кэш, не фидбек: `status` и
    /// `updatedAt` не трогаем. Неизвестный `normKey` — no-op.
    public func cacheLinks(normKey: String, json: String) throws {
        try catalog.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE recommendation SET links = ? WHERE normKey = ?",
                arguments: [json, normKey]
            )
        }
    }

    /// Кэшированный JSON ссылок Odesli (`cacheLinks`) или nil — кэша нет
    /// (строка без ссылок ИЛИ неизвестный `normKey`): повторное открытие
    /// шита читает отсюда и не ходит в сеть.
    public func cachedLinks(normKey: String) throws -> String? {
        try catalog.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT links FROM recommendation WHERE normKey = ?",
                arguments: [normKey]
            )
        }
    }

    /// «Артист — Альбом» из строк выборки (формат блоков промпта).
    private static func labels(_ db: Database, sql: String,
                               arguments: StatementArguments) throws -> [String] {
        try Row.fetchAll(db, sql: sql, arguments: arguments)
            .map { "\($0["artist"] as String) — \($0["album"] as String)" }
    }
}
