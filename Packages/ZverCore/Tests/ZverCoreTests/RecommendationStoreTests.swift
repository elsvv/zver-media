import Foundation
import GRDB
import Testing
@testable import ZverCore

@Suite struct RecommendationStoreTests {
    private func makeStore() throws -> (store: RecommendationStore, catalog: Catalog) {
        let catalog = try Catalog.inMemory()
        return (RecommendationStore(catalog: catalog), catalog)
    }

    /// Рекомендация с удобными дефолтами. `at` — секунды epoch (порядок во времени).
    private func rec(_ artist: String, _ album: String,
                     category: String? = "missed-classics", reason: String? = nil,
                     at seconds: TimeInterval) -> Recommendation {
        Recommendation(artist: artist, album: album, category: category, reason: reason,
                       shownAt: Date(timeIntervalSince1970: seconds))
    }

    private func fetch(_ catalog: Catalog, normKey: String) throws -> Recommendation? {
        try catalog.dbQueue.read { db in
            try Recommendation.filter(Column("normKey") == normKey).fetchOne(db)
        }
    }

    private func count(_ catalog: Catalog) throws -> Int {
        try catalog.dbQueue.read { db in try Recommendation.fetchCount(db) }
    }

    // MARK: - recordShown

    @Test func recordShownInsertsRowWithComputedNormKey() throws {
        let (store, catalog) = try makeStore()

        try store.recordShown(rec("Radiohead", "OK Computer",
                                  reason: "якорь: Kid A", at: 1_000))

        let key = ReleaseNorm.key(artist: "Radiohead", album: "OK Computer")
        let stored = try fetch(catalog, normKey: key)
        #expect(stored != nil)
        #expect(stored?.id != nil)                     // autoincrement присвоил id
        #expect(stored?.artist == "Radiohead")
        #expect(stored?.album == "OK Computer")
        #expect(stored?.status == .shown)              // статус по умолчанию
        #expect(stored?.category == "missed-classics")
        #expect(stored?.reason == "якорь: Kid A")
        #expect(stored?.shownAt == Date(timeIntervalSince1970: 1_000))
        #expect(stored?.updatedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test func recordShownUpsertsByNormKeyRefreshingShownAt() throws {
        let (store, catalog) = try makeStore()
        try store.recordShown(rec("Radiohead", "OK Computer", reason: "старая", at: 1_000))

        try store.recordShown(rec("Radiohead", "OK Computer", reason: "новая", at: 2_000))

        #expect(try count(catalog) == 1)               // upsert, не дубль
        let key = ReleaseNorm.key(artist: "Radiohead", album: "OK Computer")
        let stored = try fetch(catalog, normKey: key)
        #expect(stored?.shownAt == Date(timeIntervalSince1970: 2_000))
        #expect(stored?.reason == "новая")             // метаданные обновляются
    }

