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
        #expect(tables == ["favorite", "playEvent", "playlist", "playlistTrack", "track"])
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

    // MARK: - Миграция v3 (discNumber)

    @Test func migrationV3AddsDiscNumberColumn() throws {
        let catalog = try Catalog.inMemory()
        let columns = try catalog.dbQueue.read { db in
            try db.columns(in: "track").map(\.name)
        }
        #expect(columns.contains("discNumber"))
    }

    @Test func insertFetchRoundtripPreservesDiscNumber() throws {
        let catalog = try Catalog.inMemory()
        let record = TrackRecord(
            relativePath: "Mezzanine/CD2/01.flac",
            title: "Metal Banshee",
            album: "Mezzanine",
            trackNumber: 1,
            discNumber: 2,
            duration: 300,
            sampleRate: 44100,
            addedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        try catalog.dbQueue.write { db in try record.insert(db) }
        let fetched = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "Mezzanine/CD2/01.flac")
        }
        #expect(fetched == record)
        #expect(fetched?.discNumber == 2)
    }

    @Test func trackRecordConversionCarriesDiscNumber() throws {
        let track = Track(
            url: URL(fileURLWithPath: "/docs/Mezzanine/CD2/01.flac"),
            title: "Metal Banshee", album: "Mezzanine",
            trackNumber: 1, discNumber: 2, discLabel: "CD2", duration: 300, sampleRate: 44100)
        let record = TrackRecord(track: track, relativePath: "Mezzanine/CD2/01.flac",
                                 artworkFilePath: nil)
        #expect(record.discNumber == 2)
        #expect(record.discLabel == "CD2")
        let back = record.track(documentsURL: URL(fileURLWithPath: "/docs"))
        #expect(back.discNumber == 2)
        #expect(back.discLabel == "CD2")
    }

    // MARK: - Миграция v4 (discLabel)

    @Test func migrationV4AddsDiscLabelColumn() throws {
        let catalog = try Catalog.inMemory()
        let columns = try catalog.dbQueue.read { db in
            try db.columns(in: "track").map(\.name)
        }
        #expect(columns.contains("discLabel"))
    }

    @Test func insertFetchRoundtripPreservesDiscLabel() throws {
        let catalog = try Catalog.inMemory()
        let record = TrackRecord(
            relativePath: "Maxinquaye/CD1/01.flac", title: "Overcome",
            trackNumber: 1, discNumber: 1, discLabel: "CD1",
            duration: 300, sampleRate: 44100,
            addedAt: Date(timeIntervalSince1970: 1_750_000_000))
        try catalog.dbQueue.write { db in try record.insert(db) }
        let fetched = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "Maxinquaye/CD1/01.flac")
        }
        #expect(fetched?.discLabel == "CD1")
        #expect(fetched == record)
    }

    // MARK: - Миграция v5 (trackKey PK + границы cue)

    /// Строит БД на схеме v4 (до cue) с треками/плейлистом и возвращает путь.
    /// Открытие актуальным `Catalog` затем применит поверх миграцию v5.
    private func makeV4Database() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-v5-\(UUID().uuidString).sqlite").path
        let db = try DatabaseQueue(path: path)
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
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
        m.registerMigration("v2") { db in
            try db.alter(table: "track") { t in
                t.add(column: "fileState", .text).notNull().defaults(to: FileState.local.rawValue)
                t.add(column: "cloudSha", .text)
            }
        }
        m.registerMigration("v3") { db in
            try db.alter(table: "track") { t in t.add(column: "discNumber", .integer) }
        }
        m.registerMigration("v4") { db in
            try db.alter(table: "track") { t in t.add(column: "discLabel", .text) }
        }
        try m.migrate(db)
        return path
    }

    @Test func migrationV5AddsTrackKeyPrimaryKeyAndCueColumns() throws {
        let catalog = try Catalog.inMemory()
        let columns = try catalog.dbQueue.read { db in
            try db.columns(in: "track").map(\.name)
        }
        #expect(columns.contains("trackKey"))
        #expect(columns.contains("cueIndex"))
        #expect(columns.contains("startFrame"))
        #expect(columns.contains("frameCount"))
        // PK перекатан на trackKey (SQLite не умеет ALTER PRIMARY KEY)
        let pk = try catalog.dbQueue.read { db in try db.primaryKey("track").columns }
        #expect(pk == ["trackKey"])
    }

    @Test func migrationV5CopiesOldRowsWithTrackKeyEqualToRelativePath() throws {
        let path = try makeV4Database()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            let db = try DatabaseQueue(path: path)
            try db.write { db in
                try db.execute(sql: """
                    INSERT INTO track (relativePath, title, duration, sampleRate, addedAt,
                                       fileState, cloudSha, discNumber, discLabel)
                    VALUES ('alb/01.flac', 'Первый', 213.5, 44100, ?, 'backedUp', 'sha1', 1, 'CD1')
                    """, arguments: [addedAt])
            }
        }

        // Открываем актуальным Catalog → применяется v5 поверх данных v4.
        let catalog = try Catalog(path: path)
        let rec = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "alb/01.flac")
        }
        #expect(rec?.trackKey == "alb/01.flac")
        #expect(rec?.relativePath == "alb/01.flac")
        #expect(rec?.title == "Первый")
        #expect(rec?.duration == 213.5)
        #expect(rec?.fileState == FileState.backedUp.rawValue)
        #expect(rec?.cloudSha == "sha1")
        #expect(rec?.discNumber == 1)
        #expect(rec?.discLabel == "CD1")
        // границы cue у мигрированных обычных треков — NULL
        #expect(rec?.cueIndex == nil)
        #expect(rec?.startFrame == nil)
        #expect(rec?.frameCount == nil)
    }

    @Test func migrationV5PreservesUserPlaylists() throws {
        let path = try makeV4Database()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            let db = try DatabaseQueue(path: path)
            try db.write { db in
                try db.execute(sql: """
                    INSERT INTO track (relativePath, title, duration, sampleRate, addedAt)
                    VALUES ('a.flac', 'А', 1, 44100, ?)
                    """, arguments: [addedAt])
                try db.execute(sql: """
                    INSERT INTO track (relativePath, title, duration, sampleRate, addedAt)
                    VALUES ('b.flac', 'Б', 1, 44100, ?)
                    """, arguments: [addedAt])
                try db.execute(sql: "INSERT INTO playlist (title, createdAt) VALUES ('Микс', ?)",
                               arguments: [addedAt])
                try db.execute(sql: """
                    INSERT INTO playlistTrack (playlistId, trackRelativePath, position)
                    VALUES (1, 'a.flac', 0), (1, 'b.flac', 1)
                    """)
            }
        }

        let catalog = try Catalog(path: path)
        let store = PlaylistStore(catalog: catalog)

        // плейлист и его состав целы; порядок сохранён
        #expect(try store.allPlaylists().map(\.title) == ["Микс"])
        let titles = try store.tracks(in: 1, documentsURL: URL(fileURLWithPath: "/docs")).map(\.title)
        #expect(titles == ["А", "Б"])

        // FK перекатан на track(trackKey): каскад из track всё ещё работает.
        try CatalogStore(catalog: catalog).deleteTracks(relativePaths: ["a.flac"])
        let remaining = try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlistTrack") ?? -1
        }
        #expect(remaining == 1)
    }

    @Test func migrationV5IsIdempotentOnReopen() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-v5-idem-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let catalog = try Catalog(path: path)
            try catalog.dbQueue.write { db in
                try TrackRecord(relativePath: "alb/CD.flac", title: "Трек 1", duration: 1,
                                sampleRate: 44100, cueIndex: 1, startFrame: 0,
                                frameCount: 4_410_000).insert(db)
            }
        }
        // повторное открытие — миграции не падают, cue-строка на месте
        let reopened = try Catalog(path: path)
        let rec = try reopened.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "alb/CD.flac#1")
        }
        #expect(rec?.startFrame == 0)
        #expect(rec?.frameCount == 4_410_000)
    }

    // MARK: - Миграция v6 (favorite, playEvent)

    @Test func migrationV6CreatesFavoriteTableWithCompositePrimaryKey() throws {
        let catalog = try Catalog.inMemory()
        let columns = try catalog.dbQueue.read { db in
            try db.columns(in: "favorite").map(\.name)
        }
        #expect(columns == ["entityKind", "entityKey", "createdAt"])
        let pk = try catalog.dbQueue.read { db in try db.primaryKey("favorite").columns }
        #expect(pk == ["entityKind", "entityKey"])
    }

    @Test func migrationV6CreatesPlayEventTableWithColumnsAndIndex() throws {
        let catalog = try Catalog.inMemory()
        let columns = try catalog.dbQueue.read { db in
            try db.columns(in: "playEvent").map(\.name)
        }
        #expect(columns == ["id", "trackKey", "title", "artist", "album", "albumKey",
                            "startedAt", "playedSeconds", "trackDuration", "endReason"])
        // autoincrement PK на id
        let pk = try catalog.dbQueue.read { db in try db.primaryKey("playEvent").columns }
        #expect(pk == ["id"])
        // индекс на startedAt (выборки недавнего)
        let indexes = try catalog.dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'playEvent'"
            )
        }
        #expect(indexes.contains("playEvent_startedAt"))
    }

    @Test func migrationV6IsAdditiveKeepingExistingTracks() throws {
        // v6 не должна затрагивать `track`: строка, вставленная до применения
        // (эмулируем через свежую БД + запись), остаётся на месте.
        let catalog = try Catalog.inMemory()
        try catalog.dbQueue.write { db in
            try TrackRecord(relativePath: "a.flac", title: "А",
                            duration: 1, sampleRate: 44100).insert(db)
        }
        let count = try catalog.dbQueue.read { db in try TrackRecord.fetchCount(db) }
        #expect(count == 1)
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

    @Test func trackFromRecordCarriesAddedAt() throws {
        // Питает «Недавно добавленные»: addedAt строки каталога доходит до Track.
        let addedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let record = TrackRecord(relativePath: "a.flac", title: "А",
                                 duration: 1, sampleRate: 44100, addedAt: addedAt)

        let track = record.track(documentsURL: URL(fileURLWithPath: "/docs"))

        #expect(track.addedAt == addedAt)
    }

    @Test func trackFromCatalogRowCarriesAddedAt() throws {
        // Полный путь: строка в БД → fetch → маппинг в Track (как в LibraryStore).
        let catalog = try Catalog.inMemory()
        let addedAt = Date(timeIntervalSince1970: 1_750_000_000)
        try catalog.dbQueue.write { db in
            try TrackRecord(relativePath: "a.flac", title: "А", duration: 1,
                            sampleRate: 44100, addedAt: addedAt).insert(db)
        }

        let track = try CatalogStore(catalog: catalog)
            .allTracks(documentsURL: URL(fileURLWithPath: "/docs")).first

        #expect(track?.addedAt == addedAt)
    }

    @Test func trackDefaultsAddedAtToNilWhenConstructedDirectly() throws {
        let track = Track(url: URL(fileURLWithPath: "/docs/a.flac"),
                          title: "А", duration: 1, sampleRate: 44100)

        #expect(track.addedAt == nil)
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

    @Test func deleteTracksRemovesOnlyGivenRows() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try catalog.dbQueue.write { db in
            try TrackRecord(relativePath: "A/CD1/01.flac", title: "x", duration: 1, sampleRate: 44100).insert(db)
            try TrackRecord(relativePath: "A/CD1/02.flac", title: "y", duration: 1, sampleRate: 44100).insert(db)
            try TrackRecord(relativePath: "B/01.flac", title: "z", duration: 1, sampleRate: 44100).insert(db)
        }
        try store.deleteTracks(relativePaths: ["A/CD1/01.flac", "A/CD1/02.flac"])
        let count = try catalog.dbQueue.read { db in try TrackRecord.fetchCount(db) }
        #expect(count == 1)
        let survivor = try catalog.dbQueue.read { db in try TrackRecord.fetchOne(db, key: "B/01.flac") }
        #expect(survivor != nil)
    }

    @Test func deleteTracksEmptyIsNoOp() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try catalog.dbQueue.write { db in
            try TrackRecord(relativePath: "a.flac", title: "x", duration: 1, sampleRate: 44100).insert(db)
        }
        try store.deleteTracks(relativePaths: [])
        #expect(try catalog.dbQueue.read { db in try TrackRecord.fetchCount(db) } == 1)
    }

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
