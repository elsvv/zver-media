import Foundation

/// Правки полей одного трека, заданные на Маке и переносимые рядом с файлами.
/// Любое непустое поле побеждает прочитанный из файла тег (см. `LibraryScanner`).
public struct TrackOverride: Codable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var year: Int?
    public var trackNumber: Int?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.year = year
        self.trackNumber = trackNumber
    }
}

/// Sidecar-файл альбома (`album.zvermeta.json`), лежащий в папке трека.
/// Несёт правки тегов треков (ключ — `fileName` аудиофайла) и опциональную
/// обложку альбома (`artworkFileName` — имя файла в той же папке).
public struct AlbumSidecar: Codable, Sendable {
    public var version: Int
    public var artworkFileName: String?
    public var tracks: [String: TrackOverride]

    /// Имя sidecar-файла в папке альбома.
    public static let fileName = "album.zvermeta.json"

    public init(
        version: Int,
        artworkFileName: String? = nil,
        tracks: [String: TrackOverride] = [:]
    ) {
        self.version = version
        self.artworkFileName = artworkFileName
        self.tracks = tracks
    }
}
