import Testing
import Foundation
@testable import ZverTransport

@Suite struct ManifestTests {
    private func sampleManifest() -> SyncManifest {
        let track = ManifestTrack(
            fileName: "01 - 15 Step.flac",
            title: "15 Step",
            artist: "Radiohead",
            album: "In Rainbows",
            trackNumber: 1,
            year: 2007,
            duration: 237.5,
            sampleRate: 44100,
            bitDepth: 24,
            fileSize: 30_123_456,
            sha256: "abc123def456",
            fileExtension: "flac"
        )
        let trackNoOptionals = ManifestTrack(
            fileName: "02 - Bodysnatchers.flac",
            title: "Bodysnatchers",
            artist: nil,
            album: nil,
            trackNumber: nil,
            year: nil,
            duration: 242.0,
            sampleRate: 44100,
            bitDepth: nil,
            fileSize: 31_000_000,
            sha256: "deadbeef",
            fileExtension: "flac"
        )
        let artwork = ManifestArtwork(fileName: "folder.jpg", sha256: "artsha", fileSize: 512_000)
        let album = ManifestAlbum(
            id: "Radiohead - In Rainbows (2007)",
            title: "In Rainbows",
            artist: "Radiohead",
            year: 2007,
            artwork: artwork,
            tracks: [track, trackNoOptionals]
        )
        let albumNoOptionals = ManifestAlbum(
            id: "Unknown - Mixtape",
            title: "Mixtape",
            artist: nil,
            year: nil,
            artwork: nil,
            tracks: [trackNoOptionals]
        )
        return SyncManifest(protocolVersion: SyncManifest.currentProtocolVersion,
                            albums: [album, albumNoOptionals])
    }

