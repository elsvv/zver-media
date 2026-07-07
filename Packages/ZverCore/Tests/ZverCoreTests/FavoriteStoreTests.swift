import Foundation
import Testing
@testable import ZverCore

@Suite struct FavoriteStoreTests {
    private func makeStore() throws -> (Catalog, FavoriteStore) {
        let catalog = try Catalog.inMemory()
        return (catalog, FavoriteStore(catalog: catalog))
    }

    // MARK: - setFavorite / isFavorite

    @Test func setFavoriteMarksEntity() throws {
        let (_, store) = try makeStore()

        try store.setFavorite(kind: .track, key: "a.flac", isFavorite: true)

        #expect(try store.isFavorite(kind: .track, key: "a.flac"))
    }

    @Test func unsetFavoriteRemovesMark() throws {
        let (_, store) = try makeStore()
        try store.setFavorite(kind: .track, key: "a.flac", isFavorite: true)

        try store.setFavorite(kind: .track, key: "a.flac", isFavorite: false)

        #expect(try !store.isFavorite(kind: .track, key: "a.flac"))
    }

    @Test func isFavoriteFalseForUnknownKey() throws {
        let (_, store) = try makeStore()

        #expect(try !store.isFavorite(kind: .track, key: "нет-такого"))
    }

    @Test func trackAndAlbumKindsAreIndependent() throws {
        let (_, store) = try makeStore()

        // одинаковый ключ, но разные виды — не пересекаются
        try store.setFavorite(kind: .album, key: "/music/Aurora", isFavorite: true)

        #expect(try store.isFavorite(kind: .album, key: "/music/Aurora"))
        #expect(try !store.isFavorite(kind: .track, key: "/music/Aurora"))
    }

    // MARK: - Идемпотентность

    @Test func setFavoriteTwiceIsIdempotentAndKeepsFirstCreatedAt() throws {
        let (_, store) = try makeStore()

        try store.setFavorite(kind: .album, key: "/music/X", isFavorite: true)
        let firstCreatedAt = try store.favorites(kind: .album).first?.createdAt
        try store.setFavorite(kind: .album, key: "/music/X", isFavorite: true)

        let all = try store.favorites(kind: .album)
        #expect(all.count == 1)
        #expect(all.first?.createdAt == firstCreatedAt)   // createdAt первой отметки сохранён
    }

    @Test func unsetUnknownFavoriteIsNoOp() throws {
        let (_, store) = try makeStore()
        try store.setFavorite(kind: .track, key: "a.flac", isFavorite: true)

        try store.setFavorite(kind: .track, key: "нет-такого", isFavorite: false)

        #expect(try store.favoriteKeys(kind: .track) == ["a.flac"])
    }

    // MARK: - favorites (порядок) / favoriteKeys

    @Test func favoritesReturnNewestFirst() throws {
        let (catalog, store) = try makeStore()
        // Вставляем с явными createdAt, чтобы порядок был детерминирован
        // (у setFavorite время = Date(), в одну мс тай-брейк по ключу).
        try insertFavorite(catalog, kind: .album, key: "старый", createdAt: 1_000)
        try insertFavorite(catalog, kind: .album, key: "средний", createdAt: 2_000)
        try insertFavorite(catalog, kind: .album, key: "новый", createdAt: 3_000)

        let keys = try store.favorites(kind: .album).map(\.key)

        #expect(keys == ["новый", "средний", "старый"])
    }

    @Test func favoritesFilterByKind() throws {
        let (_, store) = try makeStore()
        try store.setFavorite(kind: .track, key: "t.flac", isFavorite: true)
        try store.setFavorite(kind: .album, key: "/music/A", isFavorite: true)

        #expect(try store.favorites(kind: .track).map(\.key) == ["t.flac"])
        #expect(try store.favorites(kind: .album).map(\.key) == ["/music/A"])
    }

    @Test func favoriteKeysReturnsSetOfKind() throws {
        let (_, store) = try makeStore()
        try store.setFavorite(kind: .track, key: "a.flac", isFavorite: true)
        try store.setFavorite(kind: .track, key: "b.flac", isFavorite: true)
        try store.setFavorite(kind: .album, key: "/music/A", isFavorite: true)

        #expect(try store.favoriteKeys(kind: .track) == ["a.flac", "b.flac"])
        #expect(try store.favoriteKeys(kind: .album) == ["/music/A"])
    }

    @Test func favoriteKeysEmptyWhenNoneOfKind() throws {
        let (_, store) = try makeStore()
        try store.setFavorite(kind: .track, key: "a.flac", isFavorite: true)

        #expect(try store.favoriteKeys(kind: .album).isEmpty)
    }

    // Прямая вставка с контролируемым createdAt — тестируем порядок выборки
    // независимо от разрешения часов (setFavorite ставит Date()).
    private func insertFavorite(_ catalog: Catalog, kind: FavoriteKind,
                                key: String, createdAt seconds: TimeInterval) throws {
        try catalog.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO favorite (entityKind, entityKey, createdAt) VALUES (?, ?, ?)",
                arguments: [kind.rawValue, key, Date(timeIntervalSince1970: seconds)]
            )
        }
    }
}
