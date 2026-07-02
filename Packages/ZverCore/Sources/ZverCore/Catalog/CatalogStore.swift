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
                // а облачные поля (fileState/cloudSha) — тоже: скан их не
                // знает (всегда дефолтные local/nil) и не должен затирать
                // подтверждённое в облаке состояние. Для вновь вставляемых
                // строк значения берутся из самого TrackRecord (local/nil).
                _ = try record.upsertAndFetch(db) { _ in
                    [Column("addedAt").noOverwrite,
                     Column("fileState").noOverwrite,
                     Column("cloudSha").noOverwrite]
                }
            }
            let scannedPaths = Set(scanned.map(\.relativePath))
            // Кандидаты на удаление — только не-облачные треки, отсутствующие
            // в скане. Каталог стал источником правды о наличии трека: remote/
            // backedUp/downloading (или любой с непустым cloudSha) физически
            // может отсутствовать на диске по дизайну и обязан пережить рескан.
            let candidates = try TrackRecord
                .filter(!scannedPaths.contains(Column("relativePath")))
                .fetchAll(db)
            let removedPaths = candidates
                .filter { isPurelyLocal($0) && !keepMissing($0.relativePath) }
                .map(\.relativePath)
            try TrackRecord.deleteAll(db, keys: removedPaths)
        }
    }

    /// Трек «чисто локальный» (никогда не подтверждён в облаке): cloudSha == nil
    /// И fileState ∈ {local, uploading}. Только такие удаляются при пропаже
    /// файла. Облачные (cloudSha != nil ИЛИ fileState ∈ {backedUp, remote,
    /// downloading}) сохраняются всегда.
    /// Удаляет строки треков по относительным путям (удаление альбома целиком,
    /// в т.ч. облачных `remote`/`backedUp`, которые reconcile сам не трогает).
    /// Плейлистные связи чистятся каскадом. Пустой список — no-op.
    public func deleteTracks(relativePaths: [String]) throws {
        guard !relativePaths.isEmpty else { return }
        try catalog.dbQueue.write { db in
            _ = try TrackRecord.deleteAll(db, keys: relativePaths)
        }
    }

    private func isPurelyLocal(_ record: TrackRecord) -> Bool {
        guard record.cloudSha == nil else { return false }
        switch FileState(rawValue: record.fileState) ?? .local {
        case .local, .uploading: return true
        case .backedUp, .remote, .downloading: return false
        }
    }

    // MARK: - Жизненный цикл fileState (этап 4)

    /// Обновляет `fileState` одной строки. Если `cloudSha` передан — пишет
    /// его, иначе колонку `cloudSha` не трогает. Несуществующий путь — no-op.
    /// Идемпотентно: повтор того же перехода ничего не ломает.
    public func setFileState(
        relativePath: String, _ state: FileState, cloudSha: String? = nil
    ) throws {
        try catalog.dbQueue.write { db in
            if let cloudSha {
                try db.execute(
                    sql: "UPDATE track SET fileState = ?, cloudSha = ? WHERE relativePath = ?",
                    arguments: [state.rawValue, cloudSha, relativePath]
                )
            } else {
                try db.execute(
                    sql: "UPDATE track SET fileState = ? WHERE relativePath = ?",
                    arguments: [state.rawValue, relativePath]
                )
            }
        }
    }

    /// Помечает трек подтверждённым в облаке (после сверки sha): `fileState`
    /// = `backedUp`, `cloudSha` = переданный. Идемпотентно. Несуществующий
    /// путь — no-op.
    public func markBackedUp(relativePath: String, cloudSha: String) throws {
        try setFileState(relativePath: relativePath, .backedUp, cloudSha: cloudSha)
    }

    /// Кандидаты на автобэкап: `fileState == local` И `cloudSha IS NULL`
    /// (есть локально, ещё не подтверждены в облаке). Отсортированы по пути.
    public func tracksAwaitingBackup() throws -> [TrackRecord] {
        try catalog.dbQueue.read { db in
            try TrackRecord
                .filter(Column("fileState") == FileState.local.rawValue)
                .filter(Column("cloudSha") == nil)
                .order(Column("relativePath"))
                .fetchAll(db)
        }
    }

    /// Треки в заданном `fileState` (для UI/диагностики). Отсортированы по пути.
    public func tracks(inState state: FileState) throws -> [TrackRecord] {
        try catalog.dbQueue.read { db in
            try TrackRecord
                .filter(Column("fileState") == state.rawValue)
                .order(Column("relativePath"))
                .fetchAll(db)
        }
    }

    /// Восстановление из облака: записи из скачанного `catalog.sqlite.backup`
    /// (несут `cloudSha`) вставляются как `remote` — после переустановки
    /// локальных файлов нет, вся библиотека показывается облачной. Существующие
    /// локальные строки НЕ деградируют: при конфликте relativePath строка,
    /// уже присутствующая в каталоге, сохраняет свой `fileState`/`cloudSha`/
    /// `addedAt` (решаем в пользу «есть локально»). Новые пути из бэкапа
    /// создаются в состоянии `remote`.
    public func importRemoteCatalog(records: [TrackRecord]) throws {
        try catalog.dbQueue.write { db in
            for record in records {
                var imported = record
                // импортируемое состояние всегда remote (на свежей установке
                // файла нет); существующую строку защищает noOverwrite ниже.
                imported.fileState = FileState.remote.rawValue
                _ = try imported.upsertAndFetch(db) { _ in
                    // не деградировать существующую локальную строку: при
                    // конфликте её fileState/cloudSha/addedAt остаются.
                    [Column("fileState").noOverwrite,
                     Column("cloudSha").noOverwrite,
                     Column("addedAt").noOverwrite]
                }
            }
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
