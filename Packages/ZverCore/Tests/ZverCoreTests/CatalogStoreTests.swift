import Foundation
import Testing
@testable import ZverCore

@Suite struct CatalogStoreTests {
    private let documents = URL(fileURLWithPath: "/docs")

    private func record(path: String, title: String, artist: String? = nil,
                        album: String? = nil) -> TrackRecord {
        TrackRecord(relativePath: path, title: title, artist: artist, album: album,
                    duration: 1, sampleRate: 44100,
                    addedAt: Date(timeIntervalSince1970: 1_750_000_000))
    }

    // MARK: - reconcile

    @Test func reconcileInsertsNewTracks() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)

        try store.reconcile(scanned: [
            record(path: "b.flac", title: "Б"),
            record(path: "a.flac", title: "А"),
        ])

        let titles = try store.allTracks(documentsURL: documents).map(\.title)
        #expect(titles == ["А", "Б"])
    }

    @Test func reconcileUpdatesChangedTracks() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try store.reconcile(scanned: [record(path: "a.flac", title: "Старое имя")])

        try store.reconcile(scanned: [record(path: "a.flac", title: "Новое имя")])

        let tracks = try store.allTracks(documentsURL: documents)
        #expect(tracks.count == 1)
        #expect(tracks.first?.title == "Новое имя")
    }

    @Test func reconcileOfExistingPathPreservesOriginalAddedAt() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        let originalAddedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try store.reconcile(scanned: [
            TrackRecord(relativePath: "a.flac", title: "Старое имя",
                        duration: 1, sampleRate: 44100, addedAt: originalAddedAt)
        ])

        // Повторный рескан: маппинг сканера ставит дефолтный addedAt = Date(),
        // но дата добавления существующего трека не должна сбрасываться.
        try store.reconcile(scanned: [
            TrackRecord(relativePath: "a.flac", title: "Новое имя",
                        duration: 1, sampleRate: 44100)
        ])

        let stored = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "a.flac")
        }
        #expect(stored?.title == "Новое имя")
        #expect(stored?.addedAt == originalAddedAt)
    }

    @Test func reconcileDeletesMissingTracks() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try store.reconcile(scanned: [
            record(path: "a.flac", title: "А"),
            record(path: "b.flac", title: "Б"),
        ])

        // b.flac пропал из скана — файл удалён
        try store.reconcile(scanned: [record(path: "a.flac", title: "А")])

        let titles = try store.allTracks(documentsURL: documents).map(\.title)
        #expect(titles == ["А"])
    }

    @Test func reconcileWithEmptyScanDeletesEverything() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try store.reconcile(scanned: [record(path: "a.flac", title: "А")])

        try store.reconcile(scanned: [])

        #expect(try store.allTracks(documentsURL: documents).isEmpty)
    }

    @Test func reconcileKeepsMissingTrackWhenPredicateSaysFilePresent() throws {
        // a.flac есть на диске, но не прочитался при скане (например,
        // частично скопирован через file sharing) — запись не удаляется,
        // addedAt и плейлистные связи сохраняются. b.flac пропал
        // по-настоящему — удаляется как раньше.
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        let originalAddedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try store.reconcile(scanned: [
            TrackRecord(relativePath: "a.flac", title: "А",
                        duration: 1, sampleRate: 44100, addedAt: originalAddedAt),
            record(path: "b.flac", title: "Б"),
        ])
        try catalog.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO playlist (title, createdAt) VALUES ('Микс', ?)",
                           arguments: [Date()])
            try db.execute(
                sql: "INSERT INTO playlistTrack (playlistId, trackRelativePath, position) VALUES (1, 'a.flac', 0)"
            )
        }

        try store.reconcile(scanned: [], keepMissing: { $0 == "a.flac" })

        #expect(try store.allTracks(documentsURL: documents).map(\.title) == ["А"])
        let stored = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "a.flac")
        }
        #expect(stored?.addedAt == originalAddedAt)
        let memberships = try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlistTrack") ?? -1
        }
        #expect(memberships == 1)
    }

    @Test func reconcileDoesNotConsultPredicateForScannedPaths() throws {
        // keepMissing — только про отсутствующие в скане пути:
        // отсканированные записи обновляются обычным upsert'ом.
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try store.reconcile(scanned: [record(path: "a.flac", title: "Старое имя")])

        try store.reconcile(
            scanned: [record(path: "a.flac", title: "Новое имя")],
            keepMissing: { _ in
                Issue.record("keepMissing не должен вызываться для отсканированных путей")
                return true
            }
        )

        #expect(try store.allTracks(documentsURL: documents).map(\.title) == ["Новое имя"])
    }

    @Test func reconcileDeleteCascadesIntoPlaylistTrack() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try store.reconcile(scanned: [record(path: "a.flac", title: "А")])
        try catalog.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO playlist (title, createdAt) VALUES ('Микс', ?)",
                           arguments: [Date()])
            try db.execute(
                sql: "INSERT INTO playlistTrack (playlistId, trackRelativePath, position) VALUES (1, 'a.flac', 0)"
            )
        }

        try store.reconcile(scanned: [])

        let remaining = try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlistTrack") ?? -1
        }
        #expect(remaining == 0)
    }

    // MARK: - reconcile сохраняет облачные треки (этап 4)

    /// Хелпер: вставить запись с заданным fileState/cloudSha напрямую
    /// (минуя reconcile, который при upsert не трогает облачные поля).
    private func insert(_ record: TrackRecord, into catalog: Catalog) throws {
        try catalog.dbQueue.write { db in
            try record.insert(db)
        }
    }

    @Test func reconcileKeepsRemoteTrackAbsentFromScan() throws {
        // remote-трек физически отсутствует на диске (offload-нут) и потому
        // никогда не попадёт в скан. Он ОБЯЗАН пережить reconcile.
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try insert(
            TrackRecord(relativePath: "remote.flac", title: "Облачный",
                        duration: 1, sampleRate: 44100,
                        fileState: FileState.remote.rawValue, cloudSha: "abc"),
            into: catalog
        )

        // скан видит только локальный трек; remote.flac отсутствует
        try store.reconcile(scanned: [record(path: "local.flac", title: "Локальный")])

        let titles = try store.allTracks(documentsURL: documents).map(\.title)
        #expect(titles == ["Облачный", "Локальный"].sorted())
        let stored = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "remote.flac")
        }
        #expect(stored?.fileState == FileState.remote.rawValue)
        #expect(stored?.cloudSha == "abc")
    }

    @Test func reconcileKeepsBackedUpAndDownloadingAndCloudShaTracksAbsentFromScan() throws {
        // backedUp/downloading или любой трек с непустым cloudSha сохраняется
        // при отсутствии в скане — он либо намеренно в облаке, либо в передаче.
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try insert(TrackRecord(relativePath: "backed.flac", title: "Бэкап",
                               duration: 1, sampleRate: 44100,
                               fileState: FileState.backedUp.rawValue, cloudSha: "s1"),
                   into: catalog)
        try insert(TrackRecord(relativePath: "down.flac", title: "Качается",
                               duration: 1, sampleRate: 44100,
                               fileState: FileState.downloading.rawValue, cloudSha: "s2"),
                   into: catalog)
        // local с cloudSha (подтверждён в облаке) тоже не удаляется
        try insert(TrackRecord(relativePath: "localcloud.flac", title: "ЛокалОблако",
                               duration: 1, sampleRate: 44100,
                               fileState: FileState.local.rawValue, cloudSha: "s3"),
                   into: catalog)

        try store.reconcile(scanned: [])

        let titles = try store.allTracks(documentsURL: documents).map(\.title).sorted()
        #expect(titles == ["Бэкап", "ЛокалОблако", "Качается"].sorted())
    }

    @Test func reconcileDeletesLocalTrackWithMissingFile() throws {
        // Чисто локальный трек (cloudSha==nil, fileState=local) с пропавшим
        // файлом и keepMissing=false удаляется, как раньше.
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try store.reconcile(scanned: [
            record(path: "a.flac", title: "А"),
            record(path: "gone.flac", title: "Пропал"),
        ])

        try store.reconcile(scanned: [record(path: "a.flac", title: "А")])

        #expect(try store.allTracks(documentsURL: documents).map(\.title) == ["А"])
    }

    @Test func reconcileDeletesUploadingTrackWithoutCloudShaAndMissingFile() throws {
        // uploading + cloudSha==nil (выгрузка не подтверждена) — НЕ облачный,
        // удаляется при отсутствии файла и keepMissing=false.
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try insert(TrackRecord(relativePath: "up.flac", title: "Грузится",
                               duration: 1, sampleRate: 44100,
                               fileState: FileState.uploading.rawValue, cloudSha: nil),
                   into: catalog)

        try store.reconcile(scanned: [])

        #expect(try store.allTracks(documentsURL: documents).isEmpty)
    }

    @Test func reconcileDoesNotOverwriteBackedUpFieldsOnUpsert() throws {
        // backedUp-трек, файл на месте и в скане есть — upsert НЕ сбрасывает
        // fileState/cloudSha/addedAt на дефолты скана.
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        let originalAddedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try insert(TrackRecord(relativePath: "a.flac", title: "Старое имя",
                               duration: 1, sampleRate: 44100, addedAt: originalAddedAt,
                               fileState: FileState.backedUp.rawValue, cloudSha: "sha-xyz"),
                   into: catalog)

        // скан возвращает дефолтную запись (fileState=local, cloudSha=nil,
        // addedAt=Date()) с обновлённым названием
        try store.reconcile(scanned: [
            TrackRecord(relativePath: "a.flac", title: "Новое имя",
                        duration: 1, sampleRate: 44100)
        ])

        let stored = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "a.flac")
        }
        #expect(stored?.title == "Новое имя")
        #expect(stored?.fileState == FileState.backedUp.rawValue)
        #expect(stored?.cloudSha == "sha-xyz")
        #expect(stored?.addedAt == originalAddedAt)
    }

    // MARK: - setFileState / markBackedUp

    @Test func setFileStateUpdatesStateOnly() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try insert(TrackRecord(relativePath: "a.flac", title: "А",
                               duration: 1, sampleRate: 44100,
                               fileState: FileState.local.rawValue, cloudSha: "keep"),
                   into: catalog)

        try store.setFileState(relativePath: "a.flac", .uploading)

        let stored = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "a.flac")
        }
        #expect(stored?.fileState == FileState.uploading.rawValue)
        // cloudSha не передан — не трогаем
        #expect(stored?.cloudSha == "keep")
    }

    @Test func setFileStateWritesCloudShaWhenProvided() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try insert(TrackRecord(relativePath: "a.flac", title: "А",
                               duration: 1, sampleRate: 44100),
                   into: catalog)

        try store.setFileState(relativePath: "a.flac", .remote, cloudSha: "new-sha")

        let stored = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "a.flac")
        }
        #expect(stored?.fileState == FileState.remote.rawValue)
        #expect(stored?.cloudSha == "new-sha")
    }

    @Test func setFileStateIsIdempotent() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try insert(TrackRecord(relativePath: "a.flac", title: "А",
                               duration: 1, sampleRate: 44100),
                   into: catalog)

        try store.setFileState(relativePath: "a.flac", .uploading)
        try store.setFileState(relativePath: "a.flac", .uploading)

        let stored = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "a.flac")
        }
        #expect(stored?.fileState == FileState.uploading.rawValue)
    }

    @Test func setFileStateOnMissingPathIsNoOp() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)

        // не должно бросать и не должно ничего создавать
        try store.setFileState(relativePath: "ghost.flac", .uploading)

        #expect(try store.allTracks(documentsURL: documents).isEmpty)
    }

    @Test func markBackedUpSetsStateAndCloudSha() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try insert(TrackRecord(relativePath: "a.flac", title: "А",
                               duration: 1, sampleRate: 44100,
                               fileState: FileState.uploading.rawValue),
                   into: catalog)

        try store.markBackedUp(relativePath: "a.flac", cloudSha: "verified")

        let stored = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "a.flac")
        }
        #expect(stored?.fileState == FileState.backedUp.rawValue)
        #expect(stored?.cloudSha == "verified")
    }

    @Test func markBackedUpIsIdempotent() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try insert(TrackRecord(relativePath: "a.flac", title: "А",
                               duration: 1, sampleRate: 44100,
                               fileState: FileState.uploading.rawValue),
                   into: catalog)

        try store.markBackedUp(relativePath: "a.flac", cloudSha: "verified")
        try store.markBackedUp(relativePath: "a.flac", cloudSha: "verified")

        let stored = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "a.flac")
        }
        #expect(stored?.fileState == FileState.backedUp.rawValue)
        #expect(stored?.cloudSha == "verified")
    }

    // MARK: - tracksAwaitingBackup / tracks(inState:)

    @Test func tracksAwaitingBackupSelectsLocalWithoutCloudSha() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try insert(TrackRecord(relativePath: "a.flac", title: "Кандидат",
                               duration: 1, sampleRate: 44100,
                               fileState: FileState.local.rawValue, cloudSha: nil),
                   into: catalog)
        // local но с cloudSha — уже подтверждён, не кандидат
        try insert(TrackRecord(relativePath: "b.flac", title: "Уже в облаке",
                               duration: 1, sampleRate: 44100,
                               fileState: FileState.local.rawValue, cloudSha: "s"),
                   into: catalog)
        // uploading — не local, не кандидат
        try insert(TrackRecord(relativePath: "c.flac", title: "Грузится",
                               duration: 1, sampleRate: 44100,
                               fileState: FileState.uploading.rawValue, cloudSha: nil),
                   into: catalog)
        // backedUp — не кандидат
        try insert(TrackRecord(relativePath: "d.flac", title: "Бэкап",
                               duration: 1, sampleRate: 44100,
                               fileState: FileState.backedUp.rawValue, cloudSha: "s"),
                   into: catalog)

        let awaiting = try store.tracksAwaitingBackup()

        #expect(awaiting.map(\.relativePath) == ["a.flac"])
    }

    @Test func tracksInStateFiltersByFileState() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try insert(TrackRecord(relativePath: "a.flac", title: "remote1",
                               duration: 1, sampleRate: 44100,
                               fileState: FileState.remote.rawValue, cloudSha: "s"),
                   into: catalog)
        try insert(TrackRecord(relativePath: "b.flac", title: "local1",
                               duration: 1, sampleRate: 44100,
                               fileState: FileState.local.rawValue),
                   into: catalog)
        try insert(TrackRecord(relativePath: "c.flac", title: "remote2",
                               duration: 1, sampleRate: 44100,
                               fileState: FileState.remote.rawValue, cloudSha: "s2"),
                   into: catalog)

        let remotes = try store.tracks(inState: .remote).map(\.title).sorted()
        #expect(remotes == ["remote1", "remote2"])
        #expect(try store.tracks(inState: .local).map(\.title) == ["local1"])
        #expect(try store.tracks(inState: .uploading).isEmpty)
    }

    // MARK: - importRemoteCatalog

    @Test func importRemoteCatalogCreatesRemoteRecords() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)

        // записи из скачанного бэкапа несут cloudSha; локального файла нет
        try store.importRemoteCatalog(records: [
            TrackRecord(relativePath: "alb/1.flac", title: "Первый",
                        duration: 1, sampleRate: 44100,
                        fileState: FileState.backedUp.rawValue, cloudSha: "h1"),
            TrackRecord(relativePath: "alb/2.flac", title: "Второй",
                        duration: 1, sampleRate: 44100,
                        fileState: FileState.remote.rawValue, cloudSha: "h2"),
        ])

        let tracks = try store.tracks(inState: .remote).map(\.title).sorted()
        #expect(tracks == ["Второй", "Первый"])
        let stored = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "alb/1.flac")
        }
        #expect(stored?.cloudSha == "h1")
    }

    @Test func importRemoteCatalogDoesNotDegradeExistingLocalTracks() throws {
        // Существующая локальная строка не должна деградировать до remote
        // при импорте (конфликт в пользу «есть локально»).
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try insert(TrackRecord(relativePath: "alb/1.flac", title: "Локальный",
                               duration: 1, sampleRate: 44100,
                               fileState: FileState.local.rawValue, cloudSha: nil),
                   into: catalog)
        try insert(TrackRecord(relativePath: "alb/2.flac", title: "Бэкап локально",
                               duration: 1, sampleRate: 44100,
                               fileState: FileState.backedUp.rawValue, cloudSha: "have"),
                   into: catalog)

        try store.importRemoteCatalog(records: [
            TrackRecord(relativePath: "alb/1.flac", title: "Из бэкапа",
                        duration: 1, sampleRate: 44100,
                        fileState: FileState.remote.rawValue, cloudSha: "h1"),
            TrackRecord(relativePath: "alb/2.flac", title: "Из бэкапа 2",
                        duration: 1, sampleRate: 44100,
                        fileState: FileState.remote.rawValue, cloudSha: "h2"),
            TrackRecord(relativePath: "alb/3.flac", title: "Новый из бэкапа",
                        duration: 1, sampleRate: 44100,
                        fileState: FileState.backedUp.rawValue, cloudSha: "h3"),
        ])

        let one = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "alb/1.flac")
        }
        // локальный остаётся local (не деградирует до remote)
        #expect(one?.fileState == FileState.local.rawValue)
        let two = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "alb/2.flac")
        }
        #expect(two?.fileState == FileState.backedUp.rawValue)
        // новый из бэкапа без локального файла становится remote
        let three = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "alb/3.flac")
        }
        #expect(three?.fileState == FileState.remote.rawValue)
        #expect(three?.cloudSha == "h3")
    }

    // MARK: - allTracks

    @Test func allTracksSortedByRelativePathAndResolvedAgainstDocuments() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try store.reconcile(scanned: [
            record(path: "Зверь/02 Вторая.flac", title: "Вторая"),
            record(path: "Аврора/01 Рассвет.flac", title: "Рассвет"),
        ])

        let tracks = try store.allTracks(documentsURL: documents)

        #expect(tracks.map(\.title) == ["Рассвет", "Вторая"])
        #expect(tracks.first?.url.path == "/docs/Аврора/01 Рассвет.flac")
    }

    // MARK: - search

    @Test func searchFindsSubstringIgnoringCaseInLatin() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try store.reconcile(scanned: [
            record(path: "a.flac", title: "Daydream Nation"),
            record(path: "b.flac", title: "Другое"),
        ])

        let found = try store.search("DREAM", documentsURL: documents)

        #expect(found.map(\.title) == ["Daydream Nation"])
    }

    @Test func searchFindsCyrillicIgnoringCase() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try store.reconcile(scanned: [
            record(path: "a.flac", title: "Зверь"),
            record(path: "b.flac", title: "Другое"),
        ])

        // SQLite LOWER/LIKE не справились бы с кириллицей — фильтр в Swift
        let found = try store.search("зверь", documentsURL: documents)

        #expect(found.map(\.title) == ["Зверь"])
    }

    @Test func searchMatchesArtistAndAlbum() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try store.reconcile(scanned: [
            record(path: "a.flac", title: "Трек 1", artist: "Аня", album: "Аврора"),
            record(path: "b.flac", title: "Трек 2", artist: "Борис", album: "Закат"),
        ])

        #expect(try store.search("аня", documentsURL: documents).map(\.title) == ["Трек 1"])
        #expect(try store.search("закат", documentsURL: documents).map(\.title) == ["Трек 2"])
    }

    @Test func searchEmptyOrWhitespaceQueryReturnsEmpty() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try store.reconcile(scanned: [record(path: "a.flac", title: "Зверь")])

        #expect(try store.search("", documentsURL: documents).isEmpty)
        #expect(try store.search("   ", documentsURL: documents).isEmpty)
    }

    @Test func searchWithNoMatchesReturnsEmpty() throws {
        let catalog = try Catalog.inMemory()
        let store = CatalogStore(catalog: catalog)
        try store.reconcile(scanned: [record(path: "a.flac", title: "Зверь")])

        #expect(try store.search("несуществующее", documentsURL: documents).isEmpty)
    }
}
