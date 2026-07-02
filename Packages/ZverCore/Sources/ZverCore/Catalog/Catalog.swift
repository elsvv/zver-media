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

        return migrator
    }
}
