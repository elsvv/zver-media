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
