import Testing
import Foundation
@testable import ZverTransport

/// Round-trip каждого варианта `RemotePayload` через `RemoteMessage`-конверт.
/// Кодирование идёт через `RemoteCodec` (JSON), декод обратно — равенство.
@Suite struct RemoteMessageTests {
    private let codec = RemoteCodec()

    private func roundTrip(_ payload: RemotePayload) throws -> RemotePayload {
        let message = RemoteMessage(payload: payload)
        let data = try codec.encode(message)
        let decoded = try codec.decode(data)
        #expect(decoded.protocolVersion == RemoteMessage.currentProtocolVersion)
        return decoded.payload
    }

    // MARK: Mac → iPhone

    @Test func roundTripPair() throws {
        let payload = RemotePayload.pair(code: "012345")
        #expect(try roundTrip(payload) == payload)
    }

    @Test func roundTripHello() throws {
        let payload = RemotePayload.hello(token: "deadbeef00")
        #expect(try roundTrip(payload) == payload)
    }

    @Test func roundTripPlay() throws {
        #expect(try roundTrip(.play) == .play)
    }

    @Test func roundTripPause() throws {
        #expect(try roundTrip(.pause) == .pause)
    }

    @Test func roundTripTogglePlayPause() throws {
        #expect(try roundTrip(.togglePlayPause) == .togglePlayPause)
    }

    @Test func roundTripNext() throws {
        #expect(try roundTrip(.next) == .next)
    }

    @Test func roundTripPrevious() throws {
        #expect(try roundTrip(.previous) == .previous)
    }

    @Test func roundTripSeek() throws {
        let payload = RemotePayload.seek(seconds: 123.456)
        #expect(try roundTrip(payload) == payload)
    }

    @Test func roundTripRequestLibrary() throws {
        #expect(try roundTrip(.requestLibrary) == .requestLibrary)
    }

    @Test func roundTripRequestAlbumTracks() throws {
        let payload = RemotePayload.requestAlbumTracks(albumId: "Radiohead - In Rainbows (2007)")
        #expect(try roundTrip(payload) == payload)
    }

    @Test func roundTripPlayAlbum() throws {
        let payload = RemotePayload.playAlbum(albumId: "A - B (2020)", startIndex: 3)
        #expect(try roundTrip(payload) == payload)
    }

    // MARK: iPhone → Mac

    @Test func roundTripPaired() throws {
        let payload = RemotePayload.paired(token: "cafef00d")
        #expect(try roundTrip(payload) == payload)
    }

    @Test func roundTripHelloAck() throws {
        let payload = RemotePayload.helloAck(ok: true, protocolVersion: RemoteMessage.currentProtocolVersion)
        #expect(try roundTrip(payload) == payload)
    }

    @Test func roundTripHelloAckRejected() throws {
        let payload = RemotePayload.helloAck(ok: false, protocolVersion: 1)
        #expect(try roundTrip(payload) == payload)
    }

    @Test func roundTripState() throws {
        let track = RemoteTrack(id: "t1", title: "15 Step", artist: "Radiohead",
                                album: "In Rainbows", duration: 237.5,
                                sampleRate: 44100, bitDepth: 24)
        let bare = RemoteTrack(id: "t2", title: "Bodysnatchers", duration: 242.0)
        let state = RemotePlayerState(playback: .playing, current: track,
                                      position: 12.5, queue: [track, bare], currentIndex: 0)
        let payload = RemotePayload.state(state)
        #expect(try roundTrip(payload) == payload)
    }

    @Test func roundTripStateIdle() throws {
        let state = RemotePlayerState(playback: .idle, current: nil,
                                      position: 0, queue: [], currentIndex: nil)
        let payload = RemotePayload.state(state)
        #expect(try roundTrip(payload) == payload)
    }

    @Test func roundTripLibrary() throws {
        let album = RemoteAlbum(id: "A - B (2020)", title: "B", artist: "A", year: 2020, trackCount: 10)
        let bare = RemoteAlbum(id: "Mixtape", title: "Mixtape", trackCount: 3)
        let payload = RemotePayload.library(RemoteLibrary(albums: [album, bare]))
        #expect(try roundTrip(payload) == payload)
    }

    @Test func roundTripAlbumTracks() throws {
        let track = RemoteTrack(id: "t1", title: "T", artist: "A", album: "B",
                                duration: 100, sampleRate: 96000, bitDepth: 24)
        let payload = RemotePayload.albumTracks(albumId: "A - B (2020)", tracks: [track])
        #expect(try roundTrip(payload) == payload)
    }

    @Test func roundTripError() throws {
        let payload = RemotePayload.error(message: "unauthorized")
        #expect(try roundTrip(payload) == payload)
    }

    // MARK: Конверт

    @Test func messageHasExplicitProtocolVersionField() throws {
        let message = RemoteMessage(payload: .play)
        let data = try codec.encode(message)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"protocolVersion\""))
    }

    @Test func currentProtocolVersionIsOne() {
        #expect(RemoteMessage.currentProtocolVersion == 1)
    }

    @Test func payloadCarriesTypeTag() throws {
        let data = try codec.encode(RemoteMessage(payload: .seek(seconds: 1)))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"type\""))
        #expect(json.contains("\"seek\""))
    }

    @Test func equatableDistinguishesPayloads() {
        #expect(RemotePayload.play != RemotePayload.pause)
        #expect(RemotePayload.seek(seconds: 1) != RemotePayload.seek(seconds: 2))
        #expect(RemotePayload.pair(code: "1") != RemotePayload.hello(token: "1"))
    }
}
