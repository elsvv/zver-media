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
    ///
    /// `keepMissing` вызывается только для путей, отсутствующих в
    /// `scanned`: true — запись сохраняется как есть. Так различаются
    /// «файл удалён с диска» и «файл на месте, но не прочитался при
    /// скане» (частично скопирован через file sharing, временный сбой
    /// чтения) — во втором случае удаление потеряло бы `addedAt`
    /// и плейлистные связи безвозвратно.
    ///
    /// Контракт: `addedAt` существующих треков сохраняется — фоновый
    /// рескан при каждом старте не должен сбрасывать дату добавления
    /// на время последнего скана (маппинг сканера ставит дефолтный
    /// `addedAt = Date()`).
    public func reconcile(
        scanned: [TrackRecord],
        keepMissing: (String) -> Bool = { _ in false }
    ) throws {
        try catalog.dbQueue.write { db in
            for record in scanned {
                // noOverwrite: при конфликте addedAt остаётся исходным,
                // остальные колонки перезаписываются значениями скана.
                _ = try record.upsertAndFetch(db) { _ in
                    [Column("addedAt").noOverwrite]
                }
            }
            let scannedPaths = Set(scanned.map(\.relativePath))
            let existingPaths = try String.fetchAll(
                db, sql: "SELECT relativePath FROM track"
            )
            let removedPaths = existingPaths.filter {
                !scannedPaths.contains($0) && !keepMissing($0)
            }
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
