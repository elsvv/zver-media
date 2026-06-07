import Foundation
import Testing
@testable import ZverCore

@Suite struct PlaylistStoreTests {
    private let documents = URL(fileURLWithPath: "/docs")

    /// Каталог с треками a/b/c.flac — playlistTrack ссылается на track (FK),
    /// поэтому треки должны существовать до добавления в плейлист.
    private func makeStores(paths: [String] = ["a.flac", "b.flac", "c.flac"])
        throws -> (Catalog, PlaylistStore) {
        let catalog = try Catalog.inMemory()
        try CatalogStore(catalog: catalog).reconcile(scanned: paths.map {
            TrackRecord(relativePath: $0, title: $0, duration: 1, sampleRate: 44100,
                        addedAt: Date(timeIntervalSince1970: 1_750_000_000))
        })
        return (catalog, PlaylistStore(catalog: catalog))
    }

    private func positions(_ catalog: Catalog, playlistId: Int64) throws -> [Int] {
        try catalog.dbQueue.read { db in
            try Int.fetchAll(
                db,
                sql: "SELECT position FROM playlistTrack WHERE playlistId = ? ORDER BY position",
                arguments: [playlistId]
            )
        }
    }

    // MARK: - createPlaylist / allPlaylists

    @Test func createPlaylistReturnsPlaylistWithIdAndTitle() throws {
        let (_, store) = try makeStores()

        let playlist = try store.createPlaylist(title: "Микс")

        #expect(playlist.id > 0)
        #expect(playlist.title == "Микс")
    }

    @Test func allPlaylistsReturnsInCreationOrder() throws {
        let (_, store) = try makeStores()

        let first = try store.createPlaylist(title: "Первый")
        let second = try store.createPlaylist(title: "Второй")
        let third = try store.createPlaylist(title: "Третий")

        let all = try store.allPlaylists()
        #expect(all.map(\.id) == [first.id, second.id, third.id])
        #expect(all.map(\.title) == ["Первый", "Второй", "Третий"])
    }

    @Test func allPlaylistsOnEmptyCatalogReturnsEmpty() throws {
        let (_, store) = try makeStores()

        #expect(try store.allPlaylists().isEmpty)
    }

    // MARK: - renamePlaylist

    @Test func renamePlaylistChangesTitle() throws {
        let (_, store) = try makeStores()
        let playlist = try store.createPlaylist(title: "Старое имя")

        try store.renamePlaylist(id: playlist.id, title: "Новое имя")

        #expect(try store.allPlaylists().map(\.title) == ["Новое имя"])
    }

    // MARK: - deletePlaylist

