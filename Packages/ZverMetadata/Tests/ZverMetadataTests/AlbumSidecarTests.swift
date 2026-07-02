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

    @Test func decodesDiscNumberOverride() throws {
        let json = """
        {"version": 1, "tracks": {"d2.flac": {"title": "T", "discNumber": 2, "trackNumber": 5}}}
        """
        let sidecar = try JSONDecoder().decode(AlbumSidecar.self, from: Data(json.utf8))
        let override = try #require(sidecar.tracks["d2.flac"])
        #expect(override.discNumber == 2)
        #expect(override.trackNumber == 5)
    }

    @Test func discNumberAbsentDecodesAsNil() throws {
        // Старый sidecar без ключа discNumber — не падает, диск nil.
        let json = """
        {"version": 1, "tracks": {"x.flac": {"trackNumber": 1}}}
        """
        let sidecar = try JSONDecoder().decode(AlbumSidecar.self, from: Data(json.utf8))
        #expect(sidecar.tracks["x.flac"]?.discNumber == nil)
    }

    @Test func roundTripsDiscNumber() throws {
        let original = AlbumSidecar(
            version: 1,
            tracks: ["a.flac": TrackOverride(title: "T", trackNumber: 1, discNumber: 2)])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AlbumSidecar.self, from: data)
        #expect(decoded.tracks["a.flac"]?.discNumber == 2)
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

    @Test func decodesArtworkOnlyWithoutTracksKey() throws {
        // Реалистичный кейс: правка только обложки, ключа `tracks` нет вовсе.
        // Синтезированный init(from:) кинул бы keyNotFound; кастомный — нет.
        let json = """
        {"version": 1, "artworkFileName": "edited.jpg"}
        """
        let sidecar = try JSONDecoder().decode(
            AlbumSidecar.self, from: Data(json.utf8))
        #expect(sidecar.version == 1)
        #expect(sidecar.artworkFileName == "edited.jpg")
        #expect(sidecar.tracks.isEmpty)
    }

    @Test func decodesBareVersionOnly() throws {
        // Ни tracks, ни artworkFileName, ни description — все опциональны при чтении.
        let sidecar = try JSONDecoder().decode(
            AlbumSidecar.self, from: Data(#"{"version":2}"#.utf8))
        #expect(sidecar.version == 2)
        #expect(sidecar.artworkFileName == nil)
        #expect(sidecar.description == nil)
        #expect(sidecar.tracks.isEmpty)
    }

    @Test func decodesDescriptionField() throws {
        let json = """
        {"version": 1, "description": "Легендарный альбом 2003 года."}
        """
        let sidecar = try JSONDecoder().decode(
            AlbumSidecar.self, from: Data(json.utf8))
        #expect(sidecar.description == "Легендарный альбом 2003 года.")
        // description сам по себе не тянет за собой другие поля.
        #expect(sidecar.artworkFileName == nil)
        #expect(sidecar.tracks.isEmpty)
    }

    @Test func roundTripsWithDescription() throws {
        let original = AlbumSidecar(
            version: 1,
            artworkFileName: "cover.jpg",
            description: "Многострочное\nописание альбома.",
            tracks: ["a.flac": TrackOverride(title: "T")])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AlbumSidecar.self, from: data)
        #expect(decoded.description == "Многострочное\nописание альбома.")
        #expect(decoded.artworkFileName == "cover.jpg")
        #expect(decoded.tracks["a.flac"]?.title == "T")
    }

    @Test func descriptionAbsentWhenNil() throws {
        // Правка без описания round-trip'ится с description == nil.
        let original = AlbumSidecar(version: 1, tracks: ["a.flac": TrackOverride(title: "T")])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AlbumSidecar.self, from: data)
        #expect(decoded.description == nil)
    }
}
