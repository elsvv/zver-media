import Testing
import Foundation
@testable import ZverTransport

@Suite struct SyncPlannerTests {
    // MARK: - Fixtures

    private func track(_ fileName: String, sha: String, size: Int = 1000) -> ManifestTrack {
        ManifestTrack(
            fileName: fileName,
            title: fileName,
            artist: "A",
            album: "B",
            trackNumber: 1,
            year: 2020,
            duration: 100.0,
            sampleRate: 44100,
            bitDepth: 24,
            fileSize: size,
            sha256: sha,
            fileExtension: "flac"
        )
    }

    private func album(id: String,
                       tracks: [ManifestTrack],
                       artwork: ManifestArtwork? = nil) -> ManifestAlbum {
        ManifestAlbum(id: id, title: "B", artist: "A", year: 2020, artwork: artwork, tracks: tracks)
    }

    /// Удобный поиск планируемого файла по пути.
    private func find(_ plan: SyncPlan, albumId: String, fileName: String) -> PlannedFile? {
        plan.toFetch.first { $0.albumId == albumId && $0.fileName == fileName }
    }

    // MARK: - Новый альбом

    @Test func newAlbumQueuesAllFiles() {
        let manifest = SyncManifest(albums: [
            album(
                id: "A - B (2020)",
                tracks: [track("01.flac", sha: "t1"), track("02.flac", sha: "t2")],
                artwork: ManifestArtwork(fileName: "folder.jpg", sha256: "art", fileSize: 500)
            )
        ])
        let plan = SyncPlanner.plan(manifest: manifest, localShasByPath: [:])

        // Все три файла (2 трека + обложка) — на скачивание.
        #expect(plan.toFetch.count == 3)
        #expect(find(plan, albumId: "A - B (2020)", fileName: "01.flac") != nil)
        #expect(find(plan, albumId: "A - B (2020)", fileName: "02.flac") != nil)
        let art = find(plan, albumId: "A - B (2020)", fileName: "folder.jpg")
        #expect(art != nil)
        #expect(art?.kind == .artwork)
        // Альбом не докачан целиком → его нет в alreadyComplete.
        #expect(plan.alreadyComplete.isEmpty)
    }

    // MARK: - Плейлист-компаньон + подпапки-диски

    @Test func playlistParticipatesAsSeparateFile() {
        let manifest = SyncManifest(albums: [
            ManifestAlbum(
                id: "A - B (2020)", title: "B", artist: "A", year: 2020,
                playlist: ManifestFile(fileName: "playlist.m3u8", sha256: "pl", fileSize: 300),
                tracks: [track("CD1/01.flac", sha: "t1"), track("CD2/01.flac", sha: "t2")]
            )
        ])
        let plan = SyncPlanner.plan(manifest: manifest, localShasByPath: [:])
        let pl = find(plan, albumId: "A - B (2020)", fileName: "playlist.m3u8")
        #expect(pl?.kind == .playlist)
        // Трек-подпуть планируется как есть — fileName несёт относительный путь.
        #expect(find(plan, albumId: "A - B (2020)", fileName: "CD1/01.flac") != nil)
        #expect(find(plan, albumId: "A - B (2020)", fileName: "CD2/01.flac") != nil)
        #expect(!plan.alreadyComplete.contains("A - B (2020)"))
    }

    @Test func matchedPlaylistAndSubpathsCompleteAlbum() {
        let manifest = SyncManifest(albums: [
            ManifestAlbum(
                id: "A - B (2020)", title: "B", artist: "A", year: 2020,
                playlist: ManifestFile(fileName: "playlist.m3u8", sha256: "pl", fileSize: 300),
                tracks: [track("CD1/01.flac", sha: "t1")]
            )
        ])
        let local = [
            "A - B (2020)/CD1/01.flac": "t1",
            "A - B (2020)/playlist.m3u8": "pl",
        ]
        let plan = SyncPlanner.plan(manifest: manifest, localShasByPath: local)
        #expect(plan.toFetch.isEmpty)
        #expect(plan.alreadyComplete == ["A - B (2020)"])
    }

    // MARK: - Полностью совпавший альбом

    @Test func fullyMatchedAlbumIsCompleteAndFetchesNothing() {
        let manifest = SyncManifest(albums: [
            album(
                id: "A - B (2020)",
                tracks: [track("01.flac", sha: "t1"), track("02.flac", sha: "t2")],
                artwork: ManifestArtwork(fileName: "folder.jpg", sha256: "art", fileSize: 500)
            )
        ])
        let local: [String: String] = [
            "A - B (2020)/01.flac": "t1",
            "A - B (2020)/02.flac": "t2",
            "A - B (2020)/folder.jpg": "art"
        ]
        let plan = SyncPlanner.plan(manifest: manifest, localShasByPath: local)

        #expect(plan.toFetch.isEmpty)
        #expect(plan.alreadyComplete == ["A - B (2020)"])
    }

    // MARK: - Изменён один трек

    @Test func changedSingleTrackQueuesOnlyThatTrack() {
        let manifest = SyncManifest(albums: [
            album(
                id: "A - B (2020)",
                tracks: [track("01.flac", sha: "t1"), track("02.flac", sha: "t2-new")],
                artwork: ManifestArtwork(fileName: "folder.jpg", sha256: "art", fileSize: 500)
            )
        ])
        let local: [String: String] = [
            "A - B (2020)/01.flac": "t1",
            "A - B (2020)/02.flac": "t2-old",   // sha разошёлся → докачиваем
            "A - B (2020)/folder.jpg": "art"
        ]
        let plan = SyncPlanner.plan(manifest: manifest, localShasByPath: local)

        #expect(plan.toFetch.count == 1)
        #expect(find(plan, albumId: "A - B (2020)", fileName: "02.flac") != nil)
        #expect(find(plan, albumId: "A - B (2020)", fileName: "02.flac")?.kind == .track)
        // Альбом не докачан целиком.
        #expect(plan.alreadyComplete.isEmpty)
    }

