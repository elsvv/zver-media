import Foundation
import GRDB

/// Почему воспроизведение трека завершилось. Хранится в `playEvent.endReason`.
public enum PlayEndReason: String, Codable, Sendable {
    case finished   // доиграл до конца
    case skipped    // пользователь переключил
    case stopped    // остановка/выход
}

/// Событие воспроизведения — строка `playEvent`. Денормализовано снапшотом
/// title/artist/album/albumKey: история осмысленна даже после удаления трека
/// (у таблицы нет FK на `track`, см. миграцию v6). `id` присваивается БД при
/// вставке (autoincrement).
public struct PlayEvent: Codable, Equatable, Sendable,
                         FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playEvent"

    public var id: Int64?
    /// `trackKey` трека (для связи с каталогом, пока трек существует).
    public var trackKey: String
    public var title: String
    public var artist: String?
    public var album: String?
    /// `AlbumGroup.id` (путь папки) — устойчивый ключ альбома для группировки
    /// истории по альбомам («Недавно прослушанное»). nil у треков без альбома.
    public var albumKey: String?
    public var startedAt: Date
    /// Сколько секунд трек реально играл (сумма проигранного, без пауз-скипов).
    public var playedSeconds: Double
    /// Полная длительность трека на момент события (для правила «прослушал»).
    public var trackDuration: Double
    public var endReason: PlayEndReason

    public init(id: Int64? = nil, trackKey: String, title: String,
                artist: String? = nil, album: String? = nil, albumKey: String? = nil,
                startedAt: Date, playedSeconds: Double, trackDuration: Double,
                endReason: PlayEndReason) {
        self.id = id
        self.trackKey = trackKey
        self.title = title
        self.artist = artist
        self.album = album
        self.albumKey = albumKey
        self.startedAt = startedAt
        self.playedSeconds = playedSeconds
        self.trackDuration = trackDuration
        self.endReason = endReason
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Агрегат прослушивания за период — сырьё для будущих AI-рекомендаций.
/// Считается только по «прослушанным» событиям (`PlayHistoryStore.isListened`).
public struct ListeningStats: Equatable, Sendable {
    public struct ArtistCount: Equatable, Sendable {
        public let artist: String   // канон написания (ArtistName.canonical)
        public let count: Int
    }
    public struct AlbumCount: Equatable, Sendable {
        public let albumKey: String
        public let album: String    // название по последнему событию альбома
        public let artist: String?  // канон написания артиста альбома
        public let count: Int
    }
    /// Артисты по убыванию числа прослушиваний (тай-брейк — имя по алфавиту).
    public let artists: [ArtistCount]
    /// Альбомы по убыванию числа прослушиваний (тай-брейк — название по алфавиту).
    public let albums: [AlbumCount]
}

/// История прослушивания поверх `Catalog`. Пишет все события; правило
/// «прослушал» (`isListened`) применяется только в агрегатах — сырые события
/// сохраняются полностью (в т.ч. быстрые скипы, полезные для будущих сигналов).
///
/// Методы синхронные и бросают ошибки GRDB — вызываются с фоновой очереди
/// (как `PlaylistStore`/`CatalogStore`).
public final class PlayHistoryStore: Sendable {
    private let catalog: Catalog

    public init(catalog: Catalog) {
        self.catalog = catalog
    }

    /// Порог «прослушал» для агрегатов: ≥30с ИЛИ ≥50% длительности. Правило
    /// потребителя — сами события пишутся все (см. `record`). Статический, чтобы
    /// оставаться единственным источником правды и для UI, и для `listeningStats`.
    public static func isListened(playedSeconds: Double, trackDuration: Double) -> Bool {
        playedSeconds >= 30 || playedSeconds >= 0.5 * trackDuration
    }

    /// Записывает событие воспроизведения (всегда, без фильтра `isListened`).
    public func record(_ event: PlayEvent) throws {
        try catalog.dbQueue.write { db in
            var event = event
            try event.insert(db)
        }
    }

    /// Последние `limit` событий от новых к старым. Тай-брейк по `id` DESC
    /// упорядочивает события одной миллисекунды детерминированно.
    public func recentEvents(limit: Int) throws -> [PlayEvent] {
        try catalog.dbQueue.read { db in
            try PlayEvent
                .order(Column("startedAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Последние `limit` РАЗЛИЧНЫХ `albumKey` по времени последнего события
    /// альбома (карусель «Недавно прослушанное»). Альбом с nil-ключом
    /// (трек без альбома) пропускается.
    public func recentAlbumKeys(limit: Int) throws -> [String] {
        try catalog.dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT albumKey FROM playEvent
                WHERE albumKey IS NOT NULL
                GROUP BY albumKey
                ORDER BY MAX(startedAt) DESC, MAX(id) DESC
                LIMIT ?
                """,
                arguments: [limit]
            )
        }
    }

    /// Агрегат прослушивания с момента `since` — только по «прослушанным»
    /// событиям. Группировка и выбор канона написания — в Swift (объёмы малы,
    /// правило `isListened` не дублируется в SQL, канон совпадает с `ArtistName`).
    public func listeningStats(since: Date) throws -> ListeningStats {
        // Новые сверху: первое событие в группе альбома — самое свежее, из него
        // берём отображаемое название альбома.
        let events = try catalog.dbQueue.read { db in
            try PlayEvent
                .filter(Column("startedAt") >= since)
                .order(Column("startedAt").desc, Column("id").desc)
                .fetchAll(db)
        }
        let listened = events.filter {
            Self.isListened(playedSeconds: $0.playedSeconds, trackDuration: $0.trackDuration)
        }

        // Артисты: ключ объединения — ArtistName.key; отображаемое имя — канон
        // по всем встреченным вариантам написания.
        var artistOrder: [String] = []
        var artistVariants: [String: [String]] = [:]
        var artistCounts: [String: Int] = [:]
        for event in listened {
            guard let key = ArtistName.key(event.artist), let raw = event.artist else { continue }
            if artistCounts[key] == nil { artistOrder.append(key) }
            artistVariants[key, default: []].append(raw)
            artistCounts[key, default: 0] += 1
        }
        let artists = artistOrder
            .map { key in
                ListeningStats.ArtistCount(
                    artist: ArtistName.canonical(artistVariants[key] ?? []),
                    count: artistCounts[key] ?? 0)
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.artist.localizedCaseInsensitiveCompare(rhs.artist) == .orderedAscending
            }

        // Альбомы: ключ — albumKey; название — из самого свежего события группы
        // (события уже отсортированы по убыванию времени); артист — канон.
        var albumOrder: [String] = []
        var albumCounts: [String: Int] = [:]
        var albumTitle: [String: String] = [:]
        var albumArtistVariants: [String: [String]] = [:]
        for event in listened {
            guard let albumKey = event.albumKey else { continue }
            if albumCounts[albumKey] == nil {
                albumOrder.append(albumKey)
                albumTitle[albumKey] = event.album ?? ""
            }
            albumCounts[albumKey, default: 0] += 1
            if let artist = event.artist { albumArtistVariants[albumKey, default: []].append(artist) }
        }
        let albums = albumOrder
            .map { key -> ListeningStats.AlbumCount in
                let variants = albumArtistVariants[key] ?? []
                return ListeningStats.AlbumCount(
                    albumKey: key,
                    album: albumTitle[key] ?? "",
                    artist: variants.isEmpty ? nil : ArtistName.canonical(variants),
                    count: albumCounts[key] ?? 0)
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.album.localizedCaseInsensitiveCompare(rhs.album) == .orderedAscending
            }

        return ListeningStats(artists: artists, albums: albums)
    }
}
