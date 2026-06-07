import Foundation
import GRDB

/// Сверка и выборки каталога поверх `Catalog`.
///
/// Методы синхронные и бросают ошибки GRDB — вызываются с фоновой
/// очереди LibraryStore.
public final class CatalogStore: Sendable {
    private let catalog: Catalog

    public init(catalog: Catalog) {
        self.catalog = catalog
    }

    /// Сверяет каталог с результатом сканирования: в одной транзакции
    /// upsert всех записей и удаление треков, чьих relativePath нет
    /// в `scanned` (файлы удалены). Плейлистные связи чистятся
    /// каскадом (ON DELETE CASCADE).
    public func reconcile(scanned: [TrackRecord]) throws {
        try catalog.dbQueue.write { db in
            for record in scanned {
                try record.upsert(db)
            }
            let scannedPaths = Set(scanned.map(\.relativePath))
            let existingPaths = try String.fetchAll(
                db, sql: "SELECT relativePath FROM track"
            )
            let removedPaths = existingPaths.filter { !scannedPaths.contains($0) }
            try TrackRecord.deleteAll(db, keys: removedPaths)
        }
    }

    /// Все треки каталога, отсортированные по relativePath.
    public func allTracks(documentsURL: URL) throws -> [Track] {
        try catalog.dbQueue.read { db in
            try TrackRecord
                .order(Column("relativePath"))
                .fetchAll(db)
        }
        .map { $0.track(documentsURL: documentsURL) }
    }

    /// Поиск без учёта регистра по title/artist/album.
    ///
    /// Фильтрация в Swift поверх `allTracks`: SQLite LOWER/LIKE без ICU
    /// не понимает кириллицу («Зверь» не совпадает с '%зверь%'),
    /// а объёмы локальной библиотеки малы — линейный проход через
    /// `localizedCaseInsensitiveContains` честнее и проще FTS/нормализации.
    /// Пустой или пробельный запрос → [].
    public func search(_ query: String, documentsURL: URL) throws -> [Track] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        return try allTracks(documentsURL: documentsURL).filter { track in
            track.title.localizedCaseInsensitiveContains(needle)
                || track.artist?.localizedCaseInsensitiveContains(needle) == true
                || track.album?.localizedCaseInsensitiveContains(needle) == true
        }
    }
}
