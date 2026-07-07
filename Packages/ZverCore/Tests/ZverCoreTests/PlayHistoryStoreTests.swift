import Foundation
import Testing
@testable import ZverCore

@Suite struct PlayHistoryStoreTests {
    private func makeStore() throws -> PlayHistoryStore {
        PlayHistoryStore(catalog: try Catalog.inMemory())
    }

    /// Событие с удобными дефолтами. `at` — секунды epoch (порядок во времени).
    private func event(_ trackKey: String, title: String? = nil, artist: String? = nil,
                       album: String? = nil, albumKey: String? = nil,
                       at seconds: TimeInterval, played: Double = 200,
                       duration: Double = 200,
                       endReason: PlayEndReason = .finished) -> PlayEvent {
        PlayEvent(trackKey: trackKey, title: title ?? trackKey, artist: artist,
                  album: album, albumKey: albumKey,
                  startedAt: Date(timeIntervalSince1970: seconds),
                  playedSeconds: played, trackDuration: duration, endReason: endReason)
    }

    // MARK: - record / recentEvents

    @Test func recordThenRecentReturnsEvent() throws {
        let store = try makeStore()

        try store.record(event("a.flac", artist: "Аня", at: 1_000))

        let recent = try store.recentEvents(limit: 10)
        #expect(recent.count == 1)
        #expect(recent.first?.trackKey == "a.flac")
        #expect(recent.first?.artist == "Аня")
        #expect(recent.first?.endReason == .finished)
        #expect(recent.first?.id != nil)   // autoincrement присвоил id
    }

    @Test func recentEventsAreNewestFirst() throws {
        let store = try makeStore()
        try store.record(event("first", at: 1_000))
        try store.record(event("second", at: 2_000))
        try store.record(event("third", at: 3_000))

        let keys = try store.recentEvents(limit: 10).map(\.trackKey)

        #expect(keys == ["third", "second", "first"])
    }

    @Test func recentEventsRespectsLimit() throws {
        let store = try makeStore()
        for i in 0..<5 { try store.record(event("t\(i)", at: TimeInterval(1_000 + i))) }

        #expect(try store.recentEvents(limit: 2).count == 2)
    }

    @Test func recordPreservesEndReasons() throws {
        let store = try makeStore()
        try store.record(event("f", at: 1_000, endReason: .finished))
        try store.record(event("s", at: 2_000, endReason: .skipped))
        try store.record(event("x", at: 3_000, endReason: .stopped))

        let reasons = try store.recentEvents(limit: 10).map(\.endReason)
        #expect(reasons == [.stopped, .skipped, .finished])
    }

    // MARK: - recentAlbumKeys

    @Test func recentAlbumKeysAreDistinctByLatestEvent() throws {
        let store = try makeStore()
        // Альбом A слушали дважды; B — один раз, но позже A-1 и раньше A-2.
        try store.record(event("a1", albumKey: "/A", at: 1_000))
        try store.record(event("b1", albumKey: "/B", at: 2_000))
        try store.record(event("a2", albumKey: "/A", at: 3_000))

        let keys = try store.recentAlbumKeys(limit: 10)

        // A различается один раз, по последнему событию (t=3000) — впереди B (t=2000).
        #expect(keys == ["/A", "/B"])
    }

    @Test func recentAlbumKeysSkipNilAlbum() throws {
        let store = try makeStore()
        try store.record(event("loose", albumKey: nil, at: 1_000))
        try store.record(event("a1", albumKey: "/A", at: 2_000))

        #expect(try store.recentAlbumKeys(limit: 10) == ["/A"])
    }

    @Test func recentAlbumKeysRespectsLimit() throws {
        let store = try makeStore()
        try store.record(event("a", albumKey: "/A", at: 1_000))
        try store.record(event("b", albumKey: "/B", at: 2_000))
        try store.record(event("c", albumKey: "/C", at: 3_000))

        #expect(try store.recentAlbumKeys(limit: 2) == ["/C", "/B"])
    }

    // MARK: - isListened (граничные случаи)

    @Test func isListenedThirtySecondFloor() {
        // ≥30с абсолютных (длинный трек, 50% недостижимы): 29с — нет, 30с — да.
        #expect(!PlayHistoryStore.isListened(playedSeconds: 29, trackDuration: 300))
        #expect(PlayHistoryStore.isListened(playedSeconds: 30, trackDuration: 300))
    }

