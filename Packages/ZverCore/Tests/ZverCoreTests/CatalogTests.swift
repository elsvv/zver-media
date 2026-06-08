import Foundation
import GRDB
import Testing
@testable import ZverCore

@Suite struct CatalogTests {

    // MARK: - Миграция

    @Test func migrationOnEmptyDatabaseCreatesTables() throws {
        let catalog = try Catalog.inMemory()

        let tables = try catalog.dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                ORDER BY name
                """
            )
        }
        #expect(tables == ["playlist", "playlistTrack", "track"])
    }

    @Test func reopeningSameDatabaseIsIdempotent() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-test-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Первое открытие: миграция + запись
        do {
            let catalog = try Catalog(path: path)
            try catalog.dbQueue.write { db in
                try TrackRecord(relativePath: "a.flac", title: "А",
                                duration: 1, sampleRate: 44100).insert(db)
            }
        }

        // Второе открытие той же БД: миграция не падает, данные на месте
        let reopened = try Catalog(path: path)
        let count = try reopened.dbQueue.read { db in
            try TrackRecord.fetchCount(db)
        }
        #expect(count == 1)
    }

    // MARK: - Миграция v2 (fileState, cloudSha)

    @Test func migrationV2AddsFileStateAndCloudShaColumns() throws {
        let catalog = try Catalog.inMemory()

        let columns = try catalog.dbQueue.read { db in
            try db.columns(in: "track").map(\.name)
        }
        #expect(columns.contains("fileState"))
        #expect(columns.contains("cloudSha"))
    }

    @Test func migrationV2DefaultsExistingRowsToLocalWithNilCloudSha() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-v2-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Эмулируем БД на версии v1: вставляем строку через сырой SQL без
        // колонок fileState/cloudSha, затем открываем «обновлённым» Catalog,
        // который применит миграцию v2.
        do {
            let db = try DatabaseQueue(path: path)
            var migratorV1 = DatabaseMigrator()
            migratorV1.registerMigration("v1") { db in
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
            try migratorV1.migrate(db)
            try db.write { db in
                try db.execute(sql: """
                    INSERT INTO track (relativePath, title, duration, sampleRate, addedAt)
                    VALUES ('old.flac', 'Старое', 1, 44100, ?)
                    """, arguments: [Date(timeIntervalSince1970: 1_700_000_000)])
            }
        }

        // Открываем актуальным Catalog → миграция v2 применяется поверх данных v1.
        let catalog = try Catalog(path: path)
        let migrated = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "old.flac")
        }
        #expect(migrated?.fileState == FileState.local.rawValue)
        #expect(migrated?.cloudSha == nil)
        #expect(migrated?.title == "Старое")
    }

    @Test func migrationV2IsIdempotentOnReopen() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-v2-idem-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Первое открытие: v1 + v2 применяются, пишем строку с облачными полями.
        do {
            let catalog = try Catalog(path: path)
            try catalog.dbQueue.write { db in
                try TrackRecord(relativePath: "a.flac", title: "А", duration: 1,
                                sampleRate: 44100, fileState: FileState.backedUp.rawValue,
                                cloudSha: "deadbeef").insert(db)
            }
        }

        // Повторное открытие: миграции не падают, облачные поля на месте.
        let reopened = try Catalog(path: path)
        let stored = try reopened.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "a.flac")
        }
        #expect(stored?.fileState == FileState.backedUp.rawValue)
        #expect(stored?.cloudSha == "deadbeef")
    }

    // MARK: - Roundtrip TrackRecord

    @Test func insertFetchRoundtripPreservesAllFields() throws {
        let catalog = try Catalog.inMemory()
        // 0.5 c — точно представимо и в Double, и в миллисекундном DATETIME GRDB
        let record = TrackRecord(
            relativePath: "Аврора/01 Рассвет.flac",
            title: "Рассвет",
            artist: "Аня",
            album: "Аврора",
            trackNumber: 1,
            year: 2024,
            duration: 213.5,
            sampleRate: 96000,
            bitDepth: 24,
            artworkFilePath: "Аврора/folder.jpg",
            addedAt: Date(timeIntervalSince1970: 1_750_000_000.5)
        )

        try catalog.dbQueue.write { db in try record.insert(db) }
        let fetched = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "Аврора/01 Рассвет.flac")
        }

        #expect(fetched == record)
    }

    @Test func insertFetchRoundtripPreservesNilOptionals() throws {
        let catalog = try Catalog.inMemory()
        let record = TrackRecord(
            relativePath: "loose.mp3",
            title: "Сирота",
            duration: 90,
            sampleRate: 44100,
            addedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )

        try catalog.dbQueue.write { db in try record.insert(db) }
        let fetched = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "loose.mp3")
        }

        #expect(fetched == record)
        #expect(fetched?.artist == nil)
        #expect(fetched?.album == nil)
        #expect(fetched?.trackNumber == nil)
        #expect(fetched?.year == nil)
        #expect(fetched?.bitDepth == nil)
        #expect(fetched?.artworkFilePath == nil)
    }

    @Test func insertFetchRoundtripPreservesFileStateAndCloudSha() throws {
        let catalog = try Catalog.inMemory()
        let record = TrackRecord(
            relativePath: "Аврора/01 Рассвет.flac",
            title: "Рассвет",
            duration: 213.5,
            sampleRate: 96000,
            addedAt: Date(timeIntervalSince1970: 1_750_000_000),
            fileState: FileState.remote.rawValue,
            cloudSha: "abc123"
        )

        try catalog.dbQueue.write { db in try record.insert(db) }
        let fetched = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "Аврора/01 Рассвет.flac")
        }

        #expect(fetched == record)
        #expect(fetched?.fileState == "remote")
        #expect(fetched?.cloudSha == "abc123")
    }

    @Test func trackRecordDefaultsFileStateLocalAndNilCloudSha() throws {
        let record = TrackRecord(relativePath: "a.flac", title: "А",
                                 duration: 1, sampleRate: 44100)

        #expect(record.fileState == FileState.local.rawValue)
        #expect(record.cloudSha == nil)
    }

    // MARK: - Конвертация Track <-> TrackRecord

    @Test func trackFromRecordResolvesURLsAgainstDocuments() throws {
        let documents = URL(fileURLWithPath: "/var/mobile/Documents")
        let record = TrackRecord(
            relativePath: "Аврора/01 Рассвет.flac",
            title: "Рассвет",
            artist: "Аня",
            album: "Аврора",
            trackNumber: 1,
            year: 2024,
            duration: 213.5,
            sampleRate: 96000,
            bitDepth: 24,
            artworkFilePath: "Аврора/folder.jpg"
        )

        let track = record.track(documentsURL: documents)

        #expect(track.url.path == "/var/mobile/Documents/Аврора/01 Рассвет.flac")
        #expect(track.title == "Рассвет")
        #expect(track.artist == "Аня")
        #expect(track.album == "Аврора")
        #expect(track.trackNumber == 1)
        #expect(track.year == 2024)
        #expect(track.duration == 213.5)
        #expect(track.sampleRate == 96000)
        #expect(track.bitDepth == 24)
        #expect(track.fileExtension == "flac")
        #expect(track.artworkFileURL?.path == "/var/mobile/Documents/Аврора/folder.jpg")
        // fileState по умолчанию local, если запись её не несёт
        #expect(track.fileState == .local)
    }

    @Test func trackFromRecordCarriesFileState() throws {
        let record = TrackRecord(relativePath: "a.flac", title: "А",
                                 duration: 1, sampleRate: 44100,
                                 fileState: FileState.remote.rawValue,
                                 cloudSha: "abc")

        let track = record.track(documentsURL: URL(fileURLWithPath: "/docs"))

        #expect(track.fileState == .remote)
    }

    @Test func trackDefaultsFileStateToLocal() throws {
        let track = Track(url: URL(fileURLWithPath: "/docs/a.flac"),
                          title: "А", duration: 1, sampleRate: 44100)

        #expect(track.fileState == .local)
    }

    @Test func trackFromRecordWithoutArtworkHasNilArtworkURL() throws {
        let record = TrackRecord(relativePath: "loose.mp3", title: "Сирота",
                                 duration: 90, sampleRate: 44100)

        let track = record.track(documentsURL: URL(fileURLWithPath: "/docs"))

        #expect(track.artworkFileURL == nil)
    }

    @Test func recordFromTrackKeepsMetadataAndRelativePath() throws {
        let track = Track(
            url: URL(fileURLWithPath: "/var/mobile/Documents/Аврора/01 Рассвет.flac"),
            title: "Рассвет", artist: "Аня", album: "Аврора",
            trackNumber: 1, year: 2024, duration: 213.5,
            sampleRate: 96000, bitDepth: 24
        )

        let record = TrackRecord(track: track,
                                 relativePath: "Аврора/01 Рассвет.flac",
                                 artworkFilePath: "Аврора/folder.jpg")

        #expect(record.relativePath == "Аврора/01 Рассвет.flac")
        #expect(record.title == "Рассвет")
        #expect(record.artist == "Аня")
        #expect(record.album == "Аврора")
        #expect(record.trackNumber == 1)
        #expect(record.year == 2024)
        #expect(record.duration == 213.5)
        #expect(record.sampleRate == 96000)
        #expect(record.bitDepth == 24)
        #expect(record.artworkFilePath == "Аврора/folder.jpg")
    }

    // MARK: - Связи

    @Test func deletingTrackCascadesIntoPlaylistTrack() throws {
        let catalog = try Catalog.inMemory()
        try catalog.dbQueue.write { db in
            try TrackRecord(relativePath: "a.flac", title: "А",
                            duration: 1, sampleRate: 44100).insert(db)
            try db.execute(sql: "INSERT INTO playlist (title, createdAt) VALUES ('Микс', ?)",
                           arguments: [Date()])
            try db.execute(
                sql: "INSERT INTO playlistTrack (playlistId, trackRelativePath, position) VALUES (1, 'a.flac', 0)"
            )
            _ = try TrackRecord.deleteOne(db, key: "a.flac")
        }

        let remaining = try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlistTrack") ?? -1
        }
        #expect(remaining == 0)
    }
}
