import Testing
import Foundation
@testable import ZverMetadata

@Suite struct AlbumSidecarTests {
    @Test func decodesFromJSON() throws {
        let json = """
        {
          "version": 1,
          "artworkFileName": "cover.jpg",
          "tracks": {
            "01.flac": {
              "title": "Песня",
              "artist": "Исполнитель",
              "album": "Альбом",
              "year": 2007,
              "trackNumber": 3
            }
          }
        }
        """
        let sidecar = try JSONDecoder().decode(
            AlbumSidecar.self, from: Data(json.utf8))
        #expect(sidecar.version == 1)
        #expect(sidecar.artworkFileName == "cover.jpg")
        let override = try #require(sidecar.tracks["01.flac"])
        #expect(override.title == "Песня")
        #expect(override.artist == "Исполнитель")
        #expect(override.album == "Альбом")
        #expect(override.year == 2007)
        #expect(override.trackNumber == 3)
    }

    @Test func roundTripsThroughCoding() throws {
        let original = AlbumSidecar(
            version: 1,
            artworkFileName: nil,
            tracks: ["a.flac": TrackOverride(
                title: "T", artist: nil, album: "A", year: nil, trackNumber: 1)])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AlbumSidecar.self, from: data)
        #expect(decoded.version == 1)
        #expect(decoded.artworkFileName == nil)
        #expect(decoded.tracks["a.flac"]?.title == "T")
        #expect(decoded.tracks["a.flac"]?.album == "A")
        #expect(decoded.tracks["a.flac"]?.trackNumber == 1)
    }

    @Test func fileNameConstant() {
        #expect(AlbumSidecar.fileName == "album.zvermeta.json")
    }

    @Test func decodesWithMissingOptionalFields() throws {
        let json = """
        {"version": 1, "tracks": {"x.flac": {"title": "Только заголовок"}}}
        """
        let sidecar = try JSONDecoder().decode(
            AlbumSidecar.self, from: Data(json.utf8))
        #expect(sidecar.artworkFileName == nil)
        let override = try #require(sidecar.tracks["x.flac"])
        #expect(override.title == "Только заголовок")
        #expect(override.artist == nil)
        #expect(override.album == nil)
        #expect(override.year == nil)
        #expect(override.trackNumber == nil)
    }
}
