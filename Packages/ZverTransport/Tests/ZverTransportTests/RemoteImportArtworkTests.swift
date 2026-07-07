import Testing
import Foundation
@testable import ZverTransport

/// Аддитивные теги протокола пульта этапа 4 (импорт с Мака + обложки) и
/// опциональное `RemoteAlbum.cloudState`. Проверяем round-trip новых вариантов,
/// байт-точность JPEG-обложки, forward-compat фазы импорта и совместимость
/// старого JSON без `cloudState`. Протокол остаётся v1.
@Suite struct RemoteImportArtworkTests {
    private let codec = RemoteCodec()

    private func roundTrip(_ payload: RemotePayload) throws -> RemotePayload {
        let message = RemoteMessage(payload: payload)
        let data = try codec.encode(message)
        let decoded = try codec.decode(data)
        #expect(decoded.protocolVersion == RemoteMessage.currentProtocolVersion)
        return decoded.payload
    }

    // MARK: Mac → iPhone

    @Test func roundTripStartImport() throws {
        #expect(try roundTrip(.startImport) == .startImport)
    }

    @Test func roundTripRequestArtwork() throws {
        let payload = RemotePayload.requestArtwork(albumId: "Radiohead - In Rainbows (2007)")
        #expect(try roundTrip(payload) == payload)
    }

    // MARK: iPhone → Mac

    @Test func roundTripArtwork() throws {
        // Мини-JPEG-заголовок (SOI + APP0) — важно, что это непустой Data.
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
        let payload = RemotePayload.artwork(albumId: "A - B (2020)", data: bytes)
        #expect(try roundTrip(payload) == payload)
    }

    @Test func artworkRoundTripPreservesBytesExactly() throws {
        // Все 256 значений байта — base64 в JSONEncoder должен вернуть их 1:1.
        let bytes = Data((0...255).map { UInt8($0) })
        let payload = RemotePayload.artwork(albumId: "A - B (2020)", data: bytes)
        guard case let .artwork(albumId, decoded) = try roundTrip(payload) else {
            Issue.record("expected .artwork payload")
            return
        }
        #expect(albumId == "A - B (2020)")
        #expect(decoded == bytes)
        #expect(Array(decoded) == Array(bytes))
    }

    @Test func roundTripImportStatusDownloading() throws {
        let status = RemoteImportStatus(phase: .downloading, albumTitle: "In Rainbows",
                                        completedAlbums: 2, totalAlbums: 5,
                                        fraction: 0.4, message: nil)
        let payload = RemotePayload.importStatus(status)
        #expect(try roundTrip(payload) == payload)
    }

    @Test func roundTripImportStatusFailed() throws {
        let status = RemoteImportStatus(phase: .failed, albumTitle: nil,
                                        completedAlbums: 1, totalAlbums: 3,
                                        fraction: 0.33, message: "нет синк-сервиса")
        let payload = RemotePayload.importStatus(status)
        #expect(try roundTrip(payload) == payload)
    }

    @Test func roundTripImportStatusIdle() throws {
        let status = RemoteImportStatus(phase: .idle, completedAlbums: 0,
                                        totalAlbums: 0, fraction: 0)
        let payload = RemotePayload.importStatus(status)
        #expect(try roundTrip(payload) == payload)
    }

    // MARK: Forward-compat фазы импорта

    @Test func unknownImportPhaseDecodesToUnknownNotThrow() throws {
        // Фаза из будущей версии — как RemotePlayback, декод не падает.
        let json = """
        {
          "protocolVersion": 1,
          "payload": {
            "type": "importStatus",
            "status": {
              "phase": "compressing",
              "completedAlbums": 0,
              "totalAlbums": 3,
              "fraction": 0.0
            }
          }
        }
        """
        let decoded = try codec.decode(Data(json.utf8))
        guard case let .importStatus(status) = decoded.payload else {
            Issue.record("expected .importStatus payload")
            return
        }
        #expect(status.phase == .unknown)
        #expect(status.totalAlbums == 3)
    }

    @Test func unknownNewTagStillDecodesAsUnknownPayload() throws {
        // Даже с новыми тегами неизвестный type по-прежнему → .unknown.
        let json = """
        { "protocolVersion": 1, "payload": { "type": "startExport" } }
        """
        let decoded = try codec.decode(Data(json.utf8))
        #expect(decoded.payload == .unknown(type: "startExport"))
    }

    // MARK: RemotePlayerState.currentAlbumId (аддитивно)

    @Test func roundTripStateWithCurrentAlbumId() throws {
        let state = RemotePlayerState(playback: .playing, current: nil,
                                      position: 1, queue: [], currentIndex: nil,
                                      currentAlbumId: "VA\u{1}OST")
        let payload = RemotePayload.state(state)
        #expect(try roundTrip(payload) == payload)
    }

    @Test func stateWithoutCurrentAlbumIdDecodesToNil() throws {
        // Старый JSON без поля — backward-совместимость, currentAlbumId == nil.
        let json = """
        {
          "protocolVersion": 1,
          "payload": {
            "type": "state",
            "state": { "playback": "paused", "position": 0, "queue": [] }
          }
        }
        """
        let decoded = try codec.decode(Data(json.utf8))
        guard case let .state(state) = decoded.payload else {
            Issue.record("expected .state payload")
            return
        }
        #expect(state.currentAlbumId == nil)
    }

    // MARK: RemoteAlbum.cloudState

    @Test func roundTripLibraryWithCloudState() throws {
        let album = RemoteAlbum(id: "A - B (2020)", title: "B", artist: "A",
                                year: 2020, trackCount: 10, cloudState: "backedUp")
        let payload = RemotePayload.library(RemoteLibrary(albums: [album]))
        #expect(try roundTrip(payload) == payload)
    }

    @Test func albumWithoutCloudStateDecodesToNil() throws {
        // Старый JSON без поля — backward-совместимость, cloudState == nil.
        let json = """
        {
          "protocolVersion": 1,
          "payload": {
            "type": "library",
            "library": { "albums": [ { "id": "a", "title": "T", "trackCount": 1 } ] }
          }
        }
        """
        let decoded = try codec.decode(Data(json.utf8))
        guard case let .library(lib) = decoded.payload else {
            Issue.record("expected .library payload")
            return
        }
        #expect(lib.albums.first?.cloudState == nil)
    }

    @Test func albumWithCloudStateDecodes() throws {
        let json = """
        {
          "protocolVersion": 1,
          "payload": {
            "type": "library",
            "library": { "albums": [ { "id": "a", "title": "T", "trackCount": 1, "cloudState": "remote" } ] }
          }
        }
        """
        let decoded = try codec.decode(Data(json.utf8))
        guard case let .library(lib) = decoded.payload else {
            Issue.record("expected .library payload")
            return
        }
        #expect(lib.albums.first?.cloudState == "remote")
    }
}