    @Test func deletePlaylistRemovesPlaylistAndItsTrackLinks() throws {
        let (catalog, store) = try makeStores()
        let playlist = try store.createPlaylist(title: "Микс")
        try store.add(trackPath: "a.flac", to: playlist.id)
        try store.add(trackPath: "b.flac", to: playlist.id)

        try store.deletePlaylist(id: playlist.id)

        #expect(try store.allPlaylists().isEmpty)
        let remainingLinks = try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlistTrack") ?? -1
        }
        #expect(remainingLinks == 0)
    }

    @Test func deletePlaylistKeepsOtherPlaylistsIntact() throws {
        let (_, store) = try makeStores()
        let doomed = try store.createPlaylist(title: "Лишний")
        let kept = try store.createPlaylist(title: "Нужный")
        try store.add(trackPath: "a.flac", to: kept.id)

        try store.deletePlaylist(id: doomed.id)

        #expect(try store.allPlaylists().map(\.title) == ["Нужный"])
        #expect(try store.tracks(in: kept.id, documentsURL: documents).map(\.title) == ["a.flac"])
    }

    // MARK: - add / tracks

    @Test func addAppendsTracksInOrder() throws {
        let (_, store) = try makeStores()
        let playlist = try store.createPlaylist(title: "Микс")

        try store.add(trackPath: "b.flac", to: playlist.id)
        try store.add(trackPath: "a.flac", to: playlist.id)
        try store.add(trackPath: "c.flac", to: playlist.id)

        let titles = try store.tracks(in: playlist.id, documentsURL: documents).map(\.title)
        #expect(titles == ["b.flac", "a.flac", "c.flac"])
    }

    @Test func addDuplicateIsIgnored() throws {
        let (_, store) = try makeStores()
        let playlist = try store.createPlaylist(title: "Микс")
        try store.add(trackPath: "a.flac", to: playlist.id)
        try store.add(trackPath: "b.flac", to: playlist.id)

        try store.add(trackPath: "a.flac", to: playlist.id)

        let titles = try store.tracks(in: playlist.id, documentsURL: documents).map(\.title)
        #expect(titles == ["a.flac", "b.flac"])
    }

    @Test func tracksResolveURLsAgainstDocuments() throws {
        let (_, store) = try makeStores()
        let playlist = try store.createPlaylist(title: "Микс")
        try store.add(trackPath: "a.flac", to: playlist.id)

        let tracks = try store.tracks(in: playlist.id, documentsURL: documents)

        #expect(tracks.first?.url.path == "/docs/a.flac")
    }

    @Test func tracksInEmptyPlaylistReturnsEmpty() throws {
        let (_, store) = try makeStores()
        let playlist = try store.createPlaylist(title: "Пустой")

        #expect(try store.tracks(in: playlist.id, documentsURL: documents).isEmpty)
    }

    // MARK: - remove

    @Test func removeKeepsOrderAndRenumbersPositions() throws {
        let (catalog, store) = try makeStores()
        let playlist = try store.createPlaylist(title: "Микс")
        try store.add(trackPath: "a.flac", to: playlist.id)
        try store.add(trackPath: "b.flac", to: playlist.id)
        try store.add(trackPath: "c.flac", to: playlist.id)

        try store.remove(trackPath: "b.flac", from: playlist.id)

        let titles = try store.tracks(in: playlist.id, documentsURL: documents).map(\.title)
        #expect(titles == ["a.flac", "c.flac"])
        #expect(try positions(catalog, playlistId: playlist.id) == [0, 1])
    }

    @Test func addAfterRemoveAppendsToEnd() throws {
        let (_, store) = try makeStores()
        let playlist = try store.createPlaylist(title: "Микс")
        try store.add(trackPath: "a.flac", to: playlist.id)
        try store.add(trackPath: "b.flac", to: playlist.id)
        try store.remove(trackPath: "a.flac", from: playlist.id)

        try store.add(trackPath: "c.flac", to: playlist.id)

        let titles = try store.tracks(in: playlist.id, documentsURL: documents).map(\.title)
        #expect(titles == ["b.flac", "c.flac"])
    }

    // MARK: - move

    @Test func moveToStartReordersAndRenumbers() throws {
        let (catalog, store) = try makeStores()
        let playlist = try store.createPlaylist(title: "Микс")
        try store.add(trackPath: "a.flac", to: playlist.id)
        try store.add(trackPath: "b.flac", to: playlist.id)
        try store.add(trackPath: "c.flac", to: playlist.id)

        try store.move(trackPath: "c.flac", in: playlist.id, to: 0)

        let titles = try store.tracks(in: playlist.id, documentsURL: documents).map(\.title)
        #expect(titles == ["c.flac", "a.flac", "b.flac"])
        #expect(try positions(catalog, playlistId: playlist.id) == [0, 1, 2])
    }

    @Test func moveToMiddleReorders() throws {
        let (_, store) = try makeStores()
        let playlist = try store.createPlaylist(title: "Микс")
        try store.add(trackPath: "a.flac", to: playlist.id)
        try store.add(trackPath: "b.flac", to: playlist.id)
        try store.add(trackPath: "c.flac", to: playlist.id)

        try store.move(trackPath: "a.flac", in: playlist.id, to: 1)

        let titles = try store.tracks(in: playlist.id, documentsURL: documents).map(\.title)
        #expect(titles == ["b.flac", "a.flac", "c.flac"])
    }

    @Test func moveBeyondEndClampsToLastPosition() throws {
        let (_, store) = try makeStores()
        let playlist = try store.createPlaylist(title: "Микс")
        try store.add(trackPath: "a.flac", to: playlist.id)
        try store.add(trackPath: "b.flac", to: playlist.id)
        try store.add(trackPath: "c.flac", to: playlist.id)

        try store.move(trackPath: "a.flac", in: playlist.id, to: 99)

        let titles = try store.tracks(in: playlist.id, documentsURL: documents).map(\.title)
        #expect(titles == ["b.flac", "c.flac", "a.flac"])
    }

    @Test func moveOfUnknownTrackIsNoOp() throws {
        let (_, store) = try makeStores()
        let playlist = try store.createPlaylist(title: "Микс")
        try store.add(trackPath: "a.flac", to: playlist.id)
        try store.add(trackPath: "b.flac", to: playlist.id)

        try store.move(trackPath: "нет-такого.flac", in: playlist.id, to: 0)

        let titles = try store.tracks(in: playlist.id, documentsURL: documents).map(\.title)
        #expect(titles == ["a.flac", "b.flac"])
    }

    // MARK: - каскад из каталога

    @Test func reconcileRemovingTrackFromCatalogRemovesItFromPlaylists() throws {
        let (catalog, store) = try makeStores()
        let playlist = try store.createPlaylist(title: "Микс")
        try store.add(trackPath: "a.flac", to: playlist.id)
        try store.add(trackPath: "b.flac", to: playlist.id)
        try store.add(trackPath: "c.flac", to: playlist.id)

        // b.flac пропал из скана — файл удалён, каскад чистит плейлисты
        try CatalogStore(catalog: catalog).reconcile(scanned: ["a.flac", "c.flac"].map {
            TrackRecord(relativePath: $0, title: $0, duration: 1, sampleRate: 44100,
                        addedAt: Date(timeIntervalSince1970: 1_750_000_000))
        })

        let titles = try store.tracks(in: playlist.id, documentsURL: documents).map(\.title)
        #expect(titles == ["a.flac", "c.flac"])
    }
}
