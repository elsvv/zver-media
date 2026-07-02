import Foundation
import Testing
@testable import ZverCore

/// Модель и запись cue-треков (image+cue): trackKey-идентичность, границы
/// сэмплов, конвертация Track ↔ TrackRecord.
@Suite struct CueTrackTests {
    private let documents = URL(fileURLWithPath: "/docs")

    // MARK: - Track.id / isCueTrack

    @Test func normalTrackIdIsFilePathAndNotCue() {
        let track = Track(url: URL(fileURLWithPath: "/docs/alb/01.flac"),
                          title: "Обычный", duration: 100, sampleRate: 44100)
        #expect(track.id == "/docs/alb/01.flac")
        #expect(track.isCueTrack == false)
        #expect(track.cueIndex == nil)
        #expect(track.startFrame == nil)
        #expect(track.frameCount == nil)
    }

    @Test func cueTrackIdEncodesContainerPathAndIndex() {
        let container = URL(fileURLWithPath: "/docs/alb/CD.flac")
        let t1 = Track(url: container, title: "Трек 1", duration: 200, sampleRate: 44100,
                       cueIndex: 1, startFrame: 0, frameCount: 8_820_000)
        let t2 = Track(url: container, title: "Трек 2", duration: 200, sampleRate: 44100,
                       cueIndex: 2, startFrame: 8_820_000, frameCount: 8_820_000)
        // N cue-треков делят контейнер, но id (trackKey) различает их по индексу
        #expect(t1.id == "/docs/alb/CD.flac#1")
        #expect(t2.id == "/docs/alb/CD.flac#2")
        #expect(t1.url == t2.url)
        #expect(t1 != t2)
        #expect(t1.isCueTrack)
        #expect(t2.isCueTrack)
    }

    // MARK: - TrackRecord.trackKey

    @Test func trackKeyHelperMatchesDocFormula() {
        #expect(TrackRecord.trackKey(relativePath: "alb/CD.flac", cueIndex: nil) == "alb/CD.flac")
        #expect(TrackRecord.trackKey(relativePath: "alb/CD.flac", cueIndex: 3) == "alb/CD.flac#3")
    }

    @Test func recordTrackKeyIsRelativePathForNormalTrack() {
        let record = TrackRecord(relativePath: "alb/01.flac", title: "Обычный",
                                 duration: 1, sampleRate: 44100)
        #expect(record.trackKey == "alb/01.flac")
        #expect(record.cueIndex == nil)
    }

    @Test func recordTrackKeyEncodesCueIndex() {
        let record = TrackRecord(relativePath: "alb/CD.flac", title: "Трек 2",
                                 duration: 1, sampleRate: 44100,
                                 cueIndex: 2, startFrame: 8_820_000, frameCount: 4_410_000)
        #expect(record.trackKey == "alb/CD.flac#2")
        #expect(record.relativePath == "alb/CD.flac")
    }

    // MARK: - Roundtrip Track ↔ TrackRecord (границы cue)

    @Test func recordFromCueTrackCarriesOffsetsAndTrackKey() {
        let container = URL(fileURLWithPath: "/docs/alb/CD.flac")
        let track = Track(url: container, title: "Трек 2", artist: "Исполнитель",
                          album: "Альбом", trackNumber: 2, duration: 190, sampleRate: 44100,
                          cueIndex: 2, startFrame: 8_820_000, frameCount: 8_379_000)

        let record = TrackRecord(track: track, relativePath: "alb/CD.flac",
                                 artworkFilePath: nil)

        // trackKey собирается из relativePath (относительного), не из абсолютного id
        #expect(record.trackKey == "alb/CD.flac#2")
        #expect(record.relativePath == "alb/CD.flac")
        #expect(record.cueIndex == 2)
        #expect(record.startFrame == 8_820_000)
        #expect(record.frameCount == 8_379_000)
    }

    @Test func trackFromCueRecordRebuildsOffsetsAndId() {
        let record = TrackRecord(relativePath: "alb/CD.flac", title: "Трек 2",
                                 duration: 190, sampleRate: 44100,
                                 cueIndex: 2, startFrame: 8_820_000, frameCount: 8_379_000)

        let track = record.track(documentsURL: documents)

        #expect(track.url.path == "/docs/alb/CD.flac")
        #expect(track.id == "/docs/alb/CD.flac#2")
        #expect(track.cueIndex == 2)
        #expect(track.startFrame == 8_820_000)
        #expect(track.frameCount == 8_379_000)
        #expect(track.isCueTrack)
    }

    // MARK: - Roundtrip через SQLite

    @Test func insertFetchRoundtripPreservesCueColumns() throws {
        let catalog = try Catalog.inMemory()
        let record = TrackRecord(relativePath: "alb/CD.flac", title: "Трек 2",
                                 duration: 190, sampleRate: 44100,
                                 addedAt: Date(timeIntervalSince1970: 1_750_000_000),
                                 cueIndex: 2, startFrame: 8_820_000, frameCount: 8_379_000)
        try catalog.dbQueue.write { db in try record.insert(db) }

        let fetched = try catalog.dbQueue.read { db in
            try TrackRecord.fetchOne(db, key: "alb/CD.flac#2")
        }
        #expect(fetched == record)
        #expect(fetched?.trackKey == "alb/CD.flac#2")
        #expect(fetched?.cueIndex == 2)
        #expect(fetched?.startFrame == 8_820_000)
        #expect(fetched?.frameCount == 8_379_000)
    }

    @Test func nCueRowsShareRelativePathButDistinctTrackKeys() throws {
        let catalog = try Catalog.inMemory()
        try catalog.dbQueue.write { db in
            for i in 1...3 {
                try TrackRecord(relativePath: "alb/CD.flac", title: "Трек \(i)",
                                duration: 100, sampleRate: 44100,
                                cueIndex: i, startFrame: Int64((i - 1) * 4_410_000),
                                frameCount: 4_410_000).insert(db)
            }
        }
        let count = try catalog.dbQueue.read { db in try TrackRecord.fetchCount(db) }
        #expect(count == 3)
        let keys = try catalog.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT trackKey FROM track ORDER BY trackKey")
        }
        #expect(keys == ["alb/CD.flac#1", "alb/CD.flac#2", "alb/CD.flac#3"])
    }
}