    @Test func recordShownDedupsDiacriticsAndDeluxeViaNormKey() throws {
        // Краевые normKey: диакритика и Deluxe-хвост дают ту же строку.
        let (store, catalog) = try makeStore()
        try store.recordShown(rec("Sigur Rós", "Takk", at: 1_000))

        try store.recordShown(rec("Sigur Ros", "Takk (Deluxe Edition)", at: 2_000))

        #expect(try count(catalog) == 1)
        let key = ReleaseNorm.key(artist: "Sigur Rós", album: "Takk")
        #expect(try fetch(catalog, normKey: key)?.shownAt
                == Date(timeIntervalSince1970: 2_000))
    }

    @Test func recordShownPreservesStatusAndLinksOnRepeat() throws {
        let (store, catalog) = try makeStore()
        let key = ReleaseNorm.key(artist: "Radiohead", album: "OK Computer")
        try store.recordShown(rec("Radiohead", "OK Computer", at: 1_000))
        try store.setStatus(normKey: key, status: .liked,
                            at: Date(timeIntervalSince1970: 1_500))
        try store.cacheLinks(normKey: key, json: #"{"yandex":"url"}"#)

        try store.recordShown(rec("Radiohead", "OK Computer", at: 2_000))

        let stored = try fetch(catalog, normKey: key)
        #expect(stored?.status == .liked)              // фидбек не затирается показом
        #expect(stored?.links == #"{"yandex":"url"}"#) // кэш ссылок тоже
        #expect(stored?.shownAt == Date(timeIntervalSince1970: 2_000))
    }

    // MARK: - setStatus

    @Test func setStatusUpdatesStatusAndUpdatedAt() throws {
        let (store, catalog) = try makeStore()
        let key = ReleaseNorm.key(artist: "Radiohead", album: "OK Computer")
        try store.recordShown(rec("Radiohead", "OK Computer", at: 1_000))

        try store.setStatus(normKey: key, status: .hidden,
                            at: Date(timeIntervalSince1970: 3_000))

        let stored = try fetch(catalog, normKey: key)
        #expect(stored?.status == .hidden)
        #expect(stored?.updatedAt == Date(timeIntervalSince1970: 3_000))
        #expect(stored?.shownAt == Date(timeIntervalSince1970: 1_000))   // не трогаем
    }

    @Test func setStatusOnUnknownKeyIsNoOp() throws {
        let (store, catalog) = try makeStore()

        try store.setStatus(normKey: "нет|такого", status: .liked,
                            at: Date(timeIntervalSince1970: 1_000))

        #expect(try count(catalog) == 0)
    }

    // MARK: - feedback

    @Test func feedbackSplitsLikedHiddenRecentlyShown() throws {
        let (store, _) = try makeStore()
        try store.recordShown(rec("A", "Alpha", at: 1_000))
        try store.recordShown(rec("B", "Beta", at: 2_000))
        try store.recordShown(rec("C", "Gamma", at: 3_000))
        try store.setStatus(normKey: ReleaseNorm.key(artist: "A", album: "Alpha"),
                            status: .liked, at: Date(timeIntervalSince1970: 4_000))
        try store.setStatus(normKey: ReleaseNorm.key(artist: "B", album: "Beta"),
                            status: .hidden, at: Date(timeIntervalSince1970: 5_000))

        let feedback = try store.feedback(likedLimit: 10, hiddenLimit: 10,
                                          shownWindow: Date(timeIntervalSince1970: 0))

        #expect(feedback.liked == ["A — Alpha"])
        #expect(feedback.hidden == ["B — Beta"])
        // «Уже предлагали» включает все статусы, новые сверху.
        #expect(feedback.recentlyShown == ["C — Gamma", "B — Beta", "A — Alpha"])
    }

    @Test func feedbackRespectsLimitsNewestFirst() throws {
        let (store, _) = try makeStore()
        for (i, name) in ["Alpha", "Beta", "Gamma"].enumerated() {
            try store.recordShown(rec("A", name, at: TimeInterval(1_000 + i)))
            try store.setStatus(normKey: ReleaseNorm.key(artist: "A", album: name),
                                status: .liked,
                                at: Date(timeIntervalSince1970: TimeInterval(2_000 + i)))
        }

        let feedback = try store.feedback(likedLimit: 2, hiddenLimit: 10,
                                          shownWindow: Date(timeIntervalSince1970: 0))

        // Лимит режет старые: остаются два последних по updatedAt.
        #expect(feedback.liked == ["A — Gamma", "A — Beta"])
    }

    @Test func feedbackRecentlyShownRespectsWindow() throws {
        let (store, _) = try makeStore()
        try store.recordShown(rec("Old", "Ancient", at: 1_000))
        try store.recordShown(rec("New", "Fresh", at: 5_000))

        let feedback = try store.feedback(likedLimit: 10, hiddenLimit: 10,
                                          shownWindow: Date(timeIntervalSince1970: 4_000))

        #expect(feedback.recentlyShown == ["New — Fresh"])
    }

    // MARK: - shownKeys

    @Test func shownKeysFiltersBySince() throws {
        let (store, _) = try makeStore()
        try store.recordShown(rec("Old", "Ancient", at: 1_000))
        try store.recordShown(rec("New", "Fresh", at: 5_000))

        let keys = try store.shownKeys(since: Date(timeIntervalSince1970: 4_000))

        #expect(keys == [ReleaseNorm.key(artist: "New", album: "Fresh")])
    }

    @Test func shownKeysIncludesAllStatuses() throws {
        let (store, _) = try makeStore()
        let key = ReleaseNorm.key(artist: "A", album: "Alpha")
        try store.recordShown(rec("A", "Alpha", at: 1_000))
        try store.setStatus(normKey: key, status: .hidden,
                            at: Date(timeIntervalSince1970: 2_000))

        #expect(try store.shownKeys(since: Date(timeIntervalSince1970: 0)) == [key])
    }

    @Test func shownKeysExcludesRequestedStatuses() throws {
        // Дедуп ленты: показанное за 90 дней, КРОМЕ liked — их дозволено
        // вернуть (дизайн «Предложка v2», шаг 5 пайплайна).
        let (store, _) = try makeStore()
        let likedKey = ReleaseNorm.key(artist: "A", album: "Alpha")
        try store.recordShown(rec("A", "Alpha", at: 1_000))
        try store.recordShown(rec("B", "Beta", at: 1_000))
        try store.setStatus(normKey: likedKey, status: .liked,
                            at: Date(timeIntervalSince1970: 2_000))

        let keys = try store.shownKeys(since: Date(timeIntervalSince1970: 0),
                                       excluding: [.liked])

        #expect(keys == [ReleaseNorm.key(artist: "B", album: "Beta")])
    }

    // MARK: - keys(withStatus:)

    @Test func keysWithStatusReturnsOnlyMatching() throws {
        // ♥-бейджи карточек ленты: нужен набор liked-ключей, остальные статусы
        // не подмешиваются.
        let (store, _) = try makeStore()
        let likedKey = ReleaseNorm.key(artist: "A", album: "Alpha")
        try store.recordShown(rec("A", "Alpha", at: 1_000))
        try store.recordShown(rec("B", "Beta", at: 1_000))
        try store.recordShown(rec("C", "Gamma", at: 1_000))
        try store.setStatus(normKey: likedKey, status: .liked,
                            at: Date(timeIntervalSince1970: 2_000))
        try store.setStatus(normKey: ReleaseNorm.key(artist: "B", album: "Beta"),
                            status: .hidden, at: Date(timeIntervalSince1970: 2_000))

        #expect(try store.keys(withStatus: .liked) == [likedKey])
    }

    @Test func keysWithStatusEmptyWhenNoMatches() throws {
        let (store, _) = try makeStore()
        try store.recordShown(rec("A", "Alpha", at: 1_000))

        #expect(try store.keys(withStatus: .owned).isEmpty)
    }

    // MARK: - cacheLinks

    @Test func cacheLinksStoresJSONWithoutTouchingStatusOrDates() throws {
        let (store, catalog) = try makeStore()
        let key = ReleaseNorm.key(artist: "A", album: "Alpha")
        try store.recordShown(rec("A", "Alpha", at: 1_000))

        try store.cacheLinks(normKey: key, json: #"{"bandcamp":"url"}"#)

        let stored = try fetch(catalog, normKey: key)
        #expect(stored?.links == #"{"bandcamp":"url"}"#)
        #expect(stored?.status == .shown)
        #expect(stored?.updatedAt == Date(timeIntervalSince1970: 1_000))   // кэш ≠ фидбек
    }

    @Test func cacheLinksOnUnknownKeyIsNoOp() throws {
        let (store, catalog) = try makeStore()

        try store.cacheLinks(normKey: "нет|такого", json: "{}")

        #expect(try count(catalog) == 0)
    }
}
