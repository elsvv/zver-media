import Foundation
import GRDB

/// Плейлист каталога. Состав хранится отдельно в `playlistTrack`
/// и читается через `PlaylistStore.tracks(in:documentsURL:)`.
public struct Playlist: Identifiable, Equatable, Sendable {
    public let id: Int64
    public var title: String

    public init(id: Int64, title: String) {
        self.id = id
        self.title = title
    }
}

/// CRUD плейлистов и управление их составом поверх `Catalog`.
///
/// Методы синхронные и бросают ошибки GRDB — вызываются с фоновой
/// очереди LibraryStore (как и `CatalogStore`).
public final class PlaylistStore: Sendable {
    private let catalog: Catalog

    public init(catalog: Catalog) {
        self.catalog = catalog
    }

    // MARK: - Плейлисты

    public func createPlaylist(title: String) throws -> Playlist {
        try catalog.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO playlist (title, createdAt) VALUES (?, ?)",
                arguments: [title, Date()]
            )
            return Playlist(id: db.lastInsertedRowID, title: title)
        }
    }

    public func renamePlaylist(id: Int64, title: String) throws {
        try catalog.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE playlist SET title = ? WHERE id = ?",
                arguments: [title, id]
            )
        }
    }

    /// Удаляет плейлист; связи в `playlistTrack` чистятся каскадом
    /// (ON DELETE CASCADE в схеме).
    public func deletePlaylist(id: Int64) throws {
        try catalog.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [id])
        }
    }

    /// Все плейлисты в порядке создания. `id` — тай-брейк для
    /// плейлистов, созданных в одну миллисекунду (точность DATETIME GRDB).
    public func allPlaylists() throws -> [Playlist] {
        try catalog.dbQueue.read { db in
            try Row.fetchAll(
                db, sql: "SELECT id, title FROM playlist ORDER BY createdAt, id"
            )
            .map { Playlist(id: $0["id"], title: $0["title"]) }
        }
    }

    // MARK: - Состав плейлиста

    /// Треки плейлиста по позиции. Сравнение по `position` устойчиво
    /// к дыркам в нумерации (каскадное удаление трека не перенумеровывает).
    public func tracks(in playlistId: Int64, documentsURL: URL) throws -> [Track] {
        try catalog.dbQueue.read { db in
            try TrackRecord.fetchAll(
                db,
                sql: """
                SELECT track.* FROM track
                JOIN playlistTrack ON playlistTrack.trackRelativePath = track.relativePath
                WHERE playlistTrack.playlistId = ?
                ORDER BY playlistTrack.position
                """,
                arguments: [playlistId]
            )
        }
        .map { $0.track(documentsURL: documentsURL) }
    }

    /// Добавляет трек в конец (position = max + 1).
    /// Дубликат игнорируется (PK playlistId+trackRelativePath, OR IGNORE).
    public func add(trackPath: String, to playlistId: Int64) throws {
        try catalog.dbQueue.write { db in
            let maxPosition = try Int.fetchOne(
                db,
                sql: "SELECT MAX(position) FROM playlistTrack WHERE playlistId = ?",
                arguments: [playlistId]
            )
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO playlistTrack (playlistId, trackRelativePath, position)
                VALUES (?, ?, ?)
                """,
                arguments: [playlistId, trackPath, (maxPosition ?? -1) + 1]
            )
        }
    }

    /// Убирает трек из плейлиста и перенумеровывает позиции (0...n-1).
    public func remove(trackPath: String, from playlistId: Int64) throws {
        try catalog.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM playlistTrack WHERE playlistId = ? AND trackRelativePath = ?",
                arguments: [playlistId, trackPath]
            )
            let ordered = try Self.orderedPaths(db, playlistId: playlistId)
            try Self.renumber(db, playlistId: playlistId, orderedPaths: ordered)
        }
    }

    /// Переставляет трек на позицию `position` (клампится в границы)
    /// с целостной перенумерацией всех позиций. Неизвестный трек — no-op.
    public func move(trackPath: String, in playlistId: Int64, to position: Int) throws {
        try catalog.dbQueue.write { db in
            var ordered = try Self.orderedPaths(db, playlistId: playlistId)
            guard let from = ordered.firstIndex(of: trackPath) else { return }
            ordered.remove(at: from)
            ordered.insert(trackPath, at: max(0, min(position, ordered.count)))
            try Self.renumber(db, playlistId: playlistId, orderedPaths: ordered)
        }
    }

    // MARK: - Внутреннее

    private static func orderedPaths(_ db: Database, playlistId: Int64) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
            SELECT trackRelativePath FROM playlistTrack
            WHERE playlistId = ? ORDER BY position
            """,
            arguments: [playlistId]
        )
    }

    private static func renumber(_ db: Database, playlistId: Int64,
                                 orderedPaths: [String]) throws {
        for (index, path) in orderedPaths.enumerated() {
            try db.execute(
                sql: """
                UPDATE playlistTrack SET position = ?
                WHERE playlistId = ? AND trackRelativePath = ?
                """,
                arguments: [index, playlistId, path]
            )
        }
    }
}