    @Test func roundTripPreservesAllFields() throws {
        let original = sampleManifest()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SyncManifest.self, from: data)
        #expect(decoded == original)
    }

    @Test func currentProtocolVersionIsOne() {
        #expect(SyncManifest.currentProtocolVersion == 1)
    }

    @Test func protocolVersionSerializedAsExplicitField() throws {
        let manifest = sampleManifest()
        let data = try JSONEncoder().encode(manifest)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"protocolVersion\""))
    }

    @Test func decodeIgnoresUnknownExtraKeys() throws {
        // Forward-compat: будущая версия добавит поля — старый декодер не падает.
        let json = """
        {
          "protocolVersion": 1,
          "futureTopLevelFlag": true,
          "albums": [
            {
              "id": "A - B (2020)",
              "title": "B",
              "artist": "A",
              "year": 2020,
              "futureAlbumField": "ignored",
              "tracks": [
                {
                  "fileName": "01.flac",
                  "title": "T",
                  "duration": 100.0,
                  "sampleRate": 44100,
                  "fileSize": 1000,
                  "sha256": "x",
                  "fileExtension": "flac",
                  "futureTrackField": 42
                }
              ]
            }
          ]
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SyncManifest.self, from: data)
        #expect(decoded.protocolVersion == 1)
        #expect(decoded.albums.count == 1)
        #expect(decoded.albums[0].tracks.count == 1)
        #expect(decoded.albums[0].artwork == nil)
    }

    @Test func decodeWithDifferentProtocolVersionStillParses() throws {
        // Несовместимость по версии — это НЕ «пустой манифест»: парсим, отдаём
        // вызывающему protocolVersion для его собственного решения.
        let json = """
        {
          "protocolVersion": 99,
          "albums": [
            {
              "id": "A - B",
              "title": "B",
              "tracks": []
            }
          ]
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SyncManifest.self, from: data)
        #expect(decoded.protocolVersion == 99)
        #expect(decoded.protocolVersion != SyncManifest.currentProtocolVersion)
        #expect(decoded.albums.count == 1)
        #expect(decoded.albums[0].id == "A - B")
    }

    @Test func discNumberRoundTripsInManifestTrack() throws {
        let track = ManifestTrack(
            fileName: "d2t1.flac", title: "T", artist: "A", album: "Al",
            trackNumber: 1, discNumber: 2, year: 2000, duration: 1.0,
            sampleRate: 44100, bitDepth: 24, fileSize: 1, sha256: "s",
            fileExtension: "flac")
        let data = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(ManifestTrack.self, from: data)
        #expect(decoded.discNumber == 2)
        #expect(decoded == track)
    }

    @Test func oldManifestWithoutDiscNumberDecodesAsNil() throws {
        // Обратная совместимость: манифест, собранный до фичи дисков, не содержит
        // ключа discNumber — декодер даёт nil, а не падает.
        let json = """
        {"fileName":"x.flac","title":"X","duration":1.0,"sampleRate":44100,
         "fileSize":1,"sha256":"s","fileExtension":"flac"}
        """
        let decoded = try JSONDecoder().decode(ManifestTrack.self, from: Data(json.utf8))
        #expect(decoded.discNumber == nil)
        #expect(decoded.trackNumber == nil)
    }

    @Test func playlistCompanionRoundTrips() throws {
        let album = ManifestAlbum(
            id: "T", title: "T",
            playlist: ManifestFile(fileName: "playlist.m3u8", sha256: "pl", fileSize: 42),
            tracks: [])
        let data = try JSONEncoder().encode(album)
        let decoded = try JSONDecoder().decode(ManifestAlbum.self, from: data)
        #expect(decoded.playlist == ManifestFile(fileName: "playlist.m3u8", sha256: "pl", fileSize: 42))
    }

    @Test func oldAlbumWithoutPlaylistDecodesAsNil() throws {
        // Обратная совместимость: манифест до фичи плейлиста-компаньона.
        let json = #"{"id":"A","title":"B","tracks":[]}"#
        let decoded = try JSONDecoder().decode(ManifestAlbum.self, from: Data(json.utf8))
        #expect(decoded.playlist == nil)
        #expect(decoded.artwork == nil)
    }

    @Test func trackFileNameCarriesRelativePath() throws {
        // fileName может нести относительный путь диска — round-trip как строка.
        let t = ManifestTrack(
            fileName: "CD1/01 - Overcome.flac", title: "x", duration: 1,
            sampleRate: 44100, fileSize: 1, sha256: "s", fileExtension: "flac")
        let d = try JSONDecoder().decode(ManifestTrack.self, from: try JSONEncoder().encode(t))
        #expect(d.fileName == "CD1/01 - Overcome.flac")
    }

    // MARK: - Extras (`.cue`/`.log`)

    @Test func extrasRoundTripInManifestAlbum() throws {
        let album = ManifestAlbum(
            id: "A - B (2020)", title: "B", artist: "A", year: 2020,
            extras: [
                ManifestFile(fileName: "Album.cue", sha256: "cue", fileSize: 1024),
                ManifestFile(fileName: "Album.log", sha256: "log", fileSize: 7000),
            ],
            tracks: [])
        let data = try JSONEncoder().encode(album)
        let decoded = try JSONDecoder().decode(ManifestAlbum.self, from: data)
        #expect(decoded == album)
        #expect(decoded.extras.count == 2)
        #expect(decoded.extras[0] == ManifestFile(fileName: "Album.cue", sha256: "cue", fileSize: 1024))
        #expect(decoded.extras[1] == ManifestFile(fileName: "Album.log", sha256: "log", fileSize: 7000))
    }

    @Test func oldAlbumWithoutExtrasDecodesAsEmpty() throws {
        // Обратная совместимость: манифест, собранный до фичи extras, не содержит
        // ключа — декодер даёт пустой массив, а не падает и не nil.
        let json = #"{"id":"A","title":"B","tracks":[]}"#
        let decoded = try JSONDecoder().decode(ManifestAlbum.self, from: Data(json.utf8))
        #expect(decoded.extras.isEmpty)
        #expect(decoded.playlist == nil)
        #expect(decoded.artwork == nil)
    }

    @Test func extrasRoundTripThroughFullManifest() throws {
        // Extras переживают полный round-trip манифеста вместе с прочими полями.
        var album = sampleManifest().albums[0]
        album.extras = [ManifestFile(fileName: "CD.cue", sha256: "c", fileSize: 900)]
        let manifest = SyncManifest(albums: [album])
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(SyncManifest.self, from: data)
        #expect(decoded == manifest)
        #expect(decoded.albums[0].extras.count == 1)
    }

    // MARK: - servableFiles (дедуп треков + extras) — основа keep-set/fileCount

    @Test func servableFilesDedupesCueTracksAndKeepsExtras() {
        // cue-образ: N логических треков делят один контейнер (`.flac`); плюс `.cue`
        // и `.log` в extras. servableFiles — контейнер РОВНО один раз + оба extra.
        let container = "Album.flac"
        let cueTrack = { (title: String) in
            ManifestTrack(fileName: container, title: title, duration: 1,
                          sampleRate: 44100, fileSize: 258_000_000, sha256: "flacsha",
                          fileExtension: "flac")
        }
        let album = ManifestAlbum(
            id: "A - B (2020)", title: "B",
            artwork: ManifestArtwork(fileName: "cover.jpg", sha256: "art", fileSize: 500),
            extras: [
                ManifestFile(fileName: "Album.cue", sha256: "cue", fileSize: 1024),
                ManifestFile(fileName: "Album.log", sha256: "log", fileSize: 7000),
            ],
            tracks: [cueTrack("One"), cueTrack("Two"), cueTrack("Three")])

        let files = album.servableFiles
        let names = files.map(\.fileName)
        // Контейнер один раз, обложка, оба extra — 4 уникальных файла.
        #expect(names == [container, "cover.jpg", "Album.cue", "Album.log"])
        // Контейнер несёт sha/size именно контейнера (не затёрт).
        #expect(files[0].sha256 == "flacsha")
        #expect(files[0].fileSize == 258_000_000)
        // keep-set содержит `.cue` и `.log`.
        #expect(Set(names).isSuperset(of: ["Album.cue", "Album.log"]))
    }

    @Test func servableFilesForNormalAlbumEqualsTracksPlusCompanions() {
        // Обычный альбом (без cue/extras): servableFiles = треки + обложка + плейлист.
        let album = ManifestAlbum(
            id: "A - B (2020)", title: "B",
            artwork: ManifestArtwork(fileName: "folder.jpg", sha256: "art", fileSize: 500),
            playlist: ManifestFile(fileName: "playlist.m3u8", sha256: "pl", fileSize: 300),
            tracks: [
                ManifestTrack(fileName: "01.flac", title: "1", duration: 1, sampleRate: 44100,
                              fileSize: 1, sha256: "t1", fileExtension: "flac"),
                ManifestTrack(fileName: "02.flac", title: "2", duration: 1, sampleRate: 44100,
                              fileSize: 1, sha256: "t2", fileExtension: "flac"),
            ])
        #expect(album.servableFiles.map(\.fileName) == ["01.flac", "02.flac", "folder.jpg", "playlist.m3u8"])
    }

    @Test func optionalTrackFieldsRoundTripAsNil() throws {
        let track = ManifestTrack(
            fileName: "x.flac", title: "X", artist: nil, album: nil,
            trackNumber: nil, year: nil, duration: 1.0, sampleRate: 44100,
            bitDepth: nil, fileSize: 1, sha256: "s", fileExtension: "flac"
        )
        let data = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(ManifestTrack.self, from: data)
        #expect(decoded == track)
        #expect(decoded.artist == nil)
        #expect(decoded.bitDepth == nil)
    }
}
