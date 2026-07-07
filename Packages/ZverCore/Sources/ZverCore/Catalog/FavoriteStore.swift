import Foundation
import GRDB

/// Что помечено избранным: трек или альбом. `rawValue` хранится в колонке
/// `favorite.entityKind`.
public enum FavoriteKind: String, Sendable {
    case track
    case album
}

/// Избранное (треки и альбомы) поверх `Catalog`. `entityKey` трека — его
/// `trackKey`; альбома — `AlbumGroup.id` (путь папки). Без FK на `track`:
/// избранное переживает офлоад/удаление файла (см. миграцию v6).
///
/// Методы синхронные и бросают ошибки GRDB — вызываются с фоновой очереди
/// LibraryStore (как `PlaylistStore`/`CatalogStore`).
public final class FavoriteStore: Sendable {
    private let catalog: Catalog

    public init(catalog: Catalog) {
        self.catalog = catalog
    }

    /// Ставит/снимает избранное. Идемпотентно: повторная установка не дублирует
    /// (композитный PK + INSERT OR IGNORE, `createdAt` первой отметки сохраняется),
    /// повторное снятие — no-op.
    public func setFavorite(kind: FavoriteKind, key: String, isFavorite: Bool) throws {
        try catalog.dbQueue.write { db in
            if isFavorite {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO favorite (entityKind, entityKey, createdAt)
                    VALUES (?, ?, ?)
                    """,
                    arguments: [kind.rawValue, key, Date()]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM favorite WHERE entityKind = ? AND entityKey = ?",
                    arguments: [kind.rawValue, key]
                )
            }
        }
    }

    public func isFavorite(kind: FavoriteKind, key: String) throws -> Bool {
        try catalog.dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM favorite WHERE entityKind = ? AND entityKey = ?)",
                arguments: [kind.rawValue, key]
            ) ?? false
        }
    }

    /// Избранные сущности вида `kind` от новых к старым. Тай-брейк по `entityKey`
    /// делает порядок детерминированным для отметок в одну миллисекунду
    /// (точность DATETIME GRDB).
    public func favorites(kind: FavoriteKind) throws -> [(key: String, createdAt: Date)] {
        try catalog.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT entityKey, createdAt FROM favorite
                WHERE entityKind = ? ORDER BY createdAt DESC, entityKey DESC
                """,
                arguments: [kind.rawValue]
            )
            .map { row -> (key: String, createdAt: Date) in
                (key: row["entityKey"], createdAt: row["createdAt"])
            }
        }
    }

    /// Множество ключей избранного вида `kind` — для быстрой отрисовки сердечек
    /// в списках (O(1) проверка на строку).
    public func favoriteKeys(kind: FavoriteKind) throws -> Set<String> {
        try catalog.dbQueue.read { db in
            try String.fetchSet(
                db,
                sql: "SELECT entityKey FROM favorite WHERE entityKind = ?",
                arguments: [kind.rawValue]
            )
        }
    }
}