    @Test func isListenedHalfDurationFloor() {
        // Короткий трек (40с, порог 50% = 20с ниже абсолютных 30с):
        // 49% (19.6с) — нет, 50% (20с) — да.
        #expect(!PlayHistoryStore.isListened(playedSeconds: 19.6, trackDuration: 40))
        #expect(PlayHistoryStore.isListened(playedSeconds: 20, trackDuration: 40))
    }

    // MARK: - listeningStats

    @Test func listeningStatsCountsOnlyListenedEvents() throws {
        let store = try makeStore()
        // Аня: 2 прослушанных (по 200с) + 1 скип (5с) — счёт должен быть 2.
        try store.record(event("a1", artist: "Аня", album: "Aurora", albumKey: "/Aurora",
                               at: 1_000, played: 200, duration: 200))
        try store.record(event("a2", artist: "Аня", album: "Aurora", albumKey: "/Aurora",
                               at: 2_000, played: 200, duration: 200))
        try store.record(event("a3", artist: "Аня", album: "Aurora", albumKey: "/Aurora",
                               at: 3_000, played: 5, duration: 200, endReason: .skipped))

        let stats = try store.listeningStats(since: Date(timeIntervalSince1970: 0))

        #expect(stats.artists == [.init(artist: "Аня", count: 2)])
        #expect(stats.albums.count == 1)
        #expect(stats.albums.first?.albumKey == "/Aurora")
        #expect(stats.albums.first?.album == "Aurora")
        #expect(stats.albums.first?.artist == "Аня")
        #expect(stats.albums.first?.count == 2)
    }

    @Test func listeningStatsRespectsSinceCutoff() throws {
        let store = try makeStore()
        try store.record(event("old", artist: "Old", at: 1_000))
        try store.record(event("new", artist: "New", at: 5_000))

        let stats = try store.listeningStats(since: Date(timeIntervalSince1970: 4_000))

        #expect(stats.artists.map(\.artist) == ["New"])
    }

    @Test func listeningStatsMergesCaseInsensitiveArtists() throws {
        let store = try makeStore()
        // Один артист в двух написаниях "The"/"the" — объединяются по ключу.
        // Написание-большинство ("The", 2 из 3) становится каноном.
        let a = "King Gizzard & The lizard wizard"
        let b = "King Gizzard & the lizard wizard"
        try store.record(event("t1", artist: a, at: 1_000))
        try store.record(event("t2", artist: a, at: 2_000))
        try store.record(event("t3", artist: b, at: 3_000))

        let stats = try store.listeningStats(since: Date(timeIntervalSince1970: 0))

        #expect(stats.artists.count == 1)
        #expect(stats.artists.first?.artist == a)   // канон = большинство
        #expect(stats.artists.first?.count == 3)
    }

    @Test func listeningStatsIgnoresTracksWithoutArtist() throws {
        let store = try makeStore()
        try store.record(event("loose", artist: nil, at: 1_000))
        try store.record(event("named", artist: "Аня", at: 2_000))

        let stats = try store.listeningStats(since: Date(timeIntervalSince1970: 0))

        // трек без артиста не порождает артиста в агрегате
        #expect(stats.artists.map(\.artist) == ["Аня"])
    }

    @Test func listeningStatsSortsArtistsByCountDescending() throws {
        let store = try makeStore()
        try store.record(event("b1", artist: "Боб", at: 1_000))
        try store.record(event("a1", artist: "Аня", at: 2_000))
        try store.record(event("a2", artist: "Аня", at: 3_000))

        let stats = try store.listeningStats(since: Date(timeIntervalSince1970: 0))

        #expect(stats.artists.map(\.artist) == ["Аня", "Боб"])   // 2 > 1
        #expect(stats.artists.map(\.count) == [2, 1])
    }

    @Test func listeningStatsEmptyWhenNothingListened() throws {
        let store = try makeStore()
        try store.record(event("skip", artist: "Аня", at: 1_000, played: 5, duration: 200,
                               endReason: .skipped))

        let stats = try store.listeningStats(since: Date(timeIntervalSince1970: 0))

        #expect(stats.artists.isEmpty)
        #expect(stats.albums.isEmpty)
    }
}
