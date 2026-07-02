import Foundation

/// Правки полей одного трека, заданные на Маке и переносимые рядом с файлами.
/// Любое непустое поле побеждает прочитанный из файла тег (см. `LibraryScanner`).
public struct TrackOverride: Codable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var year: Int?
    public var trackNumber: Int?
    /// Явный номер диска, заданный на Маке. Побеждает тег DISCNUMBER файла —
    /// нужно, когда рип не содержит дисковых тегов, а альбом много-дисковый.
    public var discNumber: Int?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
    }
}

/// Sidecar-файл альбома (`album.zvermeta.json`), лежащий в папке трека.
/// Несёт правки тегов треков (ключ — `fileName` аудиофайла) и опциональную
/// обложку альбома (`artworkFileName` — имя файла в той же папке).
public struct AlbumSidecar: Codable, Sendable {
    public var version: Int
    public var artworkFileName: String?
    /// Описание альбома (аннотация/заметка), правится на Маке и показывается на
    /// экране альбома. Опционально: у большинства sidecar его нет.
    public var description: String?
    public var tracks: [String: TrackOverride]

    /// Имя sidecar-файла в папке альбома.
    public static let fileName = "album.zvermeta.json"

    public init(
        version: Int,
        artworkFileName: String? = nil,
        description: String? = nil,
        tracks: [String: TrackOverride] = [:]
    ) {
        self.version = version
        self.artworkFileName = artworkFileName
        self.description = description
        self.tracks = tracks
    }

    private enum CodingKeys: String, CodingKey {
        case version, artworkFileName, description, tracks
    }

    /// Кастомный декод: `artworkFileName`, `description` и `tracks` опциональны при
    /// чтении. Синтезированный `init(from:)` НЕ применяет дефолты из memberwise-init,
    /// поэтому sidecar без ключа `tracks` (например, правка только обложки —
    /// `{"version":1,"artworkFileName":"edited.jpg"}`) иначе не декодировался
    /// бы и молча отбрасывался вместе с обложкой.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.artworkFileName = try container.decodeIfPresent(
            String.self, forKey: .artworkFileName)
        self.description = try container.decodeIfPresent(
            String.self, forKey: .description)
        self.tracks = try container.decodeIfPresent(
            [String: TrackOverride].self, forKey: .tracks) ?? [:]
    }
}
