import Foundation
import GRDB

/// Персистентный каталог библиотеки: SQLite (GRDB) с миграциями.
///
/// Треки хранятся относительными путями от Documents — путь стабилен между
/// реинсталлами, тогда как UUID контейнера приложения меняется.
public final class Catalog: Sendable {
    public let dbQueue: DatabaseQueue

    /// Открывает (создавая при необходимости) БД по пути и применяет миграции.
    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
    }

    /// БД в памяти — для тестов.
    public static func inMemory() throws -> Catalog {
        try Catalog(dbQueue: DatabaseQueue())
    }

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "track") { t in
                t.primaryKey("relativePath", .text)
                t.column("title", .text).notNull()
                t.column("artist", .text)
                t.column("album", .text)
                t.column("trackNumber", .integer)
                t.column("year", .integer)
                t.column("duration", .double).notNull()
                t.column("sampleRate", .double).notNull()
                t.column("bitDepth", .integer)
                t.column("artworkFilePath", .text)
                t.column("addedAt", .datetime).notNull()
            }

            try db.create(table: "playlist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "playlistTrack") { t in
                t.column("playlistId", .integer).notNull()
                    .references("playlist", onDelete: .cascade)
                t.column("trackRelativePath", .text).notNull()
                    .references("track", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.primaryKey(["playlistId", "trackRelativePath"])
            }
        }

        // v2: ярус хранения трека (этап 4 «Яндекс.Диск»). Аддитивна и
        // идемпотентна — только ALTER TABLE ADD COLUMN. Существующие строки
        // (физически на диске) получают fileState = 'local', cloudSha = NULL.
        migrator.registerMigration("v2") { db in
            try db.alter(table: "track") { t in
                t.add(column: "fileState", .text)
                    .notNull()
                    .defaults(to: FileState.local.rawValue)
                t.add(column: "cloudSha", .text)
            }
        }

        // v3: номер диска (много-дисковые альбомы). Аддитивна и идемпотентна —
        // только ALTER TABLE ADD COLUMN. Существующие строки получают NULL
        // (одно-дисковый), пока рескан не подхватит DISCNUMBER из тегов/sidecar.
        migrator.registerMigration("v3") { db in
            try db.alter(table: "track") { t in
                t.add(column: "discNumber", .integer)
            }
        }

        // v4: метка диска (`CD1`/`Side A`) из папки/плейлиста. Аддитивна: NULL у
        // существующих строк, пока рескан не подхватит структуру папок/плейлист.
        migrator.registerMigration("v4") { db in
            try db.alter(table: "track") { t in
                t.add(column: "discLabel", .text)
            }
        }

        // v5: cue-альбомы (image+cue). Пересоздаём `track` с новым PK `trackKey`
        // (SQLite не умеет ALTER PRIMARY KEY) и добавляем границы cue-трека
        // (`cueIndex`/`startFrame`/`frameCount`). Для обычных треков
        // `trackKey == relativePath`; cue-строки одного `.flac` делят `relativePath`
        // и различаются только `trackKey = "\(relativePath)#\(cueIndex)"`.
        //
        // Миграция deferred → GRDB держит `PRAGMA foreign_keys = OFF` на время
        // перестройки и проверяет целостность перед коммитом (12-шаговая процедура
        // SQLite). Пользовательские плейлисты сохраняются: `playlistTrack`
        // пересоздаётся с FK на `track(trackKey)`, а для существующих связей
        // `trackKey == relativePath`, поэтому маппинг — тождественный.
        migrator.registerMigration("v5") { db in
            try db.create(table: "track_new") { t in
                t.primaryKey("trackKey", .text)
                t.column("relativePath", .text).notNull()
                t.column("title", .text).notNull()
                t.column("artist", .text)
                t.column("album", .text)
                t.column("trackNumber", .integer)
                t.column("year", .integer)
                t.column("duration", .double).notNull()
                t.column("sampleRate", .double).notNull()
                t.column("bitDepth", .integer)
                t.column("artworkFilePath", .text)
                t.column("addedAt", .datetime).notNull()
                t.column("fileState", .text)
                    .notNull()
                    .defaults(to: FileState.local.rawValue)
                t.column("cloudSha", .text)
                t.column("discNumber", .integer)
                t.column("discLabel", .text)
                t.column("cueIndex", .integer)
                t.column("startFrame", .integer)
                t.column("frameCount", .integer)
            }

            // Старые строки: 1 файл = 1 трек, trackKey = relativePath, границы NULL.
            try db.execute(sql: """
                INSERT INTO track_new
                    (trackKey, relativePath, title, artist, album, trackNumber, year,
                     duration, sampleRate, bitDepth, artworkFilePath, addedAt,
                     fileState, cloudSha, discNumber, discLabel,
                     cueIndex, startFrame, frameCount)
                SELECT relativePath, relativePath, title, artist, album, trackNumber, year,
                       duration, sampleRate, bitDepth, artworkFilePath, addedAt,
                       fileState, cloudSha, discNumber, discLabel,
                       NULL, NULL, NULL
                FROM track
                """)

            try db.drop(table: "track")
            try db.rename(table: "track_new", to: "track")

            // Пересоздаём playlistTrack с FK на track(trackKey) — сохраняя связи.
            try db.create(table: "playlistTrack_new") { t in
                t.column("playlistId", .integer).notNull()
                    .references("playlist", onDelete: .cascade)
                t.column("trackRelativePath", .text).notNull()
                    .references("track", column: "trackKey", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.primaryKey(["playlistId", "trackRelativePath"])
            }
            try db.execute(sql: """
                INSERT INTO playlistTrack_new (playlistId, trackRelativePath, position)
                SELECT playlistId, trackRelativePath, position FROM playlistTrack
                """)
            try db.drop(table: "playlistTrack")
            try db.rename(table: "playlistTrack_new", to: "playlistTrack")
        }

        return migrator
    }
}