    // MARK: - Отсутствующий локально файл

    @Test func missingLocalFileIsQueued() {
        let manifest = SyncManifest(albums: [
            album(id: "A - B (2020)", tracks: [track("01.flac", sha: "t1"), track("02.flac", sha: "t2")])
        ])
        let local: [String: String] = [
            "A - B (2020)/01.flac": "t1"   // 02.flac отсутствует
        ]
        let plan = SyncPlanner.plan(manifest: manifest, localShasByPath: local)

        #expect(plan.toFetch.count == 1)
        #expect(find(plan, albumId: "A - B (2020)", fileName: "02.flac") != nil)
        #expect(plan.alreadyComplete.isEmpty)
    }

    // MARK: - Обложка как отдельный файл

    @Test func artworkParticipatesAsSeparateFile() {
        let manifest = SyncManifest(albums: [
            album(
                id: "A - B (2020)",
                tracks: [track("01.flac", sha: "t1")],
                artwork: ManifestArtwork(fileName: "folder.jpg", sha256: "art", fileSize: 500)
            )
        ])
        // Треки совпали, обложка — нет.
        let local: [String: String] = [
            "A - B (2020)/01.flac": "t1",
            "A - B (2020)/folder.jpg": "art-old"
        ]
        let plan = SyncPlanner.plan(manifest: manifest, localShasByPath: local)

        #expect(plan.toFetch.count == 1)
        let art = find(plan, albumId: "A - B (2020)", fileName: "folder.jpg")
        #expect(art != nil)
        #expect(art?.kind == .artwork)
        #expect(art?.sha256 == "art")
        #expect(art?.fileSize == 500)
        // Обложка ещё не докачана → альбом не complete.
        #expect(plan.alreadyComplete.isEmpty)
    }

    @Test func albumWithoutArtworkCompletesOnTracksOnly() {
        let manifest = SyncManifest(albums: [
            album(id: "A - B (2020)", tracks: [track("01.flac", sha: "t1")])
        ])
        let local: [String: String] = ["A - B (2020)/01.flac": "t1"]
        let plan = SyncPlanner.plan(manifest: manifest, localShasByPath: local)

        #expect(plan.toFetch.isEmpty)
        #expect(plan.alreadyComplete == ["A - B (2020)"])
    }

    // MARK: - PlannedFile несёт метаданные файла

    @Test func plannedTrackCarriesShaAndSize() {
        let manifest = SyncManifest(albums: [
            album(id: "A - B (2020)", tracks: [track("01.flac", sha: "t1", size: 4242)])
        ])
        let plan = SyncPlanner.plan(manifest: manifest, localShasByPath: [:])
        let f = find(plan, albumId: "A - B (2020)", fileName: "01.flac")
        #expect(f?.sha256 == "t1")
        #expect(f?.fileSize == 4242)
        #expect(f?.kind == .track)
    }

    // MARK: - Несколько альбомов

    @Test func multipleAlbumsMixedCompleteAndPartial() {
        let manifest = SyncManifest(albums: [
            album(id: "Done - X (2020)", tracks: [track("01.flac", sha: "d1")]),
            album(id: "Todo - Y (2021)", tracks: [track("01.flac", sha: "y1"), track("02.flac", sha: "y2")])
        ])
        let local: [String: String] = [
            "Done - X (2020)/01.flac": "d1",
            "Todo - Y (2021)/01.flac": "y1"   // второй трек отсутствует
        ]
        let plan = SyncPlanner.plan(manifest: manifest, localShasByPath: local)

        #expect(plan.alreadyComplete == ["Done - X (2020)"])
        #expect(plan.toFetch.count == 1)
        #expect(find(plan, albumId: "Todo - Y (2021)", fileName: "02.flac") != nil)
    }

    // MARK: - Идемпотентность / перезаливка с правленым sidecar

    @Test func reuploadWithEditedSidecarDoesNotAffectPlan() {
        // Перезаливка того же альбома с правками метадаты НЕ меняет sha аудиофайлов:
        // sidecar (album.zvermeta.json) — не аудиофайл и в манифесте отдельно не качается.
        // Поэтому совпавший по sha альбом остаётся complete, ничего не докачивается.
        let manifest = SyncManifest(albums: [
            album(
                id: "A - B (2020)",
                tracks: [track("01.flac", sha: "t1"), track("02.flac", sha: "t2")],
                artwork: ManifestArtwork(fileName: "folder.jpg", sha256: "art", fileSize: 500)
            )
        ])
        let local: [String: String] = [
            "A - B (2020)/01.flac": "t1",
            "A - B (2020)/02.flac": "t2",
            "A - B (2020)/folder.jpg": "art",
            // sidecar лежит рядом, но в манифесте его нет → план его игнорирует.
            "A - B (2020)/album.zvermeta.json": "whatever-sha"
        ]
        let plan = SyncPlanner.plan(manifest: manifest, localShasByPath: local)

        #expect(plan.toFetch.isEmpty)
        #expect(plan.alreadyComplete == ["A - B (2020)"])
    }

    // MARK: - Пустой манифест

    @Test func emptyManifestPlansNothing() {
        let plan = SyncPlanner.plan(manifest: SyncManifest(albums: []), localShasByPath: [:])
        #expect(plan.toFetch.isEmpty)
        #expect(plan.alreadyComplete.isEmpty)
    }
}
